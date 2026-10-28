// stach: fast local backups. CLI parsing and mode dispatch: file/dir
// backups, list mode, and archive extraction. Sequential in this port;
// -j/-c are accepted and validated but do not parallelize yet.

import std;
import os;
import out;
import shim;
import pathutil;
import copy_file;
import tar_write;
import tar_read;
import list_mode;

fn print_usage(prog: const u8[:]) {
    var b: u8[>..] = [];
    format(b, "Usage: ", prog, " [--quiet] [-j N] [-c N] <file|directory|pattern> ...\n");
    format(b, "       ", prog, " [--quiet] [-c N] [-f list_file]\n");
    format(b, "       ", prog, " [-c N] -x <archive.tar.zst> [dest_dir]\n");
    format(b, "\n");
    format(b, "  Backup (default):\n");
    format(b, "    Files  -> copy to <path>.<timestamp>\n");
    format(b, "    Dirs   -> <path>.<timestamp>.tar.zst  (ustar + zstd level 1; symlinks/hardlinks)\n");
    format(b, "\n");
    format(b, "  List mode:\n");
    format(b, "    No paths -> pack entries of <dirname>.list into one <dirname>.<timestamp>.tar.zst\n");
    format(b, "    -f FILE  Use a custom list file (one path per line; '#' comments and\n");
    format(b, "             wildcards supported; missing entries warn and are skipped)\n");
    format(b, "\n");
    format(b, "  Extract:\n");
    format(b, "    -x     Unpack .tar.zst into dest_dir (default: .)\n");
    format(b, "\n");
    format(b, "  -j N   Max entities to process in parallel (default: CPU count)\n");
    format(b, "  -c N   multi-frame zstd workers + extract file writers (default: CPU count)\n");
    format(b, "  --quiet   Suppress all non-error output\n");
    format(b, "\n");
    format(b, "  Prints only: src -> dst and live pack progress\n");
    format(b, "  Errors go to stderr.\n");
    write_stderr(b);
}

fn parse_int_flag(s: const u8[:], n: i64&) -> bool {
    let v, ok = parse_int(s, 10);
    if !ok || v < 1 { return false; }
    n = v;
    return true;
}

// Backs up one top-level path: directories are packed, files (and symlinks)
// are copied with mode preserved.
fn entity_process(src_arg: const u8[:], ts: const u8[:], cores_n: i64,
                  text: u8[>..]&, payloads: u8[>..]&) -> bool {
    let src = strip_trailing_slashes(src_arg);

    if is_dot_or_dotdot(src) {
        errln("Error: Cannot backup '.' or '..' directly. Pass a named file or directory instead.");
        return false;
    }

    var st: Stach_Stat = default<Stach_Stat>();
    if !lstat_path(src, st) {
        var b: u8[>..] = [];
        format(b, "Error: Not found: ", src);
        errln(b);
        return false;
    }

    // os::is_dir follows symlinks, classifying a top-level link-to-dir as a
    // directory (the tree walk itself uses lstat).
    if is_dir(src) {
        let dst_start = text.len;
        dest_for_dir(src, ts, text);
        let dst = text[dst_start..];
        if tar_directory(src, dst, cores_n, text, payloads) {
            print_src_dst(src, dst);
            return true;
        }
        return false;
    }

    if st.typ == STACH_TYPE_FILE || st.typ == STACH_TYPE_SYMLINK {
        let dst_start = text.len;
        dest_for_file(src, ts, text);
        let dst = text[dst_start..];
        var msg: u8[>..] = [];
        if !copy_file_preserve(dst, src, msg) {
            var b: u8[>..] = [];
            format(b, "Error: copy ", src, " -> ", dst, ": ", msg);
            errln(b);
            return false;
        }
        print_src_dst(src, dst);
        return true;
    }

    var b: u8[>..] = [];
    format(b, "Error: Unsupported file type: ", src);
    errln(b);
    return false;
}

fn main() {
    var jobs_n = hardware_threads();
    var cores_n = jobs_n;
    if jobs_n < 1 { jobs_n = 1; }
    if cores_n < 1 { cores_n = 1; }

    var extract_mode = false;
    var list_file: const u8[:] = "";

    var patterns: const u8[:][>..] = [];

    let a = args();
    var i: i64 = 1;
    while i < a.len {
        let arg = a[i];
        if arg == "-h" || arg == "--help" {
            print_usage(arg0(a));
            exit(2);
        }
        if arg == "-x" {
            extract_mode = true;
            i += 1;
            continue;
        }
        if arg == "--quiet" {
            quiet_mode = true;
            i += 1;
            continue;
        }
        if arg == "-j" {
            if i + 1 >= a.len {
                errln("Error: -j requires a number");
                print_usage(arg0(a));
                exit(2);
            }
            if !parse_int_flag(a[i + 1], jobs_n) {
                var b: u8[>..] = [];
                format(b, "Error: invalid -j value: ", a[i + 1]);
                errln(b);
                exit(2);
            }
            i += 2;
            continue;
        }
        if starts_with(arg, "-j") && arg.len > 2 {
            if !parse_int_flag(arg[2..], jobs_n) {
                var b: u8[>..] = [];
                format(b, "Error: invalid -j value: ", arg[2..]);
                errln(b);
                exit(2);
            }
            i += 1;
            continue;
        }
        if arg == "-c" {
            if i + 1 >= a.len {
                errln("Error: -c requires a number");
                print_usage(arg0(a));
                exit(2);
            }
            if !parse_int_flag(a[i + 1], cores_n) {
                var b: u8[>..] = [];
                format(b, "Error: invalid -c value: ", a[i + 1]);
                errln(b);
                exit(2);
            }
            i += 2;
            continue;
        }
        if starts_with(arg, "-c") && arg.len > 2 {
            if !parse_int_flag(arg[2..], cores_n) {
                var b: u8[>..] = [];
                format(b, "Error: invalid -c value: ", arg[2..]);
                errln(b);
                exit(2);
            }
            i += 1;
            continue;
        }
        if arg == "-f" || arg == "--file" {
            if i + 1 >= a.len {
                var b: u8[>..] = [];
                format(b, "Error: ", arg, " requires a list file path");
                errln(b);
                print_usage(arg0(a));
                exit(2);
            }
            list_file = a[i + 1];
            i += 2;
            continue;
        }
        if starts_with(arg, "-f") && arg.len > 2 {
            list_file = arg[2..];
            i += 1;
            continue;
        }
        if starts_with(arg, "-") {
            var b: u8[>..] = [];
            format(b, "Error: unknown option: ", arg);
            errln(b);
            print_usage(arg0(a));
            exit(2);
        }
        patterns.push(arg);
        i += 1;
    }

    if extract_mode {
        if list_file.len != 0 {
            errln("Error: -f cannot be combined with -x");
            print_usage(arg0(a));
            exit(2);
        }
        if patterns.len < 1 || patterns.len > 2 {
            errln("Error: -x requires <archive.tar.zst> [dest_dir]");
            print_usage(arg0(a));
            exit(2);
        }
        let archive = patterns[0];
        let dest: const u8[:] = if patterns.len == 2 { patterns[1] } else { "." };
        if extract_tar_zst(archive, dest, cores_n) {
            print_src_dst(archive, dest);
            exit(0);
        }
        exit(1);
    }

    // List mode: explicit -f, or no paths and a default <cwd-basename>.list.
    var arena: u8[>..] = [];
    var payloads: u8[>..] = [];
    let is_default_list = list_file.len == 0 && patterns.len == 0;
    let list_path: const u8[:] = if is_default_list { default_list_file(arena) } else { list_file };
    if list_path.len != 0 {
        if patterns.len > 0 {
            errln("Error: -f / list mode cannot be combined with path arguments");
            print_usage(arg0(a));
            exit(2);
        }
        var lexists: Stach_Stat = default<Stach_Stat>();
        if !lstat_path(list_path, lexists) {
            var b: u8[>..] = [];
            format(b, "Error: list file not found: ", list_path);
            errln(b);
            exit(1);
        }
        if run_list_mode(list_path, cores_n, arena, payloads) {
            exit(0);
        }
        exit(1);
    }

    if patterns.len == 0 {
        print_usage(arg0(a));
        exit(2);
    }

    var paths: const u8[:][>..] = [];
    let expand_err = expand_patterns(patterns, paths, arena);
    if paths.len == 0 {
        exit(1);
    }

    let ts_start = arena.len;
    timestamp_now(arena);
    let ts = arena[ts_start..];

    var any_fail = expand_err;
    for p in paths {
        if !entity_process(p, ts, cores_n, arena, payloads) {
            any_fail = true;
        }
    }

    if any_fail {
        exit(1);
    }
}

// args()[0], the program name.
fn arg0(a: u8[:][>..]&) -> const u8[:] {
    if a.len > 0 { return a[0]; }
    return "stach";
}
