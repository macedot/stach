// Output helpers: quiet mode, stderr errors, stdout src -> dst lines and
// \r progress updates. Single-threaded, so no print mutex is needed.

import os;

var quiet_mode: bool = false;

// One error line to stderr (always printed, even under --quiet).
fn errln(msg: u8[:]) {
    write_stderr(msg);
    write_stderr("\n");
}

// var b: u8[>..] = []; format(b, ...); errln(b);
// is the idiom at call sites.

// The canonical success line, stdout, suppressed by --quiet.
fn print_src_dst(src: u8[:], dst: u8[:]) {
    if quiet_mode { return; }
    var b: u8[>..] = [];
    format(b, src, " -> ", dst, "\n");
    write_stdout(b);
}

// Progress line overwriting itself with \r; done=true ends with \n.
fn print_progress_update(line: u8[:], done: bool = false) {
    if quiet_mode { return; }
    var b: u8[>..] = [];
    if done {
        format(b, "\r", line, "\n");
    } else {
        format(b, "\r", line);
    }
    write_stdout(b);
}
