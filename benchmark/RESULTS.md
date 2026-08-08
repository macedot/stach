# stach compression benchmark

- Date: 2026-08-08T10:25:19Z
- Machine: Darwin 27.0.0 arm64; Apple M3 Max
- Workers: 16 (mirrors stach `-c`); best of 1 runs
- Corpus: 562 MiB tar (256 MiB logs, 128 MiB random, 64 MiB zeros, ~64 MiB small files, symlinks + hardlink)
- Correctness: every archive round-trips via `<decompressor> | tar -x` with a byte-identical tree; stach archives also verified via `stach -x`

| Candidate | Parallel | Pack (s) | Extract (s) | Size (MiB) | Ratio | Pack MiB/s |
|---|---|---:|---:|---:|---:|---:|
| store (tar only) | none | 0.79 | 0.80 | 562.7 | 100.0% | 714 |
| stach zstd-1 (embedded) | multi-frame -c 16 | 0.45 | 0.18 | 147.7 | 26.2% | 1259 |
| zstd --fast=1 | -T 16 | 0.47 | 0.84 | 154.6 | 27.5% | 1197 |
| zstd -1 | -T 16 | 0.49 | 0.81 | 148.1 | 26.3% | 1137 |
| zstd -3 (reference) | -T 16 | 0.46 | 0.79 | 146.7 | 26.1% | 1226 |
| lz4 --fast=3 | chunked -P 16 | 1.51 | 0.81 | 193.5 | 34.4% | 372 |
| lz4 -1 | chunked -P 16 | 1.33 | 0.79 | 193.2 | 34.3% | 423 |
| gzip -1 | single-thread | 3.99 | 0.76 | 170.4 | 30.3% | 141 |
| xz -1 (reference) | -T 16 | 3.38 | 0.80 | 143.2 | 25.5% | 166 |
| brotli -q 1 (reference) | single-thread | 1.05 | 1.31 | 160.3 | 28.5% | 535 |

## Summary

- Fastest pack: **stach zstd-1 (embedded)**
- Fastest extract: **stach zstd-1 (embedded)**
- Best ratio (compressed candidates): **xz -1 (reference)**

## Notes

- `stach zstd-1 (embedded)` includes in-memory tar building; pipeline candidates stream `tar -cf - | compressor`.
- lz4 CLI has no multithreading; it is chunked into 64 parts compressed with `xargs -P 16` and concatenated (same model as stach multi-frame zstd). `lz4 --fast=3` is shown instead of `--fast=1`, which is identical to the default.
- gzip and brotli ran single-threaded (no pigz installed).
- Ratio is archive size / uncompressed tar size; lower is better.
