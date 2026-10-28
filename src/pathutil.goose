// Path helpers: timestamps, slash handling, glob expansion, destination
// names and tar member names. String results land in caller-owned arenas
// (grow-only builders): memory never moves, so the slice views handed out
// stay valid however much is appended afterwards.

import std;
import os;
import out;
import shim;

// --- timestamp -----------------------------------------------------------

// Formats the current UTC wall-clock time as YYYYMMDDHHMMSS into out.
fn timestamp_now(out: u8[>..]&) {
    let secs = time_ns() / 1000000000;
    let days = secs / 86400;
    let sod = secs % 86400; // Euclidean: 0..86399

    // Civil-from-days (Howard Hinnant's algorithm): days since 1970-01-01
    // into proleptic Gregorian year/month/day.
    var z = days + 719468;
    let era = (z - (z % 146097)) / 146097;
    let doe = z - era * 146097;                                   // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    var y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);            // [0, 365]
    let mp = (5 * doy + 2) / 153;                                 // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1;                         // [1, 31]
    var m = mp + (if mp < 10 { 3 } else { -9 });                  // [1, 12]
    y += (if m <= 2 { 1 } else { 0 });

    let hh = sod / 3600;
    let mi = (sod % 3600) / 60;
    let ss = sod % 60;

    format_int(out, y, 10, 4, '0');
    format_int(out, m, 10, 2, '0');
    format_int(out, d, 10, 2, '0');
    format_int(out, hh, 10, 2, '0');
    format_int(out, mi, 10, 2, '0');
    format_int(out, ss, 10, 2, '0');
}

// --- slashes and bases ----------------------------------------------------

// Removes trailing / or \ (except a lone root "/"). Returns a view.
fn strip_trailing_slashes(path: u8[:]) -> u8[:] {
    var n = path.len;
    while n > 1 && (path[n - 1] == '/' || path[n - 1] == '\\') { n -= 1; }
    return path[..n];
}

// The final path component ("", "." and ".." pass through).
fn path_base(path: u8[:]) -> u8[:] {
    var p = strip_trailing_slashes(path);
    var i = p.len - 1;
    while i >= 0 {
        if p[i] == '/' || p[i] == '\\' { return p[i + 1..]; }
        i -= 1;
    }
    return p;
}

fn is_dot_or_dotdot(path: u8[:]) -> bool {
    let b = path_base(path);
    return b == "." || b == ".." || b == "";
}

// Joins two path fragments with one '/'; empty pieces vanish, "a/" + "b"
// stays "a/b". Result appended to out.
fn path_join(out: u8[>..]&, a: u8[:], b: u8[:]) {
    var need_sep = false;
    let start = out.len;
    if a.len > 0 {
        out.append(a);
        need_sep = a[a.len - 1] != '/';
    }
    if b.len > 0 {
        if need_sep && !(b[0] == '/') { out.push('/'); }
        out.append(b);
    }
    if out.len == start && a.len == 0 && b.len == 0 { out.push('.'); }
}

// Appends the directory part of path to out: "a/b" -> "a", "b" -> ".",
// "/a" -> "/", "a/" -> ".".
fn dir_of(out: u8[>..]&, path: const u8[:]) {
    var n = path.len;
    while n > 1 && (path[n - 1] == '/' || path[n - 1] == '\\') { n -= 1; }
    var i = n - 1;
    while i >= 0 {
        if path[i] == '/' || path[i] == '\\' {
            if i == 0 {
                out.push('/');
            } else {
                out.append(path[..i]);
            }
            return;
        }
        i -= 1;
    }
    out.push('.');
}

// --- glob ------------------------------------------------------------------

fn has_glob_meta(pattern: u8[:]) -> bool {
    for c in pattern {
        if c == '*' || c == '?' || c == '[' { return true; }
    }
    return false;
}

// fnmatch-style match of one path segment: * crosses within the segment,
// ? is one byte, [..] classes with ranges and leading ! negation.
fn glob_seg_match(pat: u8[:], name: u8[:]) -> bool {
    var pi = 0;
    var ni = 0;
    var star = -1;
    var star_ni = 0;
    while ni < name.len {
        if pi < pat.len {
            let c = pat[pi];
            if c == '*' {
                star = pi;
                star_ni = ni;
                pi += 1;
                continue;
            }
            if c == '?' { pi += 1; ni += 1; continue; }
            if c == '[' {
                // find closing ]
                var j = pi + 1;
                var negate = false;
                if j < pat.len && (pat[j] == '!' || pat[j] == '^') { negate = true; j += 1; }
                var matched = false;
                var first = true;
                var closed = false;
                while j < pat.len {
                    if pat[j] == ']' && !first { closed = true; j += 1; break; }
                    first = false;
                    var lo = pat[j];
                    var hi = lo;
                    if j + 2 < pat.len && pat[j + 1] == '-' && pat[j + 2] != ']' {
                        hi = pat[j + 2];
                        j += 3;
                    } else {
                        j += 1;
                    }
                    if name[ni] >= lo && name[ni] <= hi { matched = true; }
                }
                if !closed {
                    // Unclosed class: treat '[' literally.
                    if name[ni] == '[' { pi += 1; ni += 1; continue; }
                } else if matched != negate {
                    pi = j;
                    ni += 1;
                    continue;
                }
            }
            // Literal character (or failed class): must match here.
            if pat[pi] == name[ni] {
                pi += 1;
                ni += 1;
                continue;
            }
        }
        if star >= 0 {
            star_ni += 1;
            ni = star_ni;
            pi = star + 1;
            continue;
        }
        return false;
    }
    while pi < pat.len && pat[pi] == '*' { pi += 1; }
    return pi == pat.len;
}

// Expands one glob pattern into existing paths, appending each to arena and
// pushing views onto out. Returns false when nothing matches. Iterative DFS
// (Goose forbids resizable locals across recursive calls), matching in
// lexicographic order per directory level.
struct Glob_Job { prefix: const u8[:], seg: i64 }

fn expand_glob(pattern: u8[:], out: const u8[:][>..]&, arena: u8[>..]&) -> bool {
    var before = out.len;
    var segs: const u8[:][>..] = [];
    var abs = false;
    if pattern.len > 0 && pattern[0] == '/' { abs = true; }
    for seg in split(pattern, '/') {
        if seg.len > 0 { segs.push(seg); }
    }
    if segs.len == 0 { return false; }

    var jobs: Glob_Job[>..<] = [];
    let root: const u8[:] = if abs { "/" } else { "" };
    jobs.push(Glob_Job { prefix: root, seg: 0 });

    while jobs.len > 0 {
        let job = jobs.pop();
        let seg = segs[job.seg];
        let last = job.seg == segs.len - 1;

        if !has_glob_meta(seg) {
            var cand: u8[>..] = [];
            if job.prefix.len == 0 { cand.append(seg); } else { path_join(cand, job.prefix, seg); }
            var st: Stach_Stat = default<Stach_Stat>();
            if lstat_path(cand, st) {
                if last {
                    out.push(arena_store(cand, arena));
                } else if st.typ == STACH_TYPE_DIR {
                    jobs.push(Glob_Job { prefix: arena_store(cand, arena), seg: job.seg + 1 });
                }
            }
            continue;
        }

        // Meta segment: match against the directory listing.
        var dirb: u8[>..] = [];
        if job.prefix.len == 0 { dirb.push('.'); } else { dirb.append(job.prefix); }
        var names: u8[>..] = [];
        if !list_dir(dirb, names) { continue; }

        // First the non-directories (emitted in listed, i.e. sorted, order),
        // then directories pushed in reverse so the LIFO stack explores
        // subtrees in sorted order.
        for name in split(names, '\n') {
            if name.len == 0 { continue; }
            if !glob_seg_match(seg, name) { continue; }
            var cand: u8[>..] = [];
            if job.prefix.len == 0 { cand.append(name); } else { path_join(cand, job.prefix, name); }
            var st: Stach_Stat = default<Stach_Stat>();
            if lstat_path(cand, st) && last && st.typ != STACH_TYPE_DIR {
                out.push(arena_store(cand, arena));
            }
        }
        var dirs: const u8[:][>..] = [];
        for name in split(names, '\n') {
            if name.len == 0 { continue; }
            if !glob_seg_match(seg, name) { continue; }
            var cand: u8[>..] = [];
            if job.prefix.len == 0 { cand.append(name); } else { path_join(cand, job.prefix, name); }
            var st: Stach_Stat = default<Stach_Stat>();
            if lstat_path(cand, st) && st.typ == STACH_TYPE_DIR {
                if last {
                    out.push(arena_store(cand, arena));
                } else {
                    dirs.push(arena_store(cand, arena));
                }
            }
        }
        var di = dirs.len - 1;
        while di >= 0 {
            jobs.push(Glob_Job { prefix: dirs[di], seg: job.seg + 1 });
            di -= 1;
        }
    }
    return out.len > before;
}

// Copies candidate bytes into the arena and returns the stable view.
fn arena_store(cand: u8[>..]&, arena: u8[>..]&) -> const u8[:] {
    let start = arena.len;
    arena.append(cand);
    return arena[start..];
}

// --- CLI arg expansion ------------------------------------------------------

// Turns CLI args into concrete existing paths. Unmatched patterns and
// missing paths report errors and set the any-error flag.
fn expand_patterns(patterns: const u8[:][>..]&, out: const u8[:][>..]&, arena: u8[>..]&) -> bool {
    var any_error = false;
    for pat in patterns {
        let pre = strip_trailing_slashes(pat);
        let p: const u8[:] = if pre.len == 0 { "." } else { pre };

        if has_glob_meta(p) {
            if !expand_glob(p, out, arena) {
                var b: u8[>..] = [];
                format(b, "Error: No match: ", p);
                errln(b);
                any_error = true;
            }
        } else {
            var st: Stach_Stat = default<Stach_Stat>();
            if !lstat_path(p, st) {
                var b: u8[>..] = [];
                format(b, "Error: Not found: ", p);
                errln(b);
                any_error = true;
                continue;
            }
            let start = arena.len;
            arena.append(p);
            out.push(arena[start..]);
        }
    }
    return any_error;
}

// --- destination names -------------------------------------------------------

fn dest_for_file(src: u8[:], ts: u8[:], out: u8[>..]&) {
    format(out, src, ".", ts);
}

fn dest_for_dir(src: u8[:], ts: u8[:], out: u8[>..]&) {
    format(out, src, ".", ts, ".tar.zst");
}

// --- tar member names ---------------------------------------------------------

// Builds the archive member path for fullpath under src_root, labelled with
// base_name: root itself -> base_name, children -> base_name/suffix, with
// backslashes normalized to '/' and a trailing '/' on directories.
fn archive_entry_name(src_root: u8[:], fullpath: u8[:], base_name: u8[:], is_dir: bool, out: u8[>..]&) {
    let root = strip_trailing_slashes(src_root);
    let fp = strip_trailing_slashes(fullpath);

    out.append(base_name);
    if fp != root {
        if fp.len > root.len && starts_with(fp, root) &&
           (fp[root.len] == '/' || fp[root.len] == '\\') {
            out.push('/');
            for c in fp[root.len + 1..] {
                out.push(if c == '\\' { '/' } else { c });
            }
        } else {
            let b = path_base(fp);
            if b.len > 0 {
                out.push('/');
                for c in b {
                    out.push(if c == '\\' { '/' } else { c });
                }
            }
        }
    }
    if is_dir {
        if out.len == 0 || out[out.len - 1] != '/' { out.push('/'); }
    }
}
