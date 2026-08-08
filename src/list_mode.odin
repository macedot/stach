package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// List mode: pack every entry of a list file into a single timestamped
// .tar.zst. List file format: one path per line, '#' comments and blank lines
// ignored, '*'/'?'/'[' wildcards expanded, missing entries warned and skipped.

// parse_list_file returns the cleaned entry lines (each cloned).
parse_list_file :: proc(path: string) -> [dynamic]string {
	lines := make([dynamic]string)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		eprintfln("Error: read list file %s: %v", path, err)
		return lines
	}
	defer delete(data)

	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if l == "" || strings.has_prefix(l, "#") {
			continue
		}
		append(&lines, strings.clone(l))
	}
	return lines
}

// list_entry_root_name computes the tar member root for a resolved list path:
// relative paths are stored as written (leading ./ stripped); absolute paths
// are stored with the leading slash stripped (gist convention).
list_entry_root_name :: proc(path: string) -> string {
	p := strip_trailing_slashes(path)
	for strings.has_prefix(p, "./") {
		p = p[2:]
	}
	if filepath.is_abs(p) {
		for len(p) > 0 && (p[0] == '/' || p[0] == '\\') {
			p = p[1:]
		}
	}
	return p
}

// resolve_list_entries expands list lines into existing paths (each cloned).
// Missing paths and unmatched wildcards warn and are skipped.
resolve_list_entries :: proc(lines: []string) -> [dynamic]string {
	resolved := make([dynamic]string)
	seen := make(map[string]bool)
	defer {
		for k in seen {
			delete(k)
		}
		delete(seen)
	}

	for line in lines {
		p := strip_trailing_slashes(line)
		if p == "" {
			continue
		}

		if has_glob_meta(p) {
			matches, gerr := os.glob(p)
			if gerr != nil {
				eprintfln("Warning: skip (glob failed): %s: %v", p, gerr)
				continue
			}
			if len(matches) == 0 {
				eprintfln("Warning: skip (no matches): %s", p)
			}
			for m in matches {
				append_unique_resolved(&resolved, &seen, m)
			}
			delete(matches)
			continue
		}

		if !os.exists(p) {
			eprintfln("Warning: skip (not found): %s", p)
			continue
		}
		append_unique_resolved(&resolved, &seen, p)
	}
	return resolved
}

append_unique_resolved :: proc(resolved: ^[dynamic]string, seen: ^map[string]bool, path: string) {
	p := strip_trailing_slashes(path)
	if p == "" || p == "." || p == ".." {
		return
	}
	if p in seen^ {
		return
	}
	seen^[strings.clone(p)] = true
	append(resolved, strings.clone(p))
}

// run_list_mode packs all entries of list_path into one
// <cwd basename>.<timestamp>.tar.zst in the current directory.
run_list_mode :: proc(list_path: string, compress_workers: int) -> bool {
	lines := parse_list_file(list_path)
	defer {
		for l in lines {
			delete(l)
		}
		delete(lines)
	}
	if len(lines) == 0 {
		eprintfln("Error: no entries in list file: %s", list_path)
		return false
	}

	resolved := resolve_list_entries(lines[:])
	defer {
		for r in resolved {
			delete(r)
		}
		delete(resolved)
	}
	if len(resolved) == 0 {
		eprintfln("Error: nothing to backup from list: %s", list_path)
		return false
	}

	entries := make([dynamic]Tar_Entry)
	seen_inos := make(map[u128]string)
	defer {
		for _, v in seen_inos {
			delete(v)
		}
		delete(seen_inos)
	}

	ok := true
	for path in resolved {
		root_name := list_entry_root_name(path)
		if root_name == "" {
			eprintfln("Warning: skip (no archive name): %s", path)
			continue
		}
		if os.is_directory(path) {
			if !collect_tree_entries(path, root_name, &entries, &seen_inos) {
				ok = false
			}
		} else {
			if !append_single_entry(path, root_name, &entries, &seen_inos) {
				ok = false
			}
		}
		if !ok {
			break
		}
	}
	if !ok || len(entries) == 0 {
		destroy_tar_entries(entries)
		if ok {
			eprintfln("Error: nothing to backup from list: %s", list_path)
		}
		return false
	}
	defer destroy_tar_entries(entries)

	cwd, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil {
		eprintfln("Error: get working directory: %v", cwd_err)
		return false
	}
	defer delete(cwd)
	label := filepath.base(cwd)

	ts := strings.clone(timestamp_now())
	defer delete(ts)
	dst := dest_for_dir(label, ts)

	if !pack_tar_entries(label, entries, dst, compress_workers) {
		return false
	}
	print_src_dst(label, dst)
	return true
}

// default_list_file returns "<cwd basename>.list" (temp allocator) if it
// exists in the current directory, else "".
default_list_file :: proc() -> string {
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		return ""
	}
	candidate := fmt.tprintf("%s.list", filepath.base(cwd))
	if os.exists(candidate) {
		return candidate
	}
	return ""
}
