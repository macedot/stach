# bkp compression benchmark

- Date: 2026-08-07T11:12:07Z
- Machine: Darwin 27.0.0 arm64; Apple M3 Max
- Workers: 16 (mirrors bkp `-c`); best of 3 runs
- Corpus: 562 MiB tar (256 MiB logs, 128 MiB random, 64 MiB zeros, ~64 MiB small files, symlinks + hardlink)
- Correctness: every archive round-trips via `<decompressor> | tar -x` with a byte-identical tree; bkp archives also verified via `bkp -x`

| Candidate | Parallel | Pack (s) | Extract (s) | Size (MiB) | Ratio | Pack MiB/s |
|---|---|---:|---:|---:|---:|---:|
| store (tar only) | none | 0.50 | 0.63 | 562.7 | 100.0% | 1128 |
| bkp zstd-1 (embedded) | multi-frame -c 16 | 0.28 | 0.14 | 147.7 | 26.2% | 2046 |
| zstd --fast=1 | -T 16 | 0.39 | 0.68 | 154.6 | 27.5% | 1454 |
| zstd -1 | -T 16 | 0.40 | 0.66 | 148.1 | 26.3% | 1417 |
| zstd -3 (reference) | -T 16 | 0.38 | 0.67 | 146.7 | 26.1% | 1485 |
| lz4 --fast=3 | chunked -P 16 | 1.00 | 0.66 | 193.5 | 34.4% | 560 |
| lz4 -1 | chunked -P 16 | 1.05 | 0.67 | 193.2 | 34.3% | 535 |
| gzip -1 | single-thread | 3.09 | 0.61 | 170.4 | 30.3% | 182 |
| xz -1 (reference) | -T 16 | 3.49 | 0.64 | 143.2 | 25.5% | 161 |
| brotli -q 1 (reference) | single-thread | 0.84 | 1.10 | 160.3 | 28.5% | 668 |

## Summary

- Fastest pack: **bkp zstd-1 (embedded)**
- Fastest extract: **bkp zstd-1 (embedded)**
- Best ratio (compressed candidates): **xz -1 (reference)**

## Notes

- `bkp zstd-1 (embedded)` includes in-memory tar building; pipeline candidates stream `tar -cf - | compressor`.
- lz4 CLI has no multithreading; it is chunked into 64 parts compressed with `xargs -P 16` and concatenated (same model as bkp multi-frame zstd). `lz4 --fast=3` is shown instead of `--fast=1`, which is identical to the default.
- gzip and brotli ran single-threaded (no pigz installed).
- Ratio is archive size / uncompressed tar size; lower is better.
