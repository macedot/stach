<h1 align="center">bkp</h1>

<p align="center"><strong>Standalone timestamped backups — files, folders, symlinks, hardlinks</strong></p>

<p align="center">
  <img src="https://img.shields.io/github/license/macedot/bkp?color=blue" alt="License" />
  <img src="https://img.shields.io/badge/Odin-dev--2026-blueviolet" alt="Odin" />
  <img src="https://img.shields.io/badge/platform-linux%20%7C%20macOS%20%7C%20windows-lightgrey" alt="Platforms" />
  <img src="https://img.shields.io/github/v/release/macedot/bkp?display_name=tag" alt="Release" />
</p>

---

**bkp** is a small, dependency-free CLI for fast local backups. Point it at files or directories and get timestamped copies: plain files are duplicated beside the original; directories become a single **`.tar.zst`** (ustar + zstd) that preserves **symlinks** and **hardlinks**. Unpack with `bkp -x` or `tar` + `zstd` when those tools are available.

Written in [Odin](https://odin-lang.org/). Compression uses embedded [zstd](https://github.com/facebook/zstd) (level 1, multi-threaded). No system `zstd` required at runtime.

## Features

- **Timestamped file copies** — `notes.txt` → `notes.txt.20260714120000` (like `cp -p`)
- **Directory archives** — `project/` → `project.20260714120000.tar.zst`
- **Symlinks & hardlinks** — stored correctly in the tar stream
- **Extract mode** — `bkp -x` restores files, dirs, and links safely
- **Parallel entities** — `-j` processes multiple top-level paths at once
- **Parallel compress & extract** — `-c` multi-frame zstd (parallel compress + decompress) and parallel file writers
- **Folder pack progress** — live single-line progress while building archives
- **Quiet mode** — `--quiet` suppresses non-error output
- **Multi-arch releases** — Linux amd64/arm64, macOS Apple Silicon, Windows amd64

## Quick Start

### Pre-built binary

Download from [Releases](https://github.com/macedot/bkp/releases/latest), then:

```bash
chmod +x bkp-linux-amd64   # or the asset for your OS
./bkp-linux-amd64 notes.txt src/
```

### Build from source

Requires [Odin](https://odin-lang.org/docs/install/) and a C compiler (`cc` / MSVC on Windows).

```bash
git clone https://github.com/macedot/bkp.git
cd bkp
make
./bkp
```

## Usage

```
bkp [--quiet] [-j N] [-c N] <file|directory|pattern> ...
bkp [-c N] -x <archive.tar.zst> [dest_dir]
```

| Mode | Behavior |
|------|----------|
| **File** | Copy to `<path>.<timestamp>` |
| **Directory** | Pack to `<path>.<timestamp>.tar.zst` (ustar + zstd level 1) |
| **`-x`** | Unpack `.tar.zst` into `dest_dir` (default: `.`) |

| Flag | Default | Description |
|------|---------|-------------|
| `-j N` | CPU count | Max paths to process in parallel |
| `-c N` | CPU count | multi-frame zstd workers (pack + extract decompress) and extract file writers |
| `--quiet` | off | Suppress all non-error output (progress + `src -> dst`) |

No arguments prints usage and exits with code `2`. Exit `1` if any path fails.

In default mode, stdout shows live single-line folder packing progress plus mapping lines:

```
src -> dst
```

Use `--quiet` to keep stdout empty unless an error occurs (errors still go to stderr).

### Examples

```bash
# Backup a file and a tree
./bkp notes.txt src/

# Parallel jobs + zstd workers
./bkp -j 4 -c 8 data/*.csv project/

# Shell globs (or let bkp expand patterns)
./bkp 'logs/*.log'

# Extract (parallel file writes via -c)
./bkp -c 8 -x project.20260714120000.tar.zst restored/

# Compatible with system tar + zstd when installed
zstd -d -c project.20260714120000.tar.zst | tar -tf -
zstd -d -c project.20260714120000.tar.zst | tar -xf - -C restored/
```

## How it works

| Input | Output |
|-------|--------|
| Regular file | Byte copy next to the source, suffix `.<YYYYMMDDHHMMSS>` |
| Directory | Walk with `lstat` → ustar members (`0` file, `5` dir, `2` symlink, `1` hardlink) → multi-frame zstd → `.tar.zst` |

Hardlinks share an inode: the first copy stores data; later names reference it. Symlinks store the link target, not the pointed-to content.

Packing splits the tar into independent zstd frames (when `-c` > 1 and the tree is large enough) so both compress and decompress scale across cores. Extract inflates frames in parallel, creates directories, writes regular files in parallel, then applies symlinks/hardlinks. Path traversal (`..`, absolute names) is rejected before writing under the destination.

## Test

```bash
make test
```

Covers file copy, nested tree, symlink, hardlink, and `bkp -x`.

## Benchmark

```bash
benchmark/bench.sh   # WORKERS=N RUNS=N to override defaults
```

Compares archive formats (zstd, lz4, gzip, xz, brotli, store) against bkp's embedded zstd: pack/extract times and ratio on a generated mixed corpus, with a `decompress | tar -x` round-trip gate per candidate. Latest numbers in [`benchmark/RESULTS.md`](benchmark/RESULTS.md). Requires `zstd`, `lz4`, `xz`, `brotli`, `python3`.

## Releases

Publishing a GitHub Release runs [`.github/workflows/release.yml`](.github/workflows/release.yml) and attaches:

| Asset | Platform |
|-------|----------|
| `bkp-linux-amd64.tar.gz` | Linux x86_64 |
| `bkp-linux-arm64.tar.gz` | Linux ARM64 |
| `bkp-darwin-arm64.tar.gz` | macOS Apple Silicon |
| `bkp-windows-amd64.zip` | Windows x86_64 |

## Layout

| Path | Role |
|------|------|
| `src/` | Odin sources (CLI, tar write/read, copy) |
| `vendor/zstd/` | Embedded [zstd](https://github.com/facebook/zstd) library |
| `vendor/bkp_zstd_wrap.c` | Thin C API used from Odin |
| `build/` | Local objects / static lib (not tracked) |
| `.github/workflows/` | Multi-arch release builds |

## License

**bkp** is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

Bundled [zstd](https://github.com/facebook/zstd) retains its own licenses (see `vendor/zstd/LICENSE` and `vendor/zstd/COPYING`).
