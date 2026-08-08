package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"

// Minimum uncompressed tar bytes per zstd frame when multi-frame packing.
ZSTD_FRAME_CHUNK_MIN :: 1 * 1024 * 1024

Zstd_Chunk_Job :: struct {
	src:      []u8,
	comp:     [^]u8,
	comp_len: int,
	err:      bool,
}

Tar_Kind :: enum {
	File,
	Dir,
	Symlink,
	Hardlink,
}

Tar_Entry :: struct {
	kind:       Tar_Kind,
	fullpath:   string,
	entry_name: string, // archive path, no leading ./ ; dirs may end with /
	link_target: string, // symlink target or hardlink path inside archive
	mode:       int,
	mtime:      i64,
	size:       i64,
	data:       []u8, // file payload only
}

Tar_Pack_Progress :: struct {
	label:             string,
	total_entries:      int,
	packed_entries:     int,
	total_payload:      i64,
	packed_payload:     i64,
	last_render_entries: int,
	last_render_width:  int,
}

PROGRESS_ENTRY_STEP :: 32

// tar_directory writes src tree to dst as zstd-compressed ustar (.tar.zst).
// compress_workers: multi-frame parallel compress (independent zstd frames).
tar_directory :: proc(src_path, dst_path: string, compress_workers: int) -> bool {
	workers := max(1, compress_workers)

	if os.exists(dst_path) {
		eprintfln("Error: Destination exists: %s", dst_path)
		return false
	}

	src := strip_trailing_slashes(src_path)
	base_name := filepath.base(src)
	if base_name == "" || base_name == "." || base_name == ".." {
		eprintfln("Error: Cannot backup '%s'", src)
		return false
	}

	entries := collect_tar_entries(src, base_name)
	if entries == nil {
		return false
	}
	defer destroy_tar_entries(entries)

	progress := new_tar_pack_progress(base_name, entries)
	render_pack_progress(&progress, true)

	tar_buf := make([dynamic]u8)
	defer delete(tar_buf)

	for &e in entries {
		if !append_tar_entry(&tar_buf, &e) {
			finish_pack_progress(&progress, false)
			eprintfln("Error: Failed to pack entry: %s", e.fullpath)
			return false
		}
		advance_pack_progress(&progress, &e)
	}
	finish_pack_progress(&progress, false)
	// Two zero blocks end the archive.
	append_zeros(&tar_buf, 1024)

	print_progress_update(
		progress_phase_line(base_name, fmt.tprintf("Compressing zstd (%d workers)", workers)),
		false,
	)

	comp, cok := zstd_compress_tar_parallel(tar_buf[:], workers)
	if !cok {
		finish_pack_progress(&progress, false)
		eprintfln("Error: zstd compress failed for %s", src)
		return false
	}
	defer delete(comp)

	print_progress_update(progress_phase_line(base_name, "Writing archive"), false)
	if err := os.write_entire_file(dst_path, comp); err != nil {
		finish_pack_progress(&progress, false)
		_ = os.remove(dst_path)
		eprintfln("Error: write %s: %v", dst_path, err)
		return false
	}
	finish_pack_progress(&progress, true)
	return true
}

// zstd_compress_tar_parallel emits one or more independent zstd frames so extract
// can decompress frames in parallel. Level 1 for fast backups.
zstd_compress_tar_parallel :: proc(tar: []u8, workers: int) -> (out: []u8, ok: bool) {
	workers := max(1, workers)
	tar_len := len(tar)

	// Single frame when small or single worker.
	if workers == 1 || tar_len <= ZSTD_FRAME_CHUNK_MIN {
		src_ptr: [^]u8 = nil
		if tar_len > 0 {
			src_ptr = raw_data(tar)
		}
		out_len: c.size_t
		comp := stach_zstd_compress(src_ptr, c.size_t(tar_len), 1, c.int(workers), &out_len)
		if comp == nil {
			return nil, false
		}
		// Copy into Odin-owned slice so callers can delete() uniformly.
		out = make([]u8, int(out_len))
		copy(out, ([^]u8)(comp)[:int(out_len)])
		stach_free(comp)
		return out, true
	}

	// Target ~workers*4 chunks, each at least CHUNK_MIN (except last).
	chunk_size := max(ZSTD_FRAME_CHUNK_MIN, (tar_len + workers * 4 - 1) / (workers * 4))
	n_chunks := (tar_len + chunk_size - 1) / chunk_size
	if n_chunks < 1 {
		n_chunks = 1
	}

	jobs := make([]Zstd_Chunk_Job, n_chunks)
	defer {
		for &j in jobs {
			if j.comp != nil {
				stach_free(j.comp)
				j.comp = nil
			}
		}
		delete(jobs)
	}

	off := 0
	for i in 0 ..< n_chunks {
		end := min(off + chunk_size, tar_len)
		jobs[i].src = tar[off:end]
		off = end
	}

	n_pool := min(workers, n_chunks)
	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, n_pool)
	defer thread.pool_destroy(&pool)

	for i in 0 ..< n_chunks {
		thread.pool_add_task(&pool, context.allocator, zstd_chunk_compress_task, &jobs[i], i)
	}
	thread.pool_start(&pool)
	thread.pool_finish(&pool)

	total := 0
	for j in jobs {
		if j.err || j.comp == nil {
			return nil, false
		}
		total += j.comp_len
	}

	out = make([]u8, total)
	w := 0
	for j in jobs {
		copy(out[w:w + j.comp_len], ([^]u8)(j.comp)[:j.comp_len])
		w += j.comp_len
	}
	return out, true
}

zstd_chunk_compress_task :: proc(t: thread.Task) {
	job := cast(^Zstd_Chunk_Job)t.data
	src_ptr: [^]u8 = nil
	if len(job.src) > 0 {
		src_ptr = raw_data(job.src)
	}
	out_len: c.size_t
	// One frame per chunk; no nested MT (workers=1).
	comp := stach_zstd_compress(src_ptr, c.size_t(len(job.src)), 1, 1, &out_len)
	if comp == nil {
		job.err = true
		return
	}
	job.comp = comp
	job.comp_len = int(out_len)
}

new_tar_pack_progress :: proc(label: string, entries: [dynamic]Tar_Entry) -> Tar_Pack_Progress {
	total_payload: i64
	for e in entries {
		if e.kind == .File {
			total_payload += e.size
		}
	}
	return Tar_Pack_Progress {
		label         = label,
		total_entries = len(entries),
		total_payload = total_payload,
	}
}

advance_pack_progress :: proc(p: ^Tar_Pack_Progress, e: ^Tar_Entry) {
	p.packed_entries += 1
	if e.kind == .File {
		p.packed_payload += e.size
	}
	render_pack_progress(p, false)
}

render_pack_progress :: proc(p: ^Tar_Pack_Progress, force: bool) {
	if quiet_mode {
		return
	}
	if !force {
		if p.packed_entries != p.total_entries {
			if p.packed_entries-p.last_render_entries < PROGRESS_ENTRY_STEP {
				return
			}
		}
	}

	percent := 100.0
	if p.total_entries > 0 {
		percent = 100.0 * f64(p.packed_entries) / f64(p.total_entries)
	}
	msg := fmt.tprintf(
		"Packing %s: %d/%d entries (%.1f%%), %s/%s",
		p.label,
		p.packed_entries,
		p.total_entries,
		percent,
		human_payload(p.packed_payload),
		human_payload(p.total_payload),
	)

	if p.last_render_width > len(msg) {
		pad := p.last_render_width - len(msg)
		msg = fmt.tprintf("%s%s", msg, strings.repeat(" ", pad, context.temp_allocator))
	}

	print_progress_update(msg)
	p.last_render_entries = p.packed_entries
	p.last_render_width = len(msg)
}

finish_pack_progress :: proc(p: ^Tar_Pack_Progress, success: bool) {
	if quiet_mode {
		return
	}
	if success {
		percent := 100.0
		msg := fmt.tprintf(
			"Packed %s: %d/%d entries (%.1f%%), %s/%s",
			p.label,
			p.packed_entries,
			p.total_entries,
			percent,
			human_payload(p.packed_payload),
			human_payload(p.total_payload),
		)
		if p.last_render_width > len(msg) {
			pad := p.last_render_width - len(msg)
			msg = fmt.tprintf("%s%s", msg, strings.repeat(" ", pad, context.temp_allocator))
		}
		print_progress_update(msg, true)
		p.last_render_width = len(msg)
		return
	}
	if p.last_render_width > 0 {
		print_progress_update(strings.repeat(" ", p.last_render_width, context.temp_allocator), true)
	}
}

progress_phase_line :: proc(label, phase: string) -> string {
	return fmt.tprintf("Packing %s: %s", label, phase)
}

human_payload :: proc(n: i64) -> string {
	if n < 1024 {
		return fmt.tprintf("%d B", n)
	}
	if n < 1024 * 1024 {
		return fmt.tprintf("%.1f KiB", f64(n) / 1024.0)
	}
	if n < 1024 * 1024 * 1024 {
		return fmt.tprintf("%.1f MiB", f64(n) / (1024.0 * 1024.0))
	}
	return fmt.tprintf("%.1f GiB", f64(n) / (1024.0 * 1024.0 * 1024.0))
}

collect_tar_entries :: proc(src, base_name: string) -> [dynamic]Tar_Entry {
	entries := make([dynamic]Tar_Entry)

	src_abs, abs_err := os.get_absolute_path(src, context.allocator)
	if abs_err != nil {
		eprintfln("Error: resolve path %s: %v", src, abs_err)
		return nil
	}
	defer delete(src_abs)
	src_root := strip_trailing_slashes(src_abs)

	// inode -> first archive path for hardlinks
	seen_inos := make(map[u128]string)
	defer {
		for _, v in seen_inos {
			delete(v)
		}
		delete(seen_inos)
	}

	// Root directory entry.
	{
		info, err := os.lstat(src, context.allocator)
		if err != nil {
			eprintfln("Error: lstat %s: %v", src, err)
			return nil
		}
		defer os.file_info_delete(info, context.allocator)
		root_name := archive_entry_name(src_root, src_root, base_name, true)
		append(
			&entries,
			Tar_Entry {
				kind       = .Dir,
				fullpath   = strings.clone(src),
				entry_name = root_name,
				mode       = mode_from_info(info),
				mtime      = time.to_unix_seconds(info.modification_time),
			},
		)
	}

	w := os.walker_create(src)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {
		if path, err := os.walker_error(&w); err != nil {
			eprintfln("Error: walking %s: %v", path, err)
			destroy_tar_entries(entries)
			return nil
		}

		fp := strip_trailing_slashes(info.fullpath)
		if fp == src_root {
			continue
		}

		// Re-lstat to avoid following symlinks.
		li, lerr := os.lstat(info.fullpath, context.allocator)
		if lerr != nil {
			eprintfln("Error: lstat %s: %v", info.fullpath, lerr)
			destroy_tar_entries(entries)
			return nil
		}
		defer os.file_info_delete(li, context.allocator)

		switch li.type {
		case .Directory:
			name := archive_entry_name(src_root, fp, base_name, true)
			append(
				&entries,
				Tar_Entry {
					kind       = .Dir,
					fullpath   = strings.clone(info.fullpath),
					entry_name = name,
					mode       = mode_from_info(li),
					mtime      = time.to_unix_seconds(li.modification_time),
				},
			)
		case .Symlink:
			target, rerr := os.read_link(info.fullpath, context.allocator)
			if rerr != nil {
				eprintfln("Error: readlink %s: %v", info.fullpath, rerr)
				destroy_tar_entries(entries)
				return nil
			}
			name := archive_entry_name(src_root, fp, base_name, false)
			append(
				&entries,
				Tar_Entry {
					kind        = .Symlink,
					fullpath    = strings.clone(info.fullpath),
					entry_name  = name,
					link_target = target,
					mode        = 0o777,
					mtime       = time.to_unix_seconds(li.modification_time),
				},
			)
		case .Regular, .Undetermined:
			name := archive_entry_name(src_root, fp, base_name, false)
			// Hardlink if inode already stored as a regular file.
			if li.inode != 0 {
				if first, ok := seen_inos[li.inode]; ok {
					append(
						&entries,
						Tar_Entry {
							kind        = .Hardlink,
							fullpath    = strings.clone(info.fullpath),
							entry_name  = name,
							link_target = strings.clone(first),
							mode        = mode_from_info(li),
							mtime       = time.to_unix_seconds(li.modification_time),
						},
					)
					break
				}
			}
			data, rerr := os.read_entire_file(info.fullpath, context.allocator)
			if rerr != nil {
				eprintfln("Error: read %s: %v", info.fullpath, rerr)
				destroy_tar_entries(entries)
				return nil
			}
			if li.inode != 0 {
				seen_inos[li.inode] = strings.clone(name)
			}
			append(
				&entries,
				Tar_Entry {
					kind       = .File,
					fullpath   = strings.clone(info.fullpath),
					entry_name = name,
					mode       = mode_from_info(li),
					mtime      = time.to_unix_seconds(li.modification_time),
					size       = i64(len(data)),
					data       = data,
				},
			)
		case .Named_Pipe, .Socket, .Block_Device, .Character_Device:
			eprintfln("Error: skipping special file: %s", info.fullpath)
		}
	}

	if path, err := os.walker_error(&w); err != nil {
		eprintfln("Error: walking %s: %v", path, err)
		destroy_tar_entries(entries)
		return nil
	}
	return entries
}

destroy_tar_entries :: proc(entries: [dynamic]Tar_Entry) {
	for &e in entries {
		delete(e.fullpath)
		delete(e.entry_name)
		delete(e.link_target)
		if e.data != nil {
			delete(e.data)
		}
	}
	delete(entries)
}

mode_from_info :: proc(info: os.File_Info) -> int {
	m := int(transmute(u32)info.mode) & 0o777
	if m == 0 {
		if info.type == .Directory {
			return 0o755
		}
		return 0o644
	}
	return m
}

append_zeros :: proc(buf: ^[dynamic]u8, n: int) {
	for i := 0; i < n; i += 1 {
		append(buf, 0)
	}
}

append_tar_entry :: proc(buf: ^[dynamic]u8, e: ^Tar_Entry) -> bool {
	name := strings.trim_right(e.entry_name, "/")
	// ustar name limit 100, prefix 155
	name_field, prefix_field, ok_split := split_ustar_name(name)
	if !ok_split {
		// Fall back: truncate with warning (rare); better than failing entirely.
		eprintfln("Error: path too long for ustar: %s", name)
		return false
	}

	typeflag: u8
	size: i64 = 0
	linkname := e.link_target

	switch e.kind {
	case .File:
		typeflag = '0'
		size = e.size
	case .Dir:
		typeflag = '5'
		// directory names often stored with trailing slash in name field
		if !strings.has_suffix(e.entry_name, "/") {
			// name_field already without slash; put slash in name if room
		}
		size = 0
	case .Symlink:
		typeflag = '2'
		size = 0
	case .Hardlink:
		typeflag = '1'
		size = 0
	}

	if len(linkname) > 100 {
		eprintfln("Error: link target too long: %s", linkname)
		return false
	}

	hdr: [512]u8
	put_str_field(hdr[0:100], name_field)
	// For directories, ensure trailing slash in name if fits
	if e.kind == .Dir {
		nf := name_field
		if !strings.has_suffix(nf, "/") && len(nf) < 100 {
			tmp := fmt_tprintf_dir_name(nf)
			put_str_field(hdr[0:100], tmp)
		}
	}
	put_octal(hdr[100:108], e.mode, 7)
	put_octal(hdr[108:116], 0, 7) // uid
	put_octal(hdr[116:124], 0, 7) // gid
	put_octal(hdr[124:136], int(size), 11)
	put_octal(hdr[136:148], int(e.mtime), 11)
	// checksum field spaces for calculation
	for i in 148 ..< 156 {
		hdr[i] = ' '
	}
	hdr[156] = typeflag
	put_str_field(hdr[157:257], linkname)
	// magic ustar\0
	copy(hdr[257:263], transmute([]u8)string("ustar\x00"))
	hdr[263] = '0'
	hdr[264] = '0'
	put_str_field(hdr[265:297], "") // uname
	put_str_field(hdr[297:329], "") // gname
	put_str_field(hdr[329:337], "")
	put_str_field(hdr[337:345], "")
	put_str_field(hdr[345:500], prefix_field)

	// checksum
	sum: uint = 0
	for b in hdr {
		sum += uint(b)
	}
	put_octal_chksum(hdr[148:156], int(sum))

	append(buf, ..hdr[:])

	if e.kind == .File && len(e.data) > 0 {
		append(buf, ..e.data)
		pad := (512 - (len(e.data) % 512)) % 512
		append_zeros(buf, pad)
	}
	return true
}

fmt_tprintf_dir_name :: proc(nf: string) -> string {
	return strings.concatenate({nf, "/"}, context.temp_allocator)
}

split_ustar_name :: proc(path: string) -> (name, prefix: string, ok: bool) {
	if len(path) <= 100 {
		return path, "", true
	}
	// Try prefix/name split on a slash so name <= 100 and prefix <= 155
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			prefix = path[:i]
			name = path[i + 1:]
			if len(name) <= 100 && len(prefix) <= 155 && len(name) > 0 {
				return name, prefix, true
			}
		}
	}
	return "", "", false
}

put_str_field :: proc(dst: []u8, s: string) {
	for i in 0 ..< len(dst) {
		dst[i] = 0
	}
	n := min(len(s), len(dst))
	for i in 0 ..< n {
		dst[i] = s[i]
	}
}

// put_octal writes NUL-terminated octal into field of width (standard tar style).
put_octal :: proc(dst: []u8, value: int, digits: int) {
	for i in 0 ..< len(dst) {
		dst[i] = 0
	}
	// format as octal with leading zeros, leave last as NUL if room
	buf: [32]u8
	n := format_octal(buf[:], value, digits)
	// copy into dst: digits chars + NUL
	for i in 0 ..< min(n, len(dst) - 1) {
		dst[i] = buf[i]
	}
	if n < len(dst) {
		dst[n] = 0
	}
}

put_octal_chksum :: proc(dst: []u8, value: int) {
	// 6 octal digits, NUL, space
	for i in 0 ..< len(dst) {
		dst[i] = ' '
	}
	buf: [32]u8
	n := format_octal(buf[:], value, 6)
	for i in 0 ..< min(6, n) {
		dst[i] = buf[i]
	}
	dst[6] = 0
	dst[7] = ' '
}

format_octal :: proc(buf: []u8, value: int, width: int) -> int {
	// produce zero-padded octal string of exactly `width` digits when possible
	v := value
	if v < 0 {
		v = 0
	}
	// write from end
	tmp: [32]u8
	i := 0
	if v == 0 {
		tmp[0] = '0'
		i = 1
	} else {
		for v > 0 && i < len(tmp) {
			tmp[i] = u8('0' + (v & 7))
			v >>= 3
			i += 1
		}
	}
	// reverse into out with padding
	out_len := max(width, i)
	if out_len > len(buf) {
		out_len = len(buf)
	}
	for j in 0 ..< out_len {
		buf[j] = '0'
	}
	for j in 0 ..< i {
		buf[out_len - 1 - j] = tmp[j]
	}
	// if width specified, return width
	if width > 0 {
		return min(width, len(buf))
	}
	return out_len
}
