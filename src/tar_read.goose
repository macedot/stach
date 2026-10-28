// Extraction: scan zstd frames, decompress sequentially, parse the ustar
// stream into operations, then apply them in phases (directories, files,
// symlinks, hardlinks) with path-safety checks. Payloads are views into the
// decompressed tar buffer; paths accumulate in a caller-owned arena.

import std;
import os;
import out;
import shim;
import pathutil;

enum Extract_Kind { Dir, File, Symlink, Hardlink }

struct Extract_Op {
    kind: Extract_Kind,
    path: const u8[:],      // destination path (from safe_join)
    link_target: const u8[:], // symlink text or hardlink target path
    mode: i64,
    payload: const u8[:],   // view into the tar buffer for files
}

struct Zstd_Frame {
    comp_off: i64,
    comp_len: i64,
    out_off: i64,
    out_len: i64,
}

// extract_tar_zst unpacks a zstd-compressed tar into dest_dir.
fn extract_tar_zst(archive: const u8[:], dest_dir: const u8[:], workers: i64) -> bool {
    var exists: Stach_Stat = default<Stach_Stat>();
    if !lstat_path(archive, exists) {
        var b: u8[>..] = [];
        format(b, "Error: Not found: ", archive);
        errln(b);
        return false;
    }

    let dest: const u8[:] = if dest_dir.len == 0 { "." } else { dest_dir };

    if !mkdir_all(dest) {
        var b: u8[>..] = [];
        format(b, "Error: mkdir ", dest);
        errln(b);
        return false;
    }

    var zst: u8[>..] = [];
    if !read_file(archive, zst) {
        var b: u8[>..] = [];
        format(b, "Error: read ", archive, " failed");
        errln(b);
        return false;
    }

    var tar: u8[>..] = [];
    if !zstd_decompress_all(zst, tar) {
        var b: u8[>..] = [];
        format(b, "Error: zstd decompress failed for ", archive);
        errln(b);
        return false;
    }

    return extract_tar_bytes(tar, dest, workers);
}

// Scans independent frames and inflates them one by one. Single-frame
// archives (and multi-frame, from this port or parallel builds) both work.
fn zstd_decompress_all(zst: u8[>..]&, tar: u8[>..]&) -> bool {
    var frames: Zstd_Frame[>..] = [];
    if !zstd_scan_frames(zst, frames) { return false; }

    if frames.len == 0 { return true; }

    var total_out: i64 = 0;
    for f in frames { total_out += f.out_len; }
    push_n(tar, 0, total_out);

    for f in frames {
        let src: const u8[:] = zst[f.comp_off..f.comp_off + f.comp_len];
        let dst: u8[:] = tar[f.out_off..f.out_off + f.out_len];
        var produced: i64 = 0;
        if stach_zstd_decompress_into(src, dst, produced) != 0 || produced != f.out_len {
            tar.resize(0);
            return false;
        }
    }
    return true;
}

fn zstd_scan_frames(zst: u8[>..]&, frames: Zstd_Frame[>..]&) -> bool {
    var off: i64 = 0;
    var out_off: i64 = 0;
    let UNKNOWN: i64 = -1;
    while off < zst.len {
        let remain: const u8[:] = zst[off..];
        let csize = stach_zstd_frame_compressed_size(remain);
        if csize == 0 || csize > remain.len {
            return false;
        }
        let usize = stach_zstd_frame_content_size(zst[off..off + csize]);
        if usize == UNKNOWN {
            return false;
        }
        frames.push(Zstd_Frame { comp_off: off, comp_len: csize, out_off: out_off, out_len: usize });
        off += csize;
        out_off += usize;
    }
    return true;
}

fn extract_tar_bytes(data: u8[>..]&, dest_dir: const u8[:], workers: i64) -> bool {
    var ops: Extract_Op[>..] = [];
    var text: u8[>..] = [];
    if !parse_tar_ops(data, dest_dir, ops, text) {
        return false;
    }

    // Phase D: directories first.
    for op in ops {
        if op.kind != Extract_Kind.Dir { continue; }
        if !mkdir_all(op.path) {
            var b: u8[>..] = [];
            format(b, "Error: mkdir ", op.path);
            errln(b);
            return false;
        }
        let m = perm_from_mode(op.mode, true);
        if m != 0 { stach_chmod(op.path, m); }
    }

    // Phase F: regular files.
    for op in ops {
        if op.kind != Extract_Kind.File { continue; }
        var parent: u8[>..] = [];
        dir_of(parent, op.path);
        if !mkdir_all(parent) {
            var b: u8[>..] = [];
            format(b, "Error: mkdir ", parent);
            errln(b);
            return false;
        }
        if !write_file(op.path, op.payload) {
            var b: u8[>..] = [];
            format(b, "Error: write ", op.path);
            errln(b);
            return false;
        }
        let m = perm_from_mode(op.mode, false);
        if m != 0 { stach_chmod(op.path, m); }
    }

    // Phase L: symlinks then hardlinks (targets must exist).
    for op in ops {
        if op.kind != Extract_Kind.Symlink { continue; }
        var parent: u8[>..] = [];
        dir_of(parent, op.path);
        if !mkdir_all(parent) {
            var b: u8[>..] = [];
            format(b, "Error: mkdir ", parent);
            errln(b);
            return false;
        }
        var exists: Stach_Stat = default<Stach_Stat>();
        if lstat_path(op.path, exists) { delete_file(op.path); }
        if stach_symlink(op.link_target, op.path, 0) != 0 {
            var b: u8[>..] = [];
            format(b, "Error: symlink ", op.path, " -> ", op.link_target);
            errln(b);
            return false;
        }
    }
    for op in ops {
        if op.kind != Extract_Kind.Hardlink { continue; }
        var parent: u8[>..] = [];
        dir_of(parent, op.path);
        if !mkdir_all(parent) {
            var b: u8[>..] = [];
            format(b, "Error: mkdir ", parent);
            errln(b);
            return false;
        }
        var exists: Stach_Stat = default<Stach_Stat>();
        if lstat_path(op.path, exists) { delete_file(op.path); }
        if stach_hardlink(op.link_target, op.path) != 0 {
            var b: u8[>..] = [];
            format(b, "Error: link ", op.path, " -> ", op.link_target);
            errln(b);
            return false;
        }
    }
    return true;
}

// Parses the ustar stream into extract operations. names and targets are
// appended to the text arena; payloads stay views into data.
fn parse_tar_ops(data: u8[>..]&, dest_dir: const u8[:], ops: Extract_Op[>..]&,
                 text: u8[>..]&) -> bool {
    var off: i64 = 0;
    while off + 512 <= data.len {
        let hdr: const u8[:] = data[off..off + 512];
        off += 512;

        if is_zero_block(hdr) {
            // End of archive (one or two zero blocks).
            return true;
        }

        var name: const u8[:] = ustar_full_name(hdr, text);
        if name.len == 0 {
            errln("Error: empty tar member name");
            return false;
        }

        let typeflag = hdr[156];
        let size = parse_octal(hdr[124..136]);
        let linkname: const u8[:] = cstr_field(hdr[157..257]);
        let mode = parse_octal(hdr[100..108]);

        // Consume payload + padding; payload is a view into data.
        var payload: const u8[:] = data[0..0]; // rooted at data so rebinding stays legal
        var have_payload = false;
        if size > 0 {
            if off + size > data.len {
                var b: u8[>..] = [];
                format(b, "Error: truncated tar payload for ", name);
                errln(b);
                return false;
            }
            payload = data[off..off + size];
            have_payload = true;
            off += size;
            off += (512 - (size % 512)) % 512;
        }

        // pax / gnu long name — skip unsupported special types with data.
        if typeflag == 'x' || typeflag == 'g' || typeflag == 'L' || typeflag == 'K' {
            continue;
        }

        let safe, sok = safe_join(dest_dir, name, text);
        if !sok {
            var b: u8[>..] = [];
            format(b, "Error: unsafe path in archive: ", name);
            errln(b);
            return false;
        }

        if typeflag == '5' || typeflag == 'D' {
            ops.push(Extract_Op { kind: Extract_Kind.Dir, path: safe, link_target: "", mode: mode, payload: "" });
        } else if typeflag == '2' {
            let lstart = text.len;
            text.append(linkname);
            ops.push(Extract_Op { kind: Extract_Kind.Symlink, path: safe, link_target: text[lstart..], mode: mode, payload: "" });
        } else if typeflag == '1' {
            let target, tok = safe_join(dest_dir, linkname, text);
            if !tok {
                var b: u8[>..] = [];
                format(b, "Error: unsafe hardlink target: ", linkname);
                errln(b);
                return false;
            }
            ops.push(Extract_Op { kind: Extract_Kind.Hardlink, path: safe, link_target: target, mode: mode, payload: "" });
        } else if typeflag == '0' || typeflag == 0 || typeflag == '7' {
            ops.push(Extract_Op { kind: Extract_Kind.File, path: safe, link_target: "", mode: mode, payload: payload });
        }
        // Other typeflags are skipped.
    }
    return true;
}

fn is_zero_block(b: const u8[:]) -> bool {
    for x in b {
        if x != 0 { return false; }
    }
    return true;
}

// The bytes of a NUL-terminated header field, as a view.
fn cstr_field(b: const u8[:]) -> const u8[:] {
    var n: i64 = 0;
    while n < b.len && b[n] != 0 { n += 1; }
    return b[..n];
}

// prefix + "/" + name for ustar split names, appended to the arena.
fn ustar_full_name(hdr: const u8[:], text: u8[>..]&) -> const u8[:] {
    let name = cstr_field(hdr[0..100]);
    let prefix = cstr_field(hdr[345..500]);
    let start = text.len;
    if prefix.len == 0 {
        text.append(name);
    } else {
        text.append(prefix);
        text.push('/');
        text.append(name);
    }
    // Trim trailing slashes via the arena copy.
    let end = text.len;
    var e = end;
    while e > start && text[e - 1] == '/' { e -= 1; }
    return text[start..e];
}

fn parse_octal(b: const u8[:]) -> i64 {
    let s = cstr_field(b);
    var i: i64 = 0;
    while i < s.len && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') { i += 1; }
    var v: i64 = 0;
    while i < s.len {
        let c = s[i];
        if c < '0' || c > '7' { break; }
        v = v * 8 + (c - '0');
        i += 1;
    }
    return v;
}

// safe_join ensures the result stays under dest_dir (no absolute, no ..).
// The joined path is appended to the arena on success.
fn safe_join(dest_dir: const u8[:], name: const u8[:], text: u8[>..]&) -> const u8[:], bool {
    // Strip leading slashes.
    var s: i64 = 0;
    while s < name.len && (name[s] == '/' || name[s] == '\\') { s += 1; }
    if s == name.len { return "", false; }

    // Normalize and reject .. (and backslash segments).
    var b: u8[>..] = [];
    var seg_start: i64 = s;
    for i in s..name.len + 1 {
        if i < name.len && name[i] != '/' { continue; }
        let seg = name[seg_start..i];
        seg_start = i + 1;
        if seg.len == 0 || seg == "." { continue; }
        if seg == ".." { return "", false; }
        var has_bslash = false;
        for c in seg {
            if c == '\\' { has_bslash = true; }
        }
        if has_bslash { return "", false; }
        if b.len > 0 { b.push('/'); }
        b.append(seg);
    }
    if b.len == 0 { return "", false; }

    // Join onto dest_dir (a leading "./" is dropped, like filepath.join).
    let start = text.len;
    if dest_dir.len > 0 && dest_dir != "." {
        text.append(dest_dir);
        if dest_dir[dest_dir.len - 1] != '/' { text.push('/'); }
    }
    text.append(b);
    let vs2 = if text.len - start > 1 && text[start] == '.' && text[start + 1] == '/' { start + 2 } else { start };
    return text[vs2..], true;
}

fn perm_from_mode(mode: i64, is_dir: bool) -> u32 {
    let m = mode & 511;
    if m == 0 { return 0; } // keep defaults when the archive stores none
    return m as u32;
}

// mkdir -p: create every prefix, then the path itself; true if it is a
// directory afterwards.
fn mkdir_all(path: const u8[:]) -> bool {
    if path.len == 0 { return false; }
    var prefix: u8[>..] = [];
    for i in path.len {
        prefix.push(path[i]);
        if path[i] == '/' && i > 0 {
            make_dir(prefix);
        }
    }
    make_dir(prefix);
    return is_dir(path);
}
