// Packing: walk a tree with lstat, build a ustar archive in memory
// (multi-frame zstd, level 1), write <dst>. Shared by directory backups and
// list mode. All strings live in caller-owned arena builders; file payloads
// accumulate in one shared payload arena.

import std;
import os;
import out;
import shim;
import pathutil;
import dictionary;

// Minimum uncompressed tar bytes per zstd frame when multi-frame packing.
let ZSTD_FRAME_CHUNK_MIN = 1048576; // 1 MiB

let PROGRESS_ENTRY_STEP = 32;

enum Tar_Kind { File, Dir, Symlink, Hardlink }

struct Tar_Entry {
    kind: Tar_Kind,
    fullpath: const u8[:],
    entry_name: const u8[:], // archive path, no leading ./ ; dirs end with /
    link_target: const u8[:], // symlink target or hardlink path inside archive
    mode: u32,
    mtime: i64,
    size: i64,
    data: const u8[:], // file payload view into the payload arena
}

struct Tar_Pack_Progress {
    label: const u8[:],
    total_entries: i64,
    packed_entries: i64,
    total_payload: i64,
    packed_payload: i64,
    last_render_entries: i64,
    last_render_width: i64,
}

// A directory queued for traversal: start/length of its path in the text
// arena (flat offsets, so no slice provenance flows through the stack).
struct Walk_Dir { ps: i64, pl: i64 }

// mode_from_info: permission bits with 0755/0644 defaults for mode-less files.
fn mode_from_stat(st: Stach_Stat&) -> u32 {
    let m = st.mode & 511;
    if m == 0 {
        if st.typ == STACH_TYPE_DIR { return 493; } // 0755
        return 420;                                 // 0644
    }
    return m;
}

// tar_directory writes the src tree to dst as zstd-compressed ustar.
fn tar_directory(src_path: const u8[:], dst_path: const u8[:], compress_workers: i64,
                 text: u8[>..]&, payloads: u8[>..]&) -> bool {
    let src = strip_trailing_slashes(src_path);
    let base_name = path_base(src);
    if base_name.len == 0 || base_name == "." || base_name == ".." {
        var b: u8[>..] = [];
        format(b, "Error: Cannot backup '", src, "'");
        errln(b);
        return false;
    }

    var ino_text: u8[>..] = [];
    var seen_inos: dictionary<const u8[:], u8[..1024]> = dictionary<const u8[:], u8[..1024]> {};
    var entries: Tar_Entry[>..] = [];
    if !collect_tree_entries(src, base_name, entries, text, payloads, ino_text, seen_inos) {
        return false;
    }

    return pack_tar_entries(base_name, entries, dst_path, compress_workers);
}

// pack_tar_entries renders progress, builds the ustar buffer, compresses it
// with multi-frame zstd and writes dst_path. Shared by tar_directory and list mode.
fn pack_tar_entries(label: const u8[:], entries: Tar_Entry[>..]&, dst_path: const u8[:],
                    compress_workers: i64) -> bool {
    let workers = max(1, compress_workers);

    var exists: Stach_Stat = default<Stach_Stat>();
    if lstat_path(dst_path, exists) {
        var b: u8[>..] = [];
        format(b, "Error: Destination exists: ", dst_path);
        errln(b);
        return false;
    }

    var p: Tar_Pack_Progress = default<Tar_Pack_Progress>();
    p.label = label;
    p.total_entries = entries.len;
    for e in entries {
        if e.kind == Tar_Kind.File { p.total_payload += e.size; }
    }
    render_pack_progress(p, true);

    var tar: u8[>..] = [];
    for e in entries {
        if !append_tar_entry(tar, e) {
            finish_pack_progress(p, false);
            var b: u8[>..] = [];
            format(b, "Error: Failed to pack entry: ", e.fullpath);
            errln(b);
            return false;
        }
        advance_pack_progress(p, e);
    }
    finish_pack_progress(p, false);
    // Two zero blocks end the archive.
    push_n(tar, 0, 1024);

    var phase: u8[>..] = [];
    format(phase, "Packing ", label, ": Compressing zstd (", workers, " workers)");
    print_progress_update(phase, false);

    var comp: u8[>..<] = [];
    if !zstd_compress_tar(tar, workers, comp) {
        finish_pack_progress(p, false);
        var b: u8[>..] = [];
        format(b, "Error: zstd compress failed for ", label);
        errln(b);
        return false;
    }

    var phase2: u8[>..] = [];
    format(phase2, "Packing ", label, ": Writing archive");
    print_progress_update(phase2, false);
    if !write_file(dst_path, comp) {
        finish_pack_progress(p, false);
        delete_file(dst_path);
        var b: u8[>..] = [];
        format(b, "Error: write ", dst_path);
        errln(b);
        return false;
    }
    finish_pack_progress(p, true);
    return true;
}

// zstd_compress_tar emits one or more independent zstd frames so extract can
// decompress them one by one. Level 1 for fast backups. Frames are produced
// sequentially in this port.
fn zstd_compress_tar(tar: u8[:], workers: i64, out: u8[>..<]&) -> bool {
    let tar_len = tar.len;

    // Single frame when small or single worker.
    if workers == 1 || tar_len <= ZSTD_FRAME_CHUNK_MIN {
        return zstd_compress_frame(tar, workers, out);
    }

    // Target ~workers*4 chunks, each at least CHUNK_MIN (except last).
    let chunk_size = max(ZSTD_FRAME_CHUNK_MIN, (tar_len + workers * 4 - 1) / (workers * 4));
    var off: i64 = 0;
    while off < tar_len {
        let end = min(off + chunk_size, tar_len);
        if !zstd_compress_frame(tar[off..end], 1, out) { return false; }
        off = end;
    }
    return true;
}

// Compresses one frame's worth of bytes onto out; restores out on failure.
fn zstd_compress_frame(src: u8[:], workers: i64, out: u8[>..<]&) -> bool {
    let bound = stach_zstd_compress_bound(src.len);
    let base = out.len;
    push_n(out, 0, bound);
    let dst: u8[:] = out[base..base + bound];
    var produced: i64 = 0;
    let ok = stach_zstd_compress_into(src, 1, workers as i32, dst, produced) == 0 && produced > 0;
    if !ok {
        out.resize(base);
        return false;
    }
    out.resize(base + produced);
    return true;
}

fn advance_pack_progress(p: Tar_Pack_Progress&, e: Tar_Entry&) {
    p.packed_entries += 1;
    if e.kind == Tar_Kind.File { p.packed_payload += e.size; }
    render_pack_progress(p, false);
}

fn render_pack_progress(p: Tar_Pack_Progress&, force: bool) {
    if quiet_mode { return; }
    if !force {
        if p.packed_entries != p.total_entries {
            if p.packed_entries - p.last_render_entries < PROGRESS_ENTRY_STEP { return; }
        }
    }

    var percent = 100.0;
    if p.total_entries > 0 {
        percent = 100.0 * p.packed_entries / p.total_entries;
    }
    var b: u8[>..] = [];
    format(b, "Packing ", p.label, ": ", p.packed_entries, "/", p.total_entries, " entries (");
    format_flt(b, percent, 1);
    format(b, "%), ");
    human_payload(b, p.packed_payload);
    format(b, "/");
    human_payload(b, p.total_payload);

    if p.last_render_width > b.len {
        push_n(b, ' ', p.last_render_width - b.len);
    }
    print_progress_update(b, false);
    p.last_render_entries = p.packed_entries;
    p.last_render_width = b.len;
}

fn finish_pack_progress(p: Tar_Pack_Progress&, success: bool) {
    if quiet_mode { return; }
    if success {
        var b: u8[>..] = [];
        format(b, "Packed ", p.label, ": ", p.packed_entries, "/", p.total_entries, " entries (");
        format_flt(b, 100.0, 1);
        format(b, "%), ");
        human_payload(b, p.packed_payload);
        format(b, "/");
        human_payload(b, p.total_payload);
        if p.last_render_width > b.len {
            push_n(b, ' ', p.last_render_width - b.len);
        }
        print_progress_update(b, true);
        p.last_render_width = b.len;
        return;
    }
    if p.last_render_width > 0 {
        var b: u8[>..] = [];
        push_n(b, ' ', p.last_render_width);
        print_progress_update(b, true);
    }
}

fn human_payload(out: u8[>..]&, n: i64) {
    if n < 1024 {
        format(out, n, " B");
    } else if n < 1048576 {
        format_flt(out, n / 1024.0, 1);
        format(out, " KiB");
    } else if n < 1073741824 {
        format_flt(out, n / 1048576.0, 1);
        format(out, " MiB");
    } else {
        format_flt(out, n / 1073741824.0, 1);
        format(out, " GiB");
    }
}

// --- tree collection ---------------------------------------------------------

// Walks directory src with lstat, appending entries named under root_name.
// seen_inos is shared so hardlinks dedupe across multiple roots (list mode).
// Directories are traversed depth-first in sorted order via an explicit
// stack (Goose forbids resizable locals across recursive calls).

fn collect_tree_entries(src: const u8[:], root_name: const u8[:], entries: Tar_Entry[>..]&,
                        text: u8[>..]&, payloads: u8[>..]&, ino_text: u8[>..]&,
                        seen_inos: dictionary<const u8[:], u8[..1024]>&) -> bool {
    var st: Stach_Stat = default<Stach_Stat>();
    if !lstat_path(src, st) {
        var b: u8[>..] = [];
        format(b, "Error: lstat ", src, " failed");
        errln(b);
        return false;
    }

    // The tree root path joins the text arena so every queued directory is
    // an offset pair into it (flat values on the stack; slices stored in
    // array elements re-root and cannot be stored into entries).
    let src_start = text.len;
    text.append(src);
    let root_entry = entry_name_for(text, src, src, root_name, true);
    append_dir_entry(entries, src, root_entry, mode_from_stat(st), st.mtime);

    var dirs: Walk_Dir[>..] = [];
    var top: i64 = 0;
    dirs.push(Walk_Dir { ps: src_start, pl: src.len });
    top += 1;

    while top > 0 {
        top -= 1;
        let d = dirs[top];
        let dpath: const u8[:] = text[d.ps..d.ps + d.pl];

        var names: u8[>..] = [];
        if !list_dir(dpath, names) {
            var b: u8[>..] = [];
            format(b, "Error: walking ", dpath, " failed");
            errln(b);
            return false;
        }

        // Files, symlinks and specials in sorted order.
        for name in split(names, '\n') {
            if name.len == 0 { continue; }
            let fs = child_path(text, dpath, name);
            let fp: const u8[:] = text[fs..];
            if !collect_child(entries, text, payloads, ino_text, seen_inos, src, fp, root_name) { return false; }
        }

        // Directories: append their entries in order, then queue them in
        // reverse so the LIFO stack explores depth-first, sorted.
        var subdirs: Walk_Dir[>..] = [];
        var stop: i64 = 0;
        for name in split(names, '\n') {
            if name.len == 0 { continue; }
            let fs = child_path(text, dpath, name);
            let fpl = text.len - fs;
            let fp: const u8[:] = text[fs..fs + fpl];
            var cst: Stach_Stat = default<Stach_Stat>();
            if !lstat_path(fp, cst) {
                var b: u8[>..] = [];
                format(b, "Error: lstat ", fp, " failed");
                errln(b);
                return false;
            }
            if cst.typ != STACH_TYPE_DIR { continue; }
            let dent = entry_name_for(text, src, fp, root_name, true);
            append_dir_entry(entries, fp, dent, mode_from_stat(cst), cst.mtime);
            if stop == subdirs.len { subdirs.push(Walk_Dir { ps: fs, pl: fpl }); }
            else { subdirs[stop] = Walk_Dir { ps: fs, pl: fpl }; }
            stop += 1;
        }
        var si = stop - 1;
        while si >= 0 {
            if top == dirs.len { dirs.push(subdirs[si]); }
            else { dirs[top] = subdirs[si]; }
            top += 1;
            si -= 1;
        }
    }
    return true;
}

// Appends "dir + '/' + name" to the text arena; returns the start offset.
fn child_path(text: u8[>..]&, dir: const u8[:], name: const u8[:]) -> i64 {
    let start = text.len;
    if dir.len == 1 && dir[0] == '/' {
        text.push('/');
        text.append(name);
    } else {
        text.append(dir);
        text.push('/');
        text.append(name);
    }
    return start;
}

// Appends the archive member name for fullpath under the tree root.
fn entry_name_for(text: u8[>..]&, src_root: const u8[:], fullpath: const u8[:],
                  base_name: const u8[:], is_dir: bool) -> const u8[:] {
    let start = text.len;
    archive_entry_name(src_root, fullpath, base_name, is_dir, text);
    return text[start..];
}

fn append_dir_entry(entries: Tar_Entry[>..]&, fullpath: const u8[:], entry_name: const u8[:],
                    mode: u32, mtime: i64) {
    entries.push(Tar_Entry {
        kind: Tar_Kind.Dir,
        fullpath: fullpath,
        entry_name: entry_name,
        link_target: "",
        mode: mode,
        mtime: mtime,
        size: 0,
        data: "",
    });
}

// Handles one non-directory child: symlink, regular file (with hardlink
// dedupe) or special (warned and skipped). Returns false on hard errors.
// root is the tree root path member names are relative to.
fn collect_child(entries: Tar_Entry[>..]&, text: u8[>..]&, payloads: u8[>..]&,
                 ino_text: u8[>..]&, seen_inos: dictionary<const u8[:], u8[..1024]>&,
                 root: const u8[:], fp: const u8[:], root_name: const u8[:]) -> bool {
    var st: Stach_Stat = default<Stach_Stat>();
    if !lstat_path(fp, st) {
        var b: u8[>..] = [];
        format(b, "Error: lstat ", fp, " failed");
        errln(b);
        return false;
    }

    if st.typ == STACH_TYPE_SYMLINK {
        var buf: u8[4096] = [0; 4096];
        let n = stach_readlink(fp, buf);
        if n < 0 {
            var b: u8[>..] = [];
            format(b, "Error: readlink ", fp, " failed");
            errln(b);
            return false;
        }
        let tstart = text.len;
        text.append(buf[..n]);
        let target = text[tstart..];
        let name = entry_name_for(text, root, fp, root_name, false);
        entries.push(Tar_Entry {
            kind: Tar_Kind.Symlink,
            fullpath: fp,
            entry_name: name,
            link_target: target,
            mode: 511, // 0777, convention for symlink entries
            mtime: st.mtime,
            size: 0,
            data: "",
        });
        return true;
    }

    if st.typ == STACH_TYPE_DIR { return true; } // directories handled in the dirs pass

    if st.typ != STACH_TYPE_FILE {
        var b: u8[>..] = [];
        format(b, "Error: skipping special file: ", fp);
        errln(b);
        return true; // not fatal
    }

    let name = entry_name_for(text, root, fp, root_name, false);

    // Hardlink if this inode was already stored as a regular file.
    if st.ino != 0 && name.len < 1020 {
        let kstart = ino_text.len;
        format(ino_text, st.dev, "/", st.ino);
        let key = ino_text[kstart..];
        let first = get(seen_inos, key);
        if first {
            // Copy the first name into the arena: dictionary slots are
            // grow-shrink, so their contents cannot be stored into entries.
            let tstart = text.len;
            text.append(first[..]);
            entries.push(Tar_Entry {
                kind: Tar_Kind.Hardlink,
                fullpath: fp,
                entry_name: name,
                link_target: text[tstart..],
                mode: mode_from_stat(st),
                mtime: st.mtime,
                size: 0,
                data: "",
            });
            return true;
        }
    }

    // Regular file: store the payload, then remember the first archive name
    // for this inode (Odin's version stopped walking a directory at the first
    // duplicate inode here — a stray `break`; this port keeps walking).
    let pstart = payloads.len;
    if !read_file(fp, payloads) {
        var b: u8[>..] = [];
        format(b, "Error: read ", fp, " failed");
        errln(b);
        return false;
    }
    if st.ino != 0 && name.len < 1020 {
        let kstart = ino_text.len;
        format(ino_text, st.dev, "/", st.ino);
        insert(seen_inos, ino_text[kstart..], limited_of(name));
    }
    entries.push(Tar_Entry {
        kind: Tar_Kind.File,
        fullpath: fp,
        entry_name: name,
        link_target: "",
        mode: mode_from_stat(st),
        mtime: st.mtime,
        size: payloads.len - pstart,
        data: payloads[pstart..],
    });
    return true;
}

// Copies name into a fixed-size value for the seen-inode dictionary.
fn limited_of(name: const u8[:]) -> u8[..1024] {
    var v: u8[..1024] = [];
    v.append(name);
    return v;
}

// Adds one top-level regular file or symlink to entries under an explicit
// archive name. Used by list mode for non-directory lines. Special files are
// warned about and skipped (not an error).
fn append_single_entry(fullpath: const u8[:], entry_name: const u8[:], entries: Tar_Entry[>..]&,
                       text: u8[>..]&, payloads: u8[>..]&, ino_text: u8[>..]&,
                       seen_inos: dictionary<const u8[:], u8[..1024]>&) -> bool {

    var st: Stach_Stat = default<Stach_Stat>();
    if !lstat_path(fullpath, st) {
        var b: u8[>..] = [];
        format(b, "Error: lstat ", fullpath, " failed");
        errln(b);
        return false;
    }

    if st.typ == STACH_TYPE_SYMLINK {
        var buf: u8[4096] = [0; 4096];
        let n = stach_readlink(fullpath, buf);
        if n < 0 {
            var b: u8[>..] = [];
            format(b, "Error: readlink ", fullpath, " failed");
            errln(b);
            return false;
        }
        let tstart = text.len;
        text.append(buf[..n]);
        let target = text[tstart..];
        let nstart = text.len;
        text.append(entry_name);
        entries.push(Tar_Entry {
            kind: Tar_Kind.Symlink,
            fullpath: fullpath,
            entry_name: text[nstart..],
            link_target: target,
            mode: 511,
            mtime: st.mtime,
            size: 0,
            data: "",
        });
        return true;
    }

    if st.typ != STACH_TYPE_FILE {
        var b: u8[>..] = [];
        format(b, "Warning: skip (special file): ", fullpath);
        errln(b);
        return true;
    }

    // Hardlink if this inode was already stored as a regular file.
    if st.ino != 0 && entry_name.len < 1020 {
        let kstart = ino_text.len;
        format(ino_text, st.dev, "/", st.ino);
        let key = ino_text[kstart..];
        let first = get(seen_inos, key);
        if first {
            let tstart = text.len;
            text.append(first[..]);
            let nstart = text.len;
            text.append(entry_name);
            entries.push(Tar_Entry {
                kind: Tar_Kind.Hardlink,
                fullpath: fullpath,
                entry_name: text[nstart..],
                link_target: text[tstart..],
                mode: mode_from_stat(st),
                mtime: st.mtime,
                size: 0,
                data: "",
            });
            return true;
        }
        let pstart = payloads.len;
        if !read_file(fullpath, payloads) {
            var b: u8[>..] = [];
            format(b, "Error: read ", fullpath, " failed");
            errln(b);
            return false;
        }
        insert(seen_inos, key, limited_of(entry_name));
        let nstart = text.len;
        text.append(entry_name);
        entries.push(Tar_Entry {
            kind: Tar_Kind.File,
            fullpath: fullpath,
            entry_name: text[nstart..],
            link_target: "",
            mode: mode_from_stat(st),
            mtime: st.mtime,
            size: payloads.len - pstart,
            data: payloads[pstart..],
        });
        return true;
    }

    let pstart = payloads.len;
    if !read_file(fullpath, payloads) {
        var b: u8[>..] = [];
        format(b, "Error: read ", fullpath, " failed");
        errln(b);
        return false;
    }
    let nstart = text.len;
    text.append(entry_name);
    entries.push(Tar_Entry {
        kind: Tar_Kind.File,
        fullpath: fullpath,
        entry_name: text[nstart..],
        link_target: "",
        mode: mode_from_stat(st),
        mtime: st.mtime,
        size: payloads.len - pstart,
        data: payloads[pstart..],
    });
    return true;
}

// --- ustar serialization ------------------------------------------------------

// Appends one 512-byte header (+ payload and padding for files) for e.
fn append_tar_entry(buf: u8[>..]&, e: Tar_Entry&) -> bool {
    var hdr: u8[512] = [0; 512];

    // ustar name limit 100, prefix 155; trailing slashes trimmed via view.
    var name: const u8[:] = e.entry_name;
    if name.len > 0 && name[name.len - 1] == '/' { name = name[..name.len - 1]; }
    var name_field: u8[..128] = [];
    var prefix_field: u8[..160] = [];
    if !split_ustar_name(name, name_field, prefix_field) {
        var b: u8[>..] = [];
        format(b, "Error: path too long for ustar: ", name);
        errln(b);
        return false;
    }

    var typeflag: u8 = '0';
    var size: i64 = 0;
    match e.kind {
        File => block {
            typeflag = '0';
            size = e.size;
        },
        Dir => block {
            typeflag = '5';
            size = 0;
        },
        Symlink => block {
            typeflag = '2';
            size = 0;
        },
        Hardlink => block {
            typeflag = '1';
            size = 0;
        },
    }

    if e.link_target.len > 100 {
        var b: u8[>..] = [];
        format(b, "Error: link target too long: ", e.link_target);
        errln(b);
        return false;
    }

    put_str_field(hdr[0..100], name_field);
    // Directories: trailing slash in the name field when it fits.
    if e.kind == Tar_Kind.Dir && !(name_field.len > 0 && name_field[name_field.len - 1] == '/') &&
       name_field.len < 100 {
        var tmp: u8[..128] = [];
        tmp.append(name_field);
        tmp.push('/');
        put_str_field(hdr[0..100], tmp);
    }
    put_octal(hdr[100..108], e.mode, 7);
    put_octal(hdr[108..116], 0, 7); // uid
    put_octal(hdr[116..124], 0, 7); // gid
    put_octal(hdr[124..136], size, 11);
    put_octal(hdr[136..148], e.mtime, 11);
    // Checksum field as spaces for the calculation.
    for i in 148..156 { hdr[i] = ' '; }
    hdr[156] = typeflag;
    put_str_field(hdr[157..257], e.link_target);
    // magic "ustar\0", version "00"
    hdr[257] = 'u';
    hdr[258] = 's';
    hdr[259] = 't';
    hdr[260] = 'a';
    hdr[261] = 'r';
    hdr[262] = 0;
    hdr[263] = '0';
    hdr[264] = '0';
    put_str_field(hdr[265..297], ""); // uname
    put_str_field(hdr[297..329], ""); // gname
    put_str_field(hdr[329..337], ""); // devmajor
    put_str_field(hdr[337..345], ""); // devminor
    put_str_field(hdr[345..500], prefix_field);

    // Checksum over the whole header with the field as spaces.
    var sum: u32 = 0;
    for b in hdr { sum += b; }
    put_octal_chksum(hdr[148..156], sum);

    buf.append(hdr);

    if e.kind == Tar_Kind.File && e.data.len > 0 {
        buf.append(e.data);
        let pad_len = (512 - (e.data.len % 512)) % 512;
        if pad_len > 0 { push_n(buf, 0, pad_len); }
    }
    return true;
}

// Splits path into (name <= 100, prefix <= 155); name_field/prefix_field are
// limited-array out params. False when no split fits.
fn split_ustar_name(path: const u8[:], name_field: u8[..128]&, prefix_field: u8[..160]&) -> bool {
    if path.len <= 100 {
        name_field.append(path);
        return true;
    }
    // Try prefix/name splits from the right so name <= 100 and prefix <= 155.
    var i = path.len - 1;
    while i >= 0 {
        if path[i] == '/' {
            let nlen = path.len - 1 - i;
            if nlen <= 100 && i <= 155 && nlen > 0 {
                name_field.append(path[i + 1..]);
                prefix_field.append(path[..i]);
                return true;
            }
        }
        i -= 1;
    }
    return false;
}

fn put_str_field(dst: u8[:], s: const u8[:]) {
    for i in dst.len { dst[i] = 0; }
    let n = min(s.len, dst.len);
    for i in n { dst[i] = s[i]; }
}

// Writes NUL-terminated octal into a field of the given digit width.
fn put_octal(dst: u8[:], value: i64, digits: i64) {
    for i in dst.len { dst[i] = 0; }
    var tmp: u8[32] = [0; 32];
    let n = format_octal(tmp, value, digits);
    let cpy = min(n, dst.len - 1);
    for i in cpy { dst[i] = tmp[i]; }
    if n < dst.len {
        dst[n] = 0;
    }
}

// 6 octal digits, NUL, space.
fn put_octal_chksum(dst: u8[:], value: i64) {
    for i in dst.len { dst[i] = ' '; }
    var tmp: u8[32] = [0; 32];
    let n = format_octal(tmp, value, 6);
    let cpy = min(6, n);
    for i in cpy { dst[i] = tmp[i]; }
    dst[6] = 0;
    dst[7] = ' ';
}

// Zero-padded octal of exactly `width` digits (when it fits); returns the
// number of digits produced (== width when width > 0).
fn format_octal(buf: u8[:], value: i64, width: i64) -> i64 {
    var v = value;
    if v < 0 { v = 0; }
    var tmp: u8[32] = [0; 32];
    var i: i64 = 0;
    if v == 0 {
        tmp[0] = '0';
        i = 1;
    } else {
        while v > 0 && i < 32 {
            tmp[i] = '0' + ((v % 8) as u8);
            v /= 8;
            i += 1;
        }
    }
    var out_len = max(width, i);
    if out_len > buf.len { out_len = buf.len; }
    for j in out_len { buf[j] = '0'; }
    for j in i { buf[out_len - 1 - j] = tmp[j]; }
    if width > 0 {
        return min(width, buf.len);
    }
    return out_len;
}
