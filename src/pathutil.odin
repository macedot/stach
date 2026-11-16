package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import dt "core:time/datetime"

// timestamp_now returns local time as YYYYMMDDHHMMSS.
timestamp_now :: proc() -> string {
	now := time.now()
	// time_to_datetime yields UTC components; convert via local if available.
	// Use unix seconds + local offset via time package helpers when possible.
	t := time.time_to_datetime(now) or_else dt.DateTime{}
	// Prefer wall-clock local via ctime-like formatting with time.Duration offset.
	// Odin core exposes UTC; for backup stamps, UTC is acceptable and stable.
	// If conversion failed, fall back to unix seconds.
	if t.year == 0 {
		return fmt.tprintf("%d", time.to_unix_seconds(now))
	}
	return fmt.tprintf(
		"%04d%02d%02d%02d%02d%02d",
		t.year,
		t.month,
		t.day,
		t.hour,
		t.minute,
		t.second,
	)
}

// strip_trailing_slashes removes trailing / or \ (except root "/").
strip_trailing_slashes :: proc(path: string) -> string {
	if path == "" {
		return path
	}
	p := path
	for len(p) > 1 && (p[len(p) - 1] == '/' || p[len(p) - 1] == '\\') {
		p = p[:len(p) - 1]
	}
	return p
}

has_glob_meta :: proc(pattern: string) -> bool {
	for ch in pattern {
		if ch == '*' || ch == '?' || ch == '[' {
			return true
		}
	}
	return false
}

// expand_patterns turns CLI args into concrete existing paths.
// Returns allocated slice of strings (each path cloned). Errors go to stderr.
expand_patterns :: proc(patterns: []string) -> (paths: [dynamic]string, any_error: bool) {
	paths = make([dynamic]string)
	any_error = false

	for pat in patterns {
		p := strip_trailing_slashes(pat)
		if p == "" {
			p = "."
		}

		if has_glob_meta(p) {
			matches, err := os.glob(p)
			if err != nil {
				eprintfln("Error: glob failed for %s: %v", p, err)
				any_error = true
				continue
			}
			if len(matches) == 0 {
				eprintfln("Error: No match: %s", p)
				any_error = true
				continue
			}
			for m in matches {
				append(&paths, strings.clone(strip_trailing_slashes(m)))
			}
			delete(matches)
		} else {
			if !os.exists(p) {
				eprintfln("Error: Not found: %s", p)
				any_error = true
				continue
			}
			append(&paths, strings.clone(p))
		}
	}
	return
}

is_dot_or_dotdot :: proc(path: string) -> bool {
	b := filepath.base(path)
	return b == "." || b == ".." || b == ""
}

dest_for_file :: proc(src, ts: string) -> string {
	return fmt.tprintf("%s.%s", src, ts)
}

dest_for_dir :: proc(src, ts: string) -> string {
	return fmt.tprintf("%s.%s.tgz", src, ts)
}

// archive_entry_name builds tar member path with forward slashes.
// src_root is the directory being archived (no trailing slash).
// base_name is filepath.base(src_root).
archive_entry_name :: proc(src_root, fullpath, base_name: string, is_dir: bool) -> string {
	root := strip_trailing_slashes(src_root)
	fp := strip_trailing_slashes(fullpath)

	suffix: string
	if fp == root {
		suffix = ""
	} else if strings.has_prefix(fp, root) &&
	   len(fp) > len(root) &&
	   (fp[len(root)] == '/' || fp[len(root)] == '\\') {
		suffix = fp[len(root) + 1:]
	} else {
		suffix = filepath.base(fp)
	}

	// Normalize separators to /
	suffix_norm, _ := strings.replace_all(suffix, "\\", "/", context.temp_allocator)

	name: string
	if suffix_norm == "" {
		name = base_name
	} else {
		name = fmt.tprintf("%s/%s", base_name, suffix_norm)
	}
	if is_dir && !strings.has_suffix(name, "/") {
		name = fmt.tprintf("%s/", name)
	}
	return strings.clone(name)
}
