package main

import "core:c"

when ODIN_OS == .Windows {
	foreign import stachgz {
		"../build/stachgz.lib",
	}
} else {
	foreign import stachgz {
		"../build/libstachgz.a",
	}
}

@(default_calling_convention = "c")
foreign stachgz {
	// Compress src into one gzip member (RFC 1952). Returns a malloc'd
	// buffer (free with stach_free); nil on failure.
	stach_gzip_compress :: proc(
		src: [^]u8,
		src_len: c.size_t,
		level: c.int,
		out_len: ^c.size_t,
	) -> [^]u8 ---

	// Inflate a full multi-member gzip stream into one malloc'd buffer,
	// verifying each member's CRC32 + ISIZE trailer. nil on failure.
	stach_gzip_decompress :: proc(
		src: [^]u8,
		src_len: c.size_t,
		out_len: ^c.size_t,
	) -> [^]u8 ---

	stach_free :: proc(p: rawptr) ---
}
