<h1 align="center">stach</h1>

<p align="center"><strong>Standalone timestamped backups — files, folders, symlinks, hardlinks</strong></p>

<p align="center">
  <img src="https://img.shields.io/github/license/macedot/stach?color=blue" alt="License" />
  <img src="https://img.shields.io/badge/Odin-dev--2026-blueviolet" alt="Odin" />
  <img src="https://img.shields.io/badge/platform-linux%20%7C%20macOS%20%7C%20windows-lightgrey" alt="Platforms" />
  <img src="https://img.shields.io/github/v/release/macedot/stach?display_name=tag" alt="Release" />
</p>

---

**stach** is a small, dependency-free CLI for fast local backups. Point it at files or directories and get timestamped copies: plain files are duplicated beside the original; directories become a single **`.tgz`** (ustar + gzip) that preserves **symlinks** and **hardlinks**. Unpack with `stach -x` or any standard `tar -xzf` / `gzip -d`.

Written in [Odin](https://odin-lang.org/). Compression uses embedded [miniz](https://github.com/richgel999/miniz) (gzip, level 6, parallelized across archive members). No system `gzip` required at runtime.

> **Upgrading from v1.0.0:** archives are now gzip (`.tgz`). `stach -x` no longer reads the old `.tar.zst` archives — unpack those with v1.0.0 or any `zstd`-capable tar (`zstd -dc a.tar.zst | tar -x`) before switching.

## Features

- **Timestamped file copies** — `notes.txt` → `notes.txt.20260714120000` (like `cp -p`)
- **Directory archives** — `project/` → `project.20260714120000.tgz`
- **List mode** — no paths → pack `<dirname>.list` entries into one `<dirname>.<timestamp>.tgz` (`-f` for a custom list)
- **Symlinks & hardlinks** — stored correctly in the tar stream
- **Extract mode** — `stach -x` restores files, dirs, and links safely
- **Parallel entities** — `-j` processes multiple top-level paths at once
- **Parallel compress & extract** — `-c` splits the tar into independent gzip members (parallel compress; plain `gzip` decodes them) and parallel file writers on extract
- **Folder pack progress** — live single-line progress while building archives
- **Quiet mode** — `--quiet` suppresses non-error output
- **Multi-arch releases** — Linux amd64/arm64, macOS Apple Silicon, Windows amd64

## Quick Start

### Pre-built binary

Download from [Releases](https://github.com/macedot/stach/releases/latest), then:

```bash
chmod +x stach-linux-amd64   # or the asset for your OS
./stach-linux-amd64 notes.txt src/
```

### Build from source

Requires [Odin](https://odin-lang.org/docs/install/) and a C compiler (`cc` / MSVC on Windows).

```bash
git clone https://github.com/macedot/stach.git
cd stach
make
./stach
```

## Usage

```
stach [--quiet] [-j N] [-c N] <file|directory|pattern> ...
stach [--quiet] [-c N] [-f list_file]
stach [-c N] -x <archive.tgz> [dest_dir]
```

| Mode | Behavior |
|------|----------|
| **File** | Copy to `<path>.<timestamp>` |
| **Directory** | Pack to `<path>.<timestamp>.tgz` (ustar + gzip level 6) |
| **List** | No paths → if `<cwd-basename>.list` exists, pack all its entries into one `<cwd-basename>.<timestamp>.tgz` |
| **`-f FILE`** | Same as list mode using a custom list file |
| **`-x`** | Unpack `.tgz` / `.tar.gz` into `dest_dir` (default: `.`) |

| Flag | Default | Description |
|------|---------|-------------|
| `-j N` | CPU count | Max paths to process in parallel |
| `-c N` | CPU count | gzip member workers (pack) and extract file writers |
| `-f FILE` | `<cwd-basename>.list` when present | List file: one path per line; `#` comments; wildcards; missing entries warn and skip |
| `--quiet` | off | Suppress all non-error output (progress + `src -> dst`) |

No arguments and no default list file prints usage and exits with code `2`. Exit `1` if any path fails.

In default mode, stdout shows live single-line folder packing progress plus mapping lines:

```
src -> dst
```

Use `--quiet` to keep stdout empty unless an error occurs (errors still go to stderr).

### Examples

```bash
# Backup a file and a tree
./stach notes.txt src/

# Parallel jobs + gzip member workers
./stach -j 4 -c 8 data/*.csv project/

# Shell globs (or let stach expand patterns)
./stach 'logs/*.log'

# List mode: pack every entry of <dirname>.list into one archive
# Example project.list:
#   .config
#   .ssh
#   Documents/*.pdf
./stach
./stach -f backup.list

# Extract (parallel file writes via -c)
./stach -c 8 -x project.20260714120000.tgz restored/

# Compatible with any standard tar / gzip
tar -tzf project.20260714120000.tgz
tar -xzf project.20260714120000.tgz -C restored/
```

## How it works

| Input | Output |
|-------|--------|
| Regular file | Byte copy next to the source, suffix `.<YYYYMMDDHHMMSS>` |
| Directory | Walk with `lstat` → ustar members (`0` file, `5` dir, `2` symlink, `1` hardlink) → independent gzip members → `.tgz` |
| List file | Resolve lines (comments/globs/missing skips) → multi-root walk into **one** `.tgz` named after the current directory |

Hardlinks share an inode: the first copy stores data; later names reference it. Symlinks store the link target, not the pointed-to content. In list mode, hardlink dedup is shared across all list roots.

Packing splits the tar into independent gzip members (RFC 1952, concatenated — whenever the tar exceeds 1 MiB) so compression scales across cores while staying a plain `.tgz` any `gzip` can decode; `-c` sets how many members deflate in parallel. Extract inflates the stream (verifying every member's CRC32), creates directories, writes regular files in parallel, then applies symlinks/hardlinks. Path traversal (`..`, absolute names) is rejected before writing under the destination.

## Test

```bash
make test
```

Covers file copy, nested tree, symlink, hardlink, `stach -x`, quiet mode, list mode (`*.list` / `-f`), and a system-tar compatibility gate (`tar -tzf`) on every produced archive.

## Benchmark

```bash
benchmark/bench.sh   # WORKERS=N RUNS=N to override defaults
```

Compares archive formats (zstd, lz4, gzip, xz, brotli, store) against stach's embedded gzip: pack/extract times and ratio on a generated mixed corpus, with a `decompress | tar -x` round-trip gate per candidate. Latest numbers in [`benchmark/RESULTS.md`](benchmark/RESULTS.md) (recorded with the previous zstd-based build; re-run `benchmark/bench.sh` to refresh for the gzip build). Requires `zstd`, `lz4`, `xz`, `brotli`, `python3`.

## Releases

Publishing a GitHub Release runs [`.github/workflows/release.yml`](.github/workflows/release.yml) and attaches:

| Asset | Platform |
|-------|----------|
| `stach-linux-amd64.tar.gz` | Linux x86_64 |
| `stach-linux-arm64.tar.gz` | Linux ARM64 |
| `stach-darwin-arm64.tar.gz` | macOS Apple Silicon |
| `stach-windows-amd64.zip` | Windows x86_64 |

## Layout

| Path | Role |
|------|------|
| `src/` | Odin sources (CLI, list mode, tar write/read, copy) |
| `vendor/miniz/` | Embedded [miniz](https://github.com/richgel999/miniz) library (deflate/inflate + CRC32) |
| `vendor/stach_gzip_wrap.c` | Thin C gzip layer used from Odin |
| `build/` | Local objects / static lib (not tracked) |
| `.github/workflows/` | Multi-arch release builds |

## License

**stach** is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

Bundled [miniz](https://github.com/richgel999/miniz) retains its own MIT license (see `vendor/miniz/LICENSE`).
