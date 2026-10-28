// File copy with mode preservation, like cp -p. Refuses to overwrite.

import std;
import os;
import out;
import shim;

// Copies a regular file (or symlink; reads through) to dst. On failure
// returns false and appends a short reason to msg.
fn copy_file_preserve(dst: const u8[:], src: const u8[:], msg: u8[>..]&) -> bool {
    var exists: Stach_Stat = default<Stach_Stat>();
    if lstat_path(dst, exists) {
        format(msg, "destination exists");
        return false;
    }

    var st: Stach_Stat = default<Stach_Stat>();
    if !lstat_path(src, st) {
        format(msg, "cannot stat source");
        return false;
    }
    if st.typ == STACH_TYPE_DIR {
        format(msg, "is a directory");
        return false;
    }
    if st.typ == STACH_TYPE_OTHER {
        format(msg, "unsupported file type");
        return false;
    }

    var data: u8[>..] = [];
    if !read_file(src, data) {
        format(msg, "read failed");
        return false;
    }
    if !write_file(dst, data) {
        format(msg, "write failed");
        return false;
    }

    // Best-effort mode preserve (like cp -p mode bits).
    stach_chmod(dst, st.mode & 511);
    return true;
}
