// List mode: pack every entry of a list file into a single timestamped
// .tar.zst. List file format: one path per line, '#' comments and blank
// lines ignored, '*'/'?'/'[' wildcards expanded, missing entries warned and
// skipped.

import std;
import os;
import out;
import shim;
import pathutil;
import tar_write;

// Appends the cleaned entry lines to lines, backed by arena.
fn parse_list_file(path: const u8[:], lines: const u8[:][>..]&, arena: u8[>..]&) -> bool {
    var data: u8[>..] = [];
    if !read_file(path, data) {
        var b: u8[>..] = [];
        format(b, "Error: read list file ", path, " failed");
        errln(b);
        return false;
    }

    var line_start: i64 = 0;
    var i: i64 = 0;
    while i <= data.len {
        if i == data.len || data[i] == '\n' {
            var line = data[line_start..i];
            line_start = i + 1;
            // trim whitespace (handles \r\n too)
            var lo: i64 = 0;
            var hi = line.len;
            while lo < hi && (line[lo] == ' ' || line[lo] == '\t' || line[lo] == '\r') { lo += 1; }
            while hi > lo && (line[hi - 1] == ' ' || line[hi - 1] == '\t' || line[hi - 1] == '\r') { hi -= 1; }
            let t = line[lo..hi];
            if t.len > 0 && t[0] != '#' {
                let start = arena.len;
                arena.append(t);
                lines.push(arena[start..]);
            }
        }
        i += 1;
    }
    return true;
}

// Computes the tar member root for a resolved list path: relative paths are
// stored as written (leading ./ stripped); absolute paths are stored with
// the leading slash stripped. Result appended to arena.
fn list_entry_root_name(path: const u8[:], arena: u8[>..]&) -> const u8[:] {
    let p = strip_trailing_slashes(path);
    let start = arena.len;
    var s: i64 = 0;
    while s + 1 < p.len && p[s] == '.' && p[s + 1] == '/' { s += 2; }
    if p[s] == '/' || p[s] == '\\' {
        while s < p.len && (p[s] == '/' || p[s] == '\\') { s += 1; }
    }
    arena.append(p[s..]);
    return arena[start..];
}

// Expands list lines into existing paths (deduped, arena-backed). Missing
// paths and unmatched wildcards warn and are skipped.
fn resolve_list_entries(lines: const u8[:][>..]&, out: const u8[:][>..]&, arena: u8[>..]&) {
    var seen: dictionary<const u8[:], bool> = dictionary<const u8[:], bool> {};

    for line in lines {
        let p = strip_trailing_slashes(line);
        if p.len == 0 { continue; }

        if has_glob_meta(p) {
            var matches: const u8[:][>..] = [];
            if !expand_glob(p, matches, arena) {
                var b: u8[>..] = [];
                format(b, "Warning: skip (no matches): ", p);
                errln(b);
            }
            for m in matches {
                append_unique_resolved(out, seen, arena, m);
            }
            continue;
        }

        var st: Stach_Stat = default<Stach_Stat>();
        if !lstat_path(p, st) {
            var b: u8[>..] = [];
            format(b, "Warning: skip (not found): ", p);
            errln(b);
            continue;
        }
        append_unique_resolved(out, seen, arena, p);
    }
}

fn append_unique_resolved(out: const u8[:][>..]&, seen: dictionary<const u8[:], bool>&,
                          arena: u8[>..]&, path: const u8[:]) {
    let p = strip_trailing_slashes(path);
    if p.len == 0 || p == "." || p == ".." { return; }
    if contains(seen, p) { return; }
    let start = arena.len;
    arena.append(p);
    let v = arena[start..];
    insert(seen, v, true);
    out.push(v);
}

// Packs all entries of list_path into one <cwd basename>.<timestamp>.tar.zst
// in the current directory.
fn run_list_mode(list_path: const u8[:], compress_workers: i64,
                 text: u8[>..]&, payloads: u8[>..]&) -> bool {
    var lines: const u8[:][>..] = [];
    if !parse_list_file(list_path, lines, text) {
        return false;
    }
    if lines.len == 0 {
        var b: u8[>..] = [];
        format(b, "Error: no entries in list file: ", list_path);
        errln(b);
        return false;
    }

    var resolved: const u8[:][>..] = [];
    resolve_list_entries(lines, resolved, text);
    if resolved.len == 0 {
        var b: u8[>..] = [];
        format(b, "Error: nothing to backup from list: ", list_path);
        errln(b);
        return false;
    }

    var entries: Tar_Entry[>..] = [];
    var ino_text: u8[>..] = [];
    var seen_inos: dictionary<const u8[:], u8[..1024]> = dictionary<const u8[:], u8[..1024]> {};

    var ok = true;
    for path in resolved {
        let root_name = list_entry_root_name(path, text);
        if root_name.len == 0 {
            var b: u8[>..] = [];
            format(b, "Warning: skip (no archive name): ", path);
            errln(b);
            continue;
        }
        if is_dir(path) {
            if !collect_tree_entries(path, root_name, entries, text, payloads, ino_text, seen_inos) {
                ok = false;
            }
        } else {
            if !append_single_entry(path, root_name, entries, text, payloads, ino_text, seen_inos) {
                ok = false;
            }
        }
        if !ok { break; }
    }
    if !ok || entries.len == 0 {
        if ok {
            var b: u8[>..] = [];
            format(b, "Error: nothing to backup from list: ", list_path);
            errln(b);
        }
        return false;
    }

    var cwd_buf: u8[4096] = [0; 4096];
    let n = stach_getcwd(cwd_buf);
    if n < 0 {
        errln("Error: get working directory failed");
        return false;
    }
    let label = path_base(cwd_buf[..n]);

    let ts_start = text.len;
    timestamp_now(text);
    let ts = text[ts_start..];

    let dst_start = text.len;
    dest_for_dir(label, ts, text);
    let dst = text[dst_start..];

    if !pack_tar_entries(label, entries, dst, compress_workers) {
        return false;
    }
    print_src_dst(label, dst);
    return true;
}

// Appends "<cwd basename>.list" to arena when that file exists, else "".
fn default_list_file(arena: u8[>..]&) -> const u8[:] {
    var cwd_buf: u8[4096] = [0; 4096];
    let n = stach_getcwd(cwd_buf);
    if n < 0 { return ""; }
    let base = path_base(cwd_buf[..n]);
    if base.len == 0 { return ""; }
    let start = arena.len;
    format(arena, base, ".list");
    let candidate = arena[start..];
    if file_exists(candidate) { return candidate; }
    return "";
}
