# stach — Workspace Instructions

## What is this project?

**stach** is a small, dependency-free CLI for fast local backups, written in [Goose](https://aardappel.github.io/goose/) (v2026.3). Point it at files or directories and it produces timestamped copies next to the originals:

- Regular file → byte copy `<path>.<YYYYMMDDHHMMSS>` (mode preserved, like `cp -p`)
- Directory → `<path>.<YYYYMMDDHHMMSS>.tar.zst` archive (ustar + zstd level 1; preserves symlinks and hardlinks)
- List mode → no paths + `<cwd-basename>.list` (or `-f FILE`): pack all list entries into **one** `<cwd-basename>.<YYYYMMDDHHMMSS>.tar.zst`
- Extract with `stach -x <archive.tar.zst> [dest_dir]`; stach archives are also readable by system `zstd -d | tar -x`

Compression uses embedded zstd (vendored C source), so no system zstd is needed at runtime. License: AGPL-3.0; bundled zstd retains its own licenses (`vendor/zstd/LICENSE`, `vendor/zstd/COPYING`).

CLI flags: `-j N` (parallel top-level paths), `-c N` (multi-frame zstd workers + parallel extract file writers), `-f FILE` (list mode with custom list; default is `<cwd-basename>.list` when present), `--quiet` (suppress all non-error output). `-j`/`-c` accept both separated and joined forms (`-j 4`, `-j4`). Both default to CPU count. Timestamps are UTC. **This Goose port runs backups sequentially** — `-j`/`-c` are parsed and validated, but the three thread pools of the Odin version are not ported yet; archive output is byte-compatible.

## Layout

| Path | Role |
|------|------|
| `src/main.goose` | CLI parsing, list-mode dispatch, sequential backup loop, entry point |
| `src/list_mode.goose` | List-file parse/resolve/pack: default `<cwd>.list`, `-f`, multi-root single archive |
| `src/pathutil.goose` | UTC timestamps (civil-from-days), glob matching/expansion, dest path + tar entry naming |
| `src/out.goose` | `quiet_mode` global, stderr/stdout print helpers, `\r` progress |
| `src/shim.goose` | `extern fn` declarations bridging to the C layer (zstd wrapper + fs shim) |
| `src/copy_file.goose` | File copy with mode preservation; refuses to overwrite existing dst |
| `src/tar_write.goose` | ustar writer + multi-frame (sequential) zstd packer + pack progress; shared `collect_tree_entries` / `append_single_entry` |
| `src/tar_read.goose` | ustar reader + frame-scan decompressor + phased extractor + `safe_join` path-safety |
| `src/main.build` | goose sidecar: compiles vendored zstd sources + wrapper + shim into the program |
| `vendor/zstd/` | Embedded zstd library (C), compiled unmodified |
| `vendor/stach_zstd_wrap.c` | Thin C wrapper: bound+fill one-shot compress, frame-size scan helpers |
| `vendor/stach_shim.c` | POSIX/Win32 fs shim: lstat, readlink, symlink, hardlink, chmod, getcwd (UTF-8 paths, UTF-16 on Windows) |
| `benchmark/bench.sh` | Compression algorithm benchmark (zstd/lz4/gzip/xz/brotli/store vs embedded zstd); tracked results in `benchmark/RESULTS.md` + `results.csv` |
| `.github/workflows/release.yml` | Multi-arch release CI |

## Build & Test

```bash
make          # Build ./stach (requires goose + a C compiler)
make check    # Typecheck only
./stach       # No args: list mode if <cwd-basename>.list exists; else usage, exit 2
make test     # Functional smoke tests (bash-driven, uses mktemp -d)
make clean    # Remove the binary
```

Build pipeline: `goose build src/main.goose` compiles the Goose sources to C and compiles/links every `c_sources` entry from `src/main.build` (the ~27 vendored zstd `.c` files, `stach_zstd_wrap.c`, `stach_shim.c`; `ZSTD_DISABLE_ASM=1`, no zstd multi-threading). The sidecar sets `output = "../stach"`, so the binary lands at the repo root. Build intermediates live under `~/.goose` (`GOOSE_HOME`); there is no separate C library step anymore.

Requirements: the goose compiler on PATH (download from goose's GitHub releases; the compiler locates its stdlib beside itself) and a C compiler (`cc` / MSVC).

## Platform-Specific Notes

- All C is compiled per-platform by `goose build`; no linker-flag or static-archive merging is needed.
- `vendor/stach_shim.c` has POSIX and Win32 branches. Windows: paths are converted UTF-8 → UTF-16; symlink creation uses `CreateSymbolicLinkW` (may require admin/developer mode), hardlinks `CreateHardLinkW`.
- zstd is compiled without assembler (`ZSTD_DISABLE_ASM=1`) and without multi-threading, so no pthread linkage is required anywhere.
- No cross-compilation: goose builds with a native C compiler, so CI uses one native runner per target.

## Architecture

One Goose package across 9 files in `src/`; `std`/`os`/`dictionary` stdlib plus the C bridge.

- **Memory model**: no manual allocation. Strings live in caller-owned grow-only "arena" builders (`u8[>..]`); string lists are arrays of slice views into those arenas (views stay valid as arenas grow — memory never moves). File payloads accumulate in one shared payload arena; the tar buffer is grow-only. Compressed output uses a grow-shrink `u8[>..<]` scratch (`push_n` to the zstd bound, fill through a slice window, `resize` down to the produced length). Recursion is avoided where resizable locals would stay live across recursive calls (tree walk and glob use explicit stacks of flat values/offsets).
- **Backup flow**: `main` expands glob patterns → sequential loop over top-level paths (`-j` reserved). Files go through `copy_file_preserve` (read → write → chmod); directories go through `tar_directory`: iterative lstat walk (hardlinks deduped by `dev:ino` in a dictionary; `.`/`..` skipped) → ustar in memory (typeflags `0` file, `5` dir, `2` symlink, `1` hardlink) → multi-frame zstd → write `.tar.zst`.
- **List mode**: when `-f FILE` is set, or when there are no path args and `<cwd-basename>.list` exists, `run_list_mode` parses the list (skip `#`/blank, expand globs, warn+skip missing), collects entries from every root with a shared seen-inodes dictionary, then packs once into `<cwd-basename>.<ts>.tar.zst`. Absolute list paths store members with the leading `/` stripped.
- **Multi-frame zstd**: when `-c` > 1 and the tar exceeds `ZSTD_FRAME_CHUNK_MIN` (1 MiB, `src/tar_write.goose`), the tar is split into ~`workers*4` chunks, each compressed as an independent zstd frame, concatenated. (Frames are produced sequentially in this port.) Extract scans frame boundaries and inflates each frame into a pre-sized buffer.
- **Extract flow** (`src/tar_read.goose`): decompress → parse ustar into ops → create dirs (+chmod) → write regular files (+chmod) → apply symlinks, then hardlinks (targets must exist first).
- **Errors**: helpers return `bool`; errors print to stderr via `errln` (`src/out.goose`). Exit codes: `0` success, `1` any path failed, `2` usage/flag errors (also `-h`/`--help`).

## Coding Conventions

- Goose, stdlib imports only (`std`, `os`, `dictionary`) plus the C bridge (`shim.goose`)
- Read-only string parameters are `const u8[:]`; string literals are `const u8[:]`, so a mutable slot that may hold a literal must be declared `var x: const u8[:]`
- A slot holding a slice can only ever bind to one *root*: use single `let` bindings (`let p = if cond { "." } else { view };`) instead of re-assigning across roots; never store slices that root at grow-shrink arrays (dictionary slots, `[>..<]` elements) into long-lived structures — copy them through a grow-only arena first
- Errors go to stderr; progress and `src -> dst` mapping lines go to stdout
- `--quiet` (`quiet_mode` global in `src/out.goose`) suppresses all non-error output, including progress
- Match arms bind enum variants unqualified (`File =>`); variant values are qualified (`Tar_Kind.File`)
- `_` is not a discard identifier; call value-returning functions as plain statements

## Testing

`make test` is the only test suite — a bash script embedded in the Makefile that builds the binary and runs end-to-end scenarios in a `mktemp` dir: file copy, nested tree pack/extract, symlink and hardlink round-trips, `--quiet` (asserts empty stdout/stderr), a larger multi-frame pack (`-c 4`, ~1.75 MiB mixed compressible/random data), and list mode (default `<basename>.list` + `-f` / `--quiet`, including missing-entry warnings and single-archive assertion). It asserts exact `src -> dst` output lines and byte-identical extraction via `diff`. There are no Goose unit tests.

## Safety / Security Considerations

- Never overwrites: backup fails if the destination path already exists (`copy_file_preserve`, `pack_tar_entries`)
- Extract rejects path traversal before writing: `safe_join` (`src/tar_read.goose`) strips leading slashes and rejects `..` segments, backslashes, and absolute names; hardlink targets are validated the same way
- `.` / `..` cannot be backed up directly
- ustar limits enforced: name ≤ 100 / prefix ≤ 155 bytes (split on `/`), link target ≤ 100 bytes
- Special files (fifos, sockets, devices) are skipped with an error message during pack

## CI / Releases

Publishing a GitHub Release triggers `.github/workflows/release.yml`, which builds on 4 native runners (each installs the goose compiler from its GitHub releases; **note**: no Linux arm64 goose compiler exists yet, so that target fails until one is published upstream), smoke-tests "no args → exit 2", and uploads:

- `stach-linux-amd64.tar.gz`
- `stach-linux-arm64.tar.gz` (pending upstream goose arm64 support)
- `stach-darwin-arm64.tar.gz`
- `stach-windows-amd64.zip` (goose build finds MSVC itself)

## .gitignore Mode

Deny-all whitelist: only explicitly listed paths are tracked (`src/`, `vendor/`, `testdata/`, `.github/`, root docs/Makefile). Build artifacts, binaries, and object files inside allowed trees are still excluded.

## History

The project was originally written in Odin (see `main` branch history); this `goose` branch is a behavior-faithful port. A partially completed Zig conversion that existed in the working tree before the port was preserved on the `zig-wip` branch.
