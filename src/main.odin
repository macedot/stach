package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

io_mu: sync.Mutex
quiet_mode: bool

eprintfln :: proc(format: string, args: ..any) {
	sync.mutex_lock(&io_mu)
	defer sync.mutex_unlock(&io_mu)
	fmt.eprintfln(format, ..args)
}

print_src_dst :: proc(src, dst: string) {
	if quiet_mode {
		return
	}
	sync.mutex_lock(&io_mu)
	defer sync.mutex_unlock(&io_mu)
	fmt.printfln("%s -> %s", src, dst)
}

print_progress_update :: proc(line: string, done := false) {
	if quiet_mode {
		return
	}
	sync.mutex_lock(&io_mu)
	defer sync.mutex_unlock(&io_mu)
	if done {
		fmt.printfln("\r%s", line)
		return
	}
	fmt.printf("\r%s", line)
}

print_usage :: proc() {
	prog := "stach"
	if len(os.args) > 0 {
		prog = os.args[0]
	}
	fmt.eprintf(
		`Usage: %s [--quiet] [-j N] [-c N] <file|directory|pattern> ...
       %s [--quiet] [-c N] [-f list_file]
       %s [-c N] -x <archive.tar.zst> [dest_dir]

  Backup (default):
    Files  → copy to <path>.<timestamp>
    Dirs   → <path>.<timestamp>.tar.zst  (ustar + zstd level 1; symlinks/hardlinks)

  List mode:
    No paths → pack entries of <dirname>.list into one <dirname>.<timestamp>.tar.zst
    -f FILE  Use a custom list file (one path per line; '#' comments and
             wildcards supported; missing entries warn and are skipped)

  Extract:
    -x     Unpack .tar.zst into dest_dir (default: .)

  -j N   Max entities to process in parallel (default: CPU count)
  -c N   multi-frame zstd workers + extract file writers (default: CPU count)
  --quiet   Suppress all non-error output

  Prints only: src -> dst and live pack progress
  Errors go to stderr.
`,
		prog,
		prog,
		prog,
	)
}

parse_int_flag :: proc(s: string) -> (n: int, ok: bool) {
	v, ok2 := strconv.parse_int(s)
	if !ok2 || v < 1 {
		return 0, false
	}
	return v, true
}

Entity_Job :: struct {
	src:       string,
	ts:        string,
	zip_cores: int,
	ok:        bool,
}

entity_task :: proc(t: thread.Task) {
	job := cast(^Entity_Job)t.data
	src := strip_trailing_slashes(job.src)

	if is_dot_or_dotdot(src) {
		eprintfln(
			"Error: Cannot backup '.' or '..' directly. Pass a named file or directory instead.",
		)
		job.ok = false
		return
	}

	if !os.exists(src) {
		eprintfln("Error: Not found: %s", src)
		job.ok = false
		return
	}

	// Prefer lstat so a top-level symlink is not misclassified.
	info, err := os.lstat(src, context.allocator)
	if err != nil {
		eprintfln("Error: lstat %s: %v", src, err)
		job.ok = false
		return
	}
	defer os.file_info_delete(info, context.allocator)

	// Follow for classification of top-level path (dir vs file); tree walk uses lstat.
	if os.is_directory(src) {
		dst := strings.clone(dest_for_dir(src, job.ts))
		defer delete(dst)
		if tar_directory(src, dst, job.zip_cores) {
			print_src_dst(src, dst)
			job.ok = true
		} else {
			job.ok = false
		}
		return
	}

	if os.is_file(src) || info.type == .Regular || info.type == .Symlink {
		dst := strings.clone(dest_for_file(src, job.ts))
		defer delete(dst)
		if cerr := copy_file_preserve(dst, src); cerr != nil {
			eprintfln("Error: copy %s -> %s: %v", src, dst, cerr)
			job.ok = false
			return
		}
		print_src_dst(src, dst)
		job.ok = true
		return
	}

	eprintfln("Error: Unsupported file type: %s", src)
	job.ok = false
}

main :: proc() {
	jobs_n := os.get_processor_core_count()
	cores_n := jobs_n
	if jobs_n < 1 {
		jobs_n = 1
	}
	if cores_n < 1 {
		cores_n = 1
	}

	extract_mode := false
	extract_archive: string
	extract_dest := "."
	list_file := ""

	patterns := make([dynamic]string)
	defer delete(patterns)

	args := os.args[1:]
	i := 0
	for i < len(args) {
		a := args[i]
		if a == "-h" || a == "--help" {
			print_usage()
			os.exit(2)
		}
		if a == "-x" {
			extract_mode = true
			i += 1
			continue
		}
		if a == "--quiet" {
			quiet_mode = true
			i += 1
			continue
		}
		if a == "-j" {
			if i + 1 >= len(args) {
				eprintfln("Error: -j requires a number")
				print_usage()
				os.exit(2)
			}
			n, ok := parse_int_flag(args[i + 1])
			if !ok {
				eprintfln("Error: invalid -j value: %s", args[i + 1])
				os.exit(2)
			}
			jobs_n = n
			i += 2
			continue
		}
		if strings.has_prefix(a, "-j") && len(a) > 2 {
			n, ok := parse_int_flag(a[2:])
			if !ok {
				eprintfln("Error: invalid -j value: %s", a[2:])
				os.exit(2)
			}
			jobs_n = n
			i += 1
			continue
		}
		if a == "-c" {
			if i + 1 >= len(args) {
				eprintfln("Error: -c requires a number")
				print_usage()
				os.exit(2)
			}
			n, ok := parse_int_flag(args[i + 1])
			if !ok {
				eprintfln("Error: invalid -c value: %s", args[i + 1])
				os.exit(2)
			}
			cores_n = n
			i += 2
			continue
		}
		if strings.has_prefix(a, "-c") && len(a) > 2 {
			n, ok := parse_int_flag(a[2:])
			if !ok {
				eprintfln("Error: invalid -c value: %s", a[2:])
				os.exit(2)
			}
			cores_n = n
			i += 1
			continue
		}
		if a == "-f" || a == "--file" {
			if i + 1 >= len(args) {
				eprintfln("Error: %s requires a list file path", a)
				print_usage()
				os.exit(2)
			}
			list_file = args[i + 1]
			i += 2
			continue
		}
		if strings.has_prefix(a, "-f") && len(a) > 2 {
			list_file = a[2:]
			i += 1
			continue
		}
		if strings.has_prefix(a, "-") {
			eprintfln("Error: unknown option: %s", a)
			print_usage()
			os.exit(2)
		}
		append(&patterns, a)
		i += 1
	}

	if extract_mode {
		if list_file != "" {
			eprintfln("Error: -f cannot be combined with -x")
			print_usage()
			os.exit(2)
		}
		if len(patterns) < 1 || len(patterns) > 2 {
			eprintfln("Error: -x requires <archive.tar.zst> [dest_dir]")
			print_usage()
			os.exit(2)
		}
		extract_archive = patterns[0]
		if len(patterns) == 2 {
			extract_dest = patterns[1]
		}
		if extract_tar_zst(extract_archive, extract_dest, cores_n) {
			print_src_dst(extract_archive, extract_dest)
			os.exit(0)
		}
		os.exit(1)
	}

	// List mode: explicit -f, or no paths and a default <cwd-basename>.list.
	list_path := list_file
	if list_path == "" && len(patterns) == 0 {
		list_path = default_list_file()
	}
	if list_path != "" {
		if len(patterns) > 0 {
			eprintfln("Error: -f / list mode cannot be combined with path arguments")
			print_usage()
			os.exit(2)
		}
		if !os.exists(list_path) {
			eprintfln("Error: list file not found: %s", list_path)
			os.exit(1)
		}
		if run_list_mode(list_path, cores_n) {
			os.exit(0)
		}
		os.exit(1)
	}

	if len(patterns) == 0 {
		print_usage()
		os.exit(2)
	}

	paths, expand_err := expand_patterns(patterns[:])
	defer {
		for p in paths {
			delete(p)
		}
		delete(paths)
	}

	if len(paths) == 0 {
		os.exit(1)
	}

	ts := strings.clone(timestamp_now())
	defer delete(ts)

	entity_workers := min(jobs_n, len(paths))
	entity_workers = max(1, entity_workers)

	entity_jobs := make([]Entity_Job, len(paths))
	defer delete(entity_jobs)

	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, entity_workers)
	defer thread.pool_destroy(&pool)

	for p, idx in paths {
		entity_jobs[idx] = Entity_Job {
			src       = p,
			ts        = ts,
			zip_cores = cores_n,
			ok        = false,
		}
		thread.pool_add_task(&pool, context.allocator, entity_task, &entity_jobs[idx], idx)
	}

	thread.pool_start(&pool)
	thread.pool_finish(&pool)

	any_fail := expand_err
	for j in entity_jobs {
		if !j.ok {
			any_fail = true
		}
	}

	if any_fail {
		os.exit(1)
	}
}
