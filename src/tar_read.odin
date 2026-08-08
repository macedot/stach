package main

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

Extract_Kind :: enum {
	Dir,
	File,
	Symlink,
	Hardlink,
}

Extract_Op :: struct {
	kind:        Extract_Kind,
	path:        string, // absolute-ish dest path (from safe_join)
	link_target: string, // symlink text or hardlink target path
	mode:        i64,
	payload:     []u8, // view into tar buffer for files
}

Zstd_Frame :: struct {
	comp_off: int,
	comp_len: int,
	out_off:  int,
	out_len:  int,
}

Zstd_Frame_Job :: struct {
	zst:       []u8,
	tar:       []u8,
	frame:     Zstd_Frame,
	fail_flag: ^bool,
	fail_mu:   ^sync.Mutex,
}

// extract_tar_zst unpacks a zstd-compressed tar into dest_dir.
// workers: parallel frame decompress + parallel regular-file writes.
extract_tar_zst :: proc(archive, dest_dir: string, workers: int) -> bool {
	if !os.exists(archive) {
		eprintfln("Error: Not found: %s", archive)
		return false
	}

	dest := dest_dir
	if dest == "" {
		dest = "."
	}

	if err := os.make_directory_all(dest); err != nil && !os.exists(dest) {
		eprintfln("Error: mkdir %s: %v", dest, err)
		return false
	}

	zst_data, rerr := os.read_entire_file(archive, context.allocator)
	if rerr != nil {
		eprintfln("Error: read %s: %v", archive, rerr)
		return false
	}
	defer delete(zst_data)

	tar_data, dok := zstd_decompress_parallel(zst_data, max(1, workers))
	if !dok {
		eprintfln("Error: zstd decompress failed for %s", archive)
		return false
	}
	defer delete(tar_data)

	return extract_tar_bytes(tar_data, dest, max(1, workers))
}

// zstd_decompress_parallel scans independent frames and inflates them with a worker pool.
// Single-frame archives (and serial multi-frame) both work.
zstd_decompress_parallel :: proc(zst: []u8, workers: int) -> (tar: []u8, ok: bool) {
	frames, fok := zstd_scan_frames(zst)
	if !fok {
		return nil, false
	}
	defer delete(frames)

	if len(frames) == 0 {
		return make([]u8, 0), true
	}

	total_out := 0
	for f in frames {
		total_out += f.out_len
	}
	tar = make([]u8, total_out)

	if len(frames) == 1 || workers <= 1 {
		for f in frames {
			src := zst[f.comp_off:f.comp_off + f.comp_len]
			dst := tar[f.out_off:f.out_off + f.out_len]
			out_len: c.size_t
			if stach_zstd_decompress_into(
				   raw_data(src),
				   c.size_t(len(src)),
				   raw_data(dst),
				   c.size_t(len(dst)),
				   &out_len,
			   ) !=
			   0 {
				delete(tar)
				return nil, false
			}
			if int(out_len) != f.out_len {
				delete(tar)
				return nil, false
			}
		}
		return tar, true
	}

	fail_flag: bool
	fail_mu: sync.Mutex
	jobs := make([]Zstd_Frame_Job, len(frames))
	defer delete(jobs)

	n_pool := min(max(1, workers), len(frames))
	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, n_pool)
	defer thread.pool_destroy(&pool)

	for i in 0 ..< len(frames) {
		jobs[i] = Zstd_Frame_Job {
			zst       = zst,
			tar       = tar,
			frame     = frames[i],
			fail_flag = &fail_flag,
			fail_mu   = &fail_mu,
		}
		thread.pool_add_task(&pool, context.allocator, zstd_frame_decompress_task, &jobs[i], i)
	}
	thread.pool_start(&pool)
	thread.pool_finish(&pool)

	if fail_flag {
		delete(tar)
		return nil, false
	}
	return tar, true
}

zstd_scan_frames :: proc(zst: []u8) -> (frames: [dynamic]Zstd_Frame, ok: bool) {
	frames = make([dynamic]Zstd_Frame)
	off := 0
	out_off := 0
	UNKNOWN :: ~c.size_t(0)
	for off < len(zst) {
		remain := zst[off:]
		csize_c := stach_zstd_frame_compressed_size(raw_data(remain), c.size_t(len(remain)))
		csize := int(csize_c)
		if csize_c == 0 || csize <= 0 || csize > len(remain) {
			delete(frames)
			return nil, false
		}
		usize_c := stach_zstd_frame_content_size(raw_data(remain), c.size_t(csize))
		if usize_c == UNKNOWN {
			delete(frames)
			return nil, false
		}
		usize := int(usize_c)
		append(
			&frames,
			Zstd_Frame{comp_off = off, comp_len = csize, out_off = out_off, out_len = usize},
		)
		off += csize
		out_off += usize
	}
	return frames, true
}

zstd_frame_decompress_task :: proc(t: thread.Task) {
	job := cast(^Zstd_Frame_Job)t.data
	sync.mutex_lock(job.fail_mu)
	already := job.fail_flag^
	sync.mutex_unlock(job.fail_mu)
	if already {
		return
	}

	f := job.frame
	src := job.zst[f.comp_off:f.comp_off + f.comp_len]
	dst := job.tar[f.out_off:f.out_off + f.out_len]
	out_len: c.size_t
	if stach_zstd_decompress_into(
		   raw_data(src),
		   c.size_t(len(src)),
		   raw_data(dst),
		   c.size_t(len(dst)),
		   &out_len,
	   ) !=
	   0 ||
	   int(out_len) != f.out_len {
		sync.mutex_lock(job.fail_mu)
		job.fail_flag^ = true
		sync.mutex_unlock(job.fail_mu)
	}
}

extract_tar_bytes :: proc(data: []u8, dest_dir: string, workers: int) -> bool {
	ops, ok := parse_tar_ops(data, dest_dir)
	if !ok {
		return false
	}
	defer destroy_extract_ops(ops)

	// Phase D: directories first.
	for op in ops {
		if op.kind != .Dir {
			continue
		}
		if err := os.make_directory_all(op.path, perm_from_mode(op.mode, true)); err != nil &&
		   !os.is_directory(op.path) {
			eprintfln("Error: mkdir %s: %v", op.path, err)
			return false
		}
	}

	// Phase F: regular files in parallel.
	file_indices := make([dynamic]int)
	defer delete(file_indices)
	for op, i in ops {
		if op.kind == .File {
			append(&file_indices, i)
		}
	}

	if len(file_indices) > 0 {
		n_workers := min(max(1, workers), len(file_indices))
		fail_flag: bool
		fail_mu: sync.Mutex

		pool: thread.Pool
		thread.pool_init(&pool, context.allocator, n_workers)
		defer thread.pool_destroy(&pool)

		// Tasks hold pointers into ops; ops is stable for the pool lifetime.
		jobs := make([]Extract_File_Job, len(file_indices))
		defer delete(jobs)

		for fi, j in file_indices {
			jobs[j] = Extract_File_Job {
				op        = &ops[fi],
				fail_flag = &fail_flag,
				fail_mu   = &fail_mu,
			}
			thread.pool_add_task(&pool, context.allocator, extract_file_task, &jobs[j], j)
		}
		thread.pool_start(&pool)
		thread.pool_finish(&pool)

		if fail_flag {
			return false
		}
	}

	// Phase L: symlinks then hardlinks (targets must exist).
	for op in ops {
		if op.kind != .Symlink {
			continue
		}
		parent := filepath.dir(op.path)
		_ = os.make_directory_all(parent)
		if os.exists(op.path) {
			_ = os.remove(op.path)
		}
		if err := os.symlink(op.link_target, op.path); err != nil {
			eprintfln("Error: symlink %s -> %s: %v", op.path, op.link_target, err)
			return false
		}
	}
	for op in ops {
		if op.kind != .Hardlink {
			continue
		}
		parent := filepath.dir(op.path)
		_ = os.make_directory_all(parent)
		if os.exists(op.path) {
			_ = os.remove(op.path)
		}
		if err := os.link(op.link_target, op.path); err != nil {
			eprintfln("Error: link %s -> %s: %v", op.path, op.link_target, err)
			return false
		}
	}
	return true
}

Extract_File_Job :: struct {
	op:        ^Extract_Op,
	fail_flag: ^bool,
	fail_mu:   ^sync.Mutex,
}

extract_file_task :: proc(t: thread.Task) {
	job := cast(^Extract_File_Job)t.data
	sync.mutex_lock(job.fail_mu)
	already := job.fail_flag^
	sync.mutex_unlock(job.fail_mu)
	if already {
		return
	}

	op := job.op
	parent := filepath.dir(op.path)
	if err := os.make_directory_all(parent); err != nil && !os.is_directory(parent) {
		eprintfln("Error: mkdir %s: %v", parent, err)
		sync.mutex_lock(job.fail_mu)
		job.fail_flag^ = true
		sync.mutex_unlock(job.fail_mu)
		return
	}
	if err := os.write_entire_file(op.path, op.payload, perm_from_mode(op.mode, false)); err != nil {
		eprintfln("Error: write %s: %v", op.path, err)
		sync.mutex_lock(job.fail_mu)
		job.fail_flag^ = true
		sync.mutex_unlock(job.fail_mu)
		return
	}
}

parse_tar_ops :: proc(data: []u8, dest_dir: string) -> (ops: [dynamic]Extract_Op, ok: bool) {
	ops = make([dynamic]Extract_Op)
	off := 0
	for off + 512 <= len(data) {
		hdr := data[off:off + 512]
		off += 512

		if is_zero_block(hdr) {
			// End of archive (one or two zero blocks)
			return ops, true
		}

		name := ustar_full_name(hdr)
		if name == "" {
			eprintfln("Error: empty tar member name")
			destroy_extract_ops(ops)
			return nil, false
		}

		typeflag := hdr[156]
		size := parse_octal(hdr[124:136])
		linkname := cstr_field(hdr[157:257])
		mode := parse_octal(hdr[100:108])

		// Consume payload + padding
		payload: []u8
		if size > 0 {
			if off + int(size) > len(data) {
				eprintfln("Error: truncated tar payload for %s", name)
				destroy_extract_ops(ops)
				delete(name)
				return nil, false
			}
			payload = data[off:off + int(size)]
			off += int(size)
			pad := (512 - (int(size) % 512)) % 512
			off += pad
		}

		// pax / gnu long name — skip unsupported special types with data
		if typeflag == 'x' || typeflag == 'g' || typeflag == 'L' || typeflag == 'K' {
			delete(name)
			continue
		}

		safe, sok := safe_join(dest_dir, name)
		if !sok {
			eprintfln("Error: unsafe path in archive: %s", name)
			delete(name)
			destroy_extract_ops(ops)
			return nil, false
		}
		delete(name)

		switch typeflag {
		case '5', 'D':
			append(
				&ops,
				Extract_Op{kind = .Dir, path = safe, mode = mode},
			)
		case '2':
			append(
				&ops,
				Extract_Op {
					kind        = .Symlink,
					path        = safe,
					link_target = strings.clone(linkname),
					mode        = mode,
				},
			)
		case '1':
			target, tok := safe_join(dest_dir, linkname)
			if !tok {
				eprintfln("Error: unsafe hardlink target: %s", linkname)
				delete(safe)
				destroy_extract_ops(ops)
				return nil, false
			}
			append(
				&ops,
				Extract_Op{kind = .Hardlink, path = safe, link_target = target, mode = mode},
			)
		case '0', '\x00', '7':
			append(
				&ops,
				Extract_Op{kind = .File, path = safe, mode = mode, payload = payload},
			)
		case:
			delete(safe)
			continue
		}
	}
	return ops, true
}

destroy_extract_ops :: proc(ops: [dynamic]Extract_Op) {
	for &op in ops {
		delete(op.path)
		delete(op.link_target)
		// payload is a view into tar buffer — not owned
	}
	delete(ops)
}

is_zero_block :: proc(b: []u8) -> bool {
	for x in b {
		if x != 0 {
			return false
		}
	}
	return true
}

cstr_field :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 {
		n += 1
	}
	return string(b[:n])
}

ustar_full_name :: proc(hdr: []u8) -> string {
	name := cstr_field(hdr[0:100])
	prefix := cstr_field(hdr[345:500])
	if prefix == "" {
		return strings.clone(strings.trim_right(name, "/"))
	}
	return strings.clone(
		strings.trim_right(strings.concatenate({prefix, "/", name}, context.temp_allocator), "/"),
	)
}

parse_octal :: proc(b: []u8) -> i64 {
	s := cstr_field(b)
	s = strings.trim_space(s)
	if s == "" {
		return 0
	}
	v: i64 = 0
	for i in 0 ..< len(s) {
		c := s[i]
		if c < '0' || c > '7' {
			break
		}
		v = v * 8 + i64(c - '0')
	}
	return v
}

// safe_join ensures result stays under dest_dir (no absolute / no ..).
safe_join :: proc(dest_dir, name: string) -> (string, bool) {
	n := name
	// strip leading slashes
	for len(n) > 0 && (n[0] == '/' || n[0] == '\\') {
		n = n[1:]
	}
	if n == "" {
		return "", false
	}
	// normalize and reject ..
	parts := strings.split(n, "/")
	defer delete(parts)
	clean := make([dynamic]string)
	defer delete(clean)
	for p in parts {
		if p == "" || p == "." {
			continue
		}
		if p == ".." {
			return "", false
		}
		// also reject backslash segments on unix
		if strings.contains(p, "\\") {
			return "", false
		}
		append(&clean, p)
	}
	if len(clean) == 0 {
		return "", false
	}
	joined := strings.join(clean[:], "/")
	defer delete(joined)
	full, jerr := filepath.join([]string{dest_dir, joined})
	if jerr != nil {
		return "", false
	}
	return full, true
}

perm_from_mode :: proc(mode: i64, is_dir: bool) -> os.Permissions {
	m := int(mode) & 0o777
	if m == 0 {
		if is_dir {
			return os.Permissions_Default_Directory
		}
		return os.Permissions_Default_File
	}
	return os.perm_number(m)
}
