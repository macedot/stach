// C bridge: extern bindings to vendor/stach_zstd_wrap.c (libzstd) and
// vendor/stach_shim.c (filesystem operations the Goose stdlib lacks).
// The C side mirrors these signatures; byte buffers cross as slices
// ({ data, len } structs by value) and Stach_Stat matches the C stach_stat
// field for field (u64 u64 u64 i64 u32 i32).

// --- filesystem shim (vendor/stach_shim.c) ---

let STACH_TYPE_OTHER = 0;
let STACH_TYPE_FILE = 1;
let STACH_TYPE_DIR = 2;
let STACH_TYPE_SYMLINK = 3;

struct Stach_Stat { dev: u64, ino: u64, size: u64, mtime: i64, mode: u32, typ: i32 }

extern fn stach_lstat(path: const u8[:], out: Stach_Stat&) -> i32;
extern fn stach_readlink(path: const u8[:], buf: u8[:]) -> i64;
extern fn stach_symlink(target: const u8[:], linkpath: const u8[:], target_is_dir: i32) -> i32;
extern fn stach_hardlink(existing: const u8[:], newpath: const u8[:]) -> i32;
extern fn stach_chmod(path: const u8[:], mode: u32) -> i32;
extern fn stach_getcwd(buf: u8[:]) -> i64;

// lstat + classify in one call; false when the path does not exist.
fn lstat_path(path: const u8[:], out: Stach_Stat&) -> bool {
    return stach_lstat(path, out) == 0;
}

// --- zstd wrapper (vendor/stach_zstd_wrap.c) ---

extern fn stach_zstd_compress_bound(src_len: i64) -> i64;
extern fn stach_zstd_compress_into(src: const u8[:], level: i32, workers: i32,
                                   dst: u8[:], out_len: i64&) -> i32;
extern fn stach_zstd_frame_compressed_size(src: const u8[:]) -> i64;
extern fn stach_zstd_frame_content_size(src: const u8[:]) -> i64;
extern fn stach_zstd_decompress_into(src: const u8[:], dst: u8[:], out_len: i64&) -> i32;
