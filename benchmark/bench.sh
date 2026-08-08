#!/usr/bin/env bash
# stach compression benchmark — compares archive formats for stach's directory-backup
# use case. Every candidate must round-trip through system tar (decompress | tar -x)
# with a byte-identical tree. Results: benchmark/results.csv + benchmark/RESULTS.md.
#
# Usage: benchmark/bench.sh
#   WORKERS=N  parallel workers (default: CPU count, mirrors stach -c)
#   RUNS=N     timing repetitions, best-of (default: 3)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/benchmark"
CSV="$OUT_DIR/results.csv"
REPORT="$OUT_DIR/RESULTS.md"
STACH="$REPO_ROOT/stach"

WORKERS="${WORKERS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
RUNS="${RUNS:-3}"

if ! command -v python3 >/dev/null 2>&1; then
	echo "Error: python3 is required for millisecond timing" >&2
	exit 1
fi
for t in tar zstd lz4 gzip xz brotli; do
	if ! command -v "$t" >/dev/null 2>&1; then
		echo "Error: required tool missing: $t" >&2
		exit 1
	fi
done

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# time_best CMD [ARGS...] -> echoes best wall time in ms over RUNS runs
time_best() {
	local best="" i s e d
	for i in $(seq "$RUNS"); do
		s=$(now_ms)
		"$@" >/dev/null 2>&1
		e=$(now_ms)
		d=$((e - s))
		if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d; fi
	done
	echo "$best"
}

# ---------------------------------------------------------------- corpus ----
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORPUS="$TMP/corpus"

echo "== Generating corpus in $TMP"
mkdir -p "$CORPUS/logs" "$CORPUS/src" "$CORPUS/bin"

# ~256 MiB compressible log-style text
awk 'BEGIN {
	for (i = 0; i < 3000000; i++)
		printf "2026-08-07T10:%02d:%02dZ INFO worker-%d request id=%d path=/api/v1/resource/%d status=%d latency_ms=%d\n",
			i % 60, i % 60, i % 16, 1000000 + i, i % 997, (i % 5) * 100 + 200, i % 250
}' > "$CORPUS/logs/app.log"

# ~64 MiB across ~500 small source-like files
awk 'BEGIN {
	for (i = 0; i < 1400; i++)
		printf "static int helper_%03d(int value) { return value * %d + (value >> %d); /* padding comment for size */\n",
			i % 500, i % 31, i % 8
}' > "$TMP/.src_tmpl"
for i in $(seq -w 1 500); do
	{ echo "// source file $i — unique header"; cat "$TMP/.src_tmpl"; } > "$CORPUS/src/file_$i.c"
done

# ~128 MiB incompressible random + ~64 MiB zeros
dd if=/dev/urandom of="$CORPUS/bin/random.bin" bs=1m count=128 2>/dev/null
dd if=/dev/zero of="$CORPUS/bin/zeros.bin" bs=1m count=64 2>/dev/null

# links (exercise tar metadata paths)
ln -s ../logs/app.log "$CORPUS/src/app.log.link"
ln -s bin/random.bin "$CORPUS/random.link"
ln "$CORPUS/src/file_001.c" "$CORPUS/src/file_001_hard.c"

# Original size = uncompressed tar of the tree (store baseline, built once)
STORE_TAR="$TMP/store.tar"
tar -cf "$STORE_TAR" -C "$TMP" corpus
ORIG_BYTES=$(stat -f %z "$STORE_TAR")
echo "== Corpus ready: $((ORIG_BYTES / 1048576)) MiB tar, $WORKERS workers, $RUNS runs each"

# ------------------------------------------------------------- verification ----
# verify_tree DIR — extracted root must contain corpus/ identical to CORPUS
verify_tree() {
	local root="$1"
	diff -r "$CORPUS" "$root/corpus" > /dev/null
	(
		cd "$CORPUS" && find . -type l | LC_ALL=C sort | while read -r l; do
			printf '%s -> %s\n' "$l" "$(readlink "$l")"
		done
	) > "$TMP/.links_a"
	(
		cd "$root/corpus" && find . -type l | LC_ALL=C sort | while read -r l; do
			printf '%s -> %s\n' "$l" "$(readlink "$l")"
		done
	) > "$TMP/.links_b"
	diff -u "$TMP/.links_a" "$TMP/.links_b" > /dev/null
}

# gate_pipe DECCMD ARCHIVE — prove system-tar compatibility + integrity
gate_pipe() {
	local dec="$1" arch="$2" g="$TMP/.gate"
	rm -rf "$g"
	mkdir -p "$g"
	$dec "$arch" | tar -x -C "$g"
	verify_tree "$g"
	rm -rf "$g"
}

# ------------------------------------------------------------- candidates ----
ARCH=""   # archive path of the candidate currently being packed
XOUT="$TMP/.xout"

pack_store()    { tar -cf "$ARCH" -C "$TMP" corpus; }
extract_store() { rm -rf "$XOUT"; mkdir -p "$XOUT"; tar -xf "$ARCH" -C "$XOUT"; }

pack_stach() {
	rm -f "$TMP"/corpus.*.tar.zst
	(cd "$TMP" && "$STACH" --quiet -c "$WORKERS" corpus)
}
extract_stach() {
	rm -rf "$XOUT"
	mkdir -p "$XOUT"
	"$STACH" --quiet -c "$WORKERS" -x "$ARCH" "$XOUT"
}

pack_zstd() { tar -cf - -C "$TMP" corpus | zstd -q "$ZSTD_LVL" -T"$WORKERS" -c > "$ARCH"; }
extract_zstd() {
	rm -rf "$XOUT"
	mkdir -p "$XOUT"
	zstd -q -dc "$ARCH" | tar -x -C "$XOUT"
}

# lz4 CLI has no multithreading: split the tar into WORKERS*4 chunks, compress
# in parallel, concatenate frames (same model as stach's multi-frame zstd).
pack_lz4() {
	local cdir="$TMP/.lz4c" ttar="$TMP/.lz4.tar" size chunk
	rm -rf "$cdir"
	mkdir -p "$cdir"
	tar -cf "$ttar" -C "$TMP" corpus
	size=$(stat -f %z "$ttar")
	chunk=$(((size + WORKERS * 4 - 1) / (WORKERS * 4)))
	(cd "$cdir" && split -b "$chunk" "$ttar" c_)
	printf '%s\n' "$cdir"/c_* | LC_ALL=C sort |
		xargs -P "$WORKERS" -I {} sh -c 'lz4 -q "$0" -c "$1" > "$1.f"' "$LZ4_LVL" {}
	: > "$ARCH"
	local f
	for f in $(printf '%s\n' "$cdir"/c_*.f | LC_ALL=C sort); do cat "$f"; done >> "$ARCH"
	rm -rf "$cdir" "$ttar"
}
extract_lz4() {
	rm -rf "$XOUT"
	mkdir -p "$XOUT"
	lz4 -q -dc "$ARCH" | tar -x -C "$XOUT"
}

pack_gzip()    { tar -cf - -C "$TMP" corpus | gzip -1 -c > "$ARCH"; }
extract_gzip() { rm -rf "$XOUT"; mkdir -p "$XOUT"; gzip -dc "$ARCH" | tar -x -C "$XOUT"; }

pack_xz()    { tar -cf - -C "$TMP" corpus | xz -1 -T"$WORKERS" -c > "$ARCH"; }
extract_xz() { rm -rf "$XOUT"; mkdir -p "$XOUT"; xz -dc "$ARCH" | tar -x -C "$XOUT"; }

pack_brotli()    { tar -cf - -C "$TMP" corpus | brotli -q 1 -c > "$ARCH"; }
extract_brotli() { rm -rf "$XOUT"; mkdir -p "$XOUT"; brotli -dc "$ARCH" | tar -x -C "$XOUT"; }

# run_candidate NAME PARALLEL_INFO PACK_FN EXTRACT_FN ARCH_PATH DECCMD DEC_FOR_STACH
run_candidate() {
	local name="$1" par="$2" pack_fn="$3" extract_fn="$4" arch="$5" dec="$6"
	ARCH="$arch"
	echo "== $name"

	echo "   gate: $dec | tar -x"
	gate_pipe "$dec" "$arch" 2>/dev/null || {
		# archive does not exist yet on first pass: pack once, then gate
		$pack_fn
		gate_pipe "$dec" "$arch"
	}

	local pack_ms extract_ms size
	pack_ms=$(time_best "$pack_fn")
	[ -f "$arch" ] || $pack_fn   # keep an archive around for extract timing
	size=$(stat -f %z "$arch")
	extract_ms=$(time_best "$extract_fn")
	rm -rf "$XOUT"

	printf '%s,%s,%s,%s,%s\n' "$name" "$par" "$pack_ms" "$extract_ms" "$size" >> "$CSV"
}

# ------------------------------------------------------------------ run ----
echo "== Building stach"
make -C "$REPO_ROOT" > /dev/null

echo "candidate,parallel,pack_ms,extract_ms,size_bytes" > "$CSV"

run_candidate "store (tar only)" "none" pack_store extract_store "$TMP/arch_store.tar" "cat"

ARCH_STACH="$TMP/stach_archive.tar.zst"
pack_stach
mv "$TMP"/corpus.*.tar.zst "$ARCH_STACH"
# stach archives must also be extractable via system zstd | tar
echo "== stach zstd-1 multi-frame (embedded)"
echo "   gate: zstd -dc | tar -x"
gate_pipe "zstd -q -dc" "$ARCH_STACH"
echo "   gate: stach -x"
G="$TMP/.gate"
rm -rf "$G"; mkdir -p "$G"
"$STACH" --quiet -c "$WORKERS" -x "$ARCH_STACH" "$G"
verify_tree "$G"
rm -rf "$G"
STACH_PACK_MS=$(time_best pack_stach)
STACH_SIZE=$(stat -f %z "$ARCH_STACH")
ARCH="$ARCH_STACH"
STACH_EXTRACT_MS=$(time_best extract_stach)
printf '%s,%s,%s,%s,%s\n' "stach zstd-1 (embedded)" "multi-frame -c $WORKERS" \
	"$STACH_PACK_MS" "$STACH_EXTRACT_MS" "$STACH_SIZE" >> "$CSV"

ZSTD_LVL="--fast=1" run_candidate "zstd --fast=1" "-T $WORKERS" pack_zstd extract_zstd "$TMP/arch_zfast1.tar.zst" "zstd -q -dc"
ZSTD_LVL="-1" run_candidate "zstd -1" "-T $WORKERS" pack_zstd extract_zstd "$TMP/arch_z1.tar.zst" "zstd -q -dc"
ZSTD_LVL="-3" run_candidate "zstd -3 (reference)" "-T $WORKERS" pack_zstd extract_zstd "$TMP/arch_z3.tar.zst" "zstd -q -dc"
LZ4_LVL="--fast=3" run_candidate "lz4 --fast=3" "chunked -P $WORKERS" pack_lz4 extract_lz4 "$TMP/arch_lz4f3.tar.lz4" "lz4 -q -dc"
LZ4_LVL="-1" run_candidate "lz4 -1" "chunked -P $WORKERS" pack_lz4 extract_lz4 "$TMP/arch_lz41.tar.lz4" "lz4 -q -dc"
run_candidate "gzip -1" "single-thread" pack_gzip extract_gzip "$TMP/arch_gz1.tar.gz" "gzip -dc"
run_candidate "xz -1 (reference)" "-T $WORKERS" pack_xz extract_xz "$TMP/arch_xz1.tar.xz" "xz -dc"
run_candidate "brotli -q 1 (reference)" "single-thread" pack_brotli extract_brotli "$TMP/arch_br1.tar.br" "brotli -dc"

# ---------------------------------------------------------------- report ----
fmt_row() { # csv line -> markdown row
	printf '%s\n' "$1" | awk -F, -v orig="$ORIG_BYTES" '{
		pack_s = $3 / 1000; ext_s = $4 / 1000;
		mib = $5 / 1048576; ratio = 100.0 * $5 / orig;
		mibs = (orig / 1048576) / (pack_s > 0 ? pack_s : 0.001);
		printf "| %s | %s | %.2f | %.2f | %.1f | %.1f%% | %.0f |\n",
			$1, $2, pack_s, ext_s, mib, ratio, mibs
	}'
}

best_pack=$(tail -n +2 "$CSV" | sort -t, -k3 -n | head -1 | cut -d, -f1)
best_extract=$(tail -n +2 "$CSV" | sort -t, -k4 -n | head -1 | cut -d, -f1)
best_ratio=$(tail -n +2 "$CSV" | grep -v '^store' | sort -t, -k5 -n | head -1 | cut -d, -f1)

{
	echo "# stach compression benchmark"
	echo
	echo "- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "- Machine: $(uname -srm); $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown CPU)"
	echo "- Workers: $WORKERS (mirrors stach \`-c\`); best of $RUNS runs"
	echo "- Corpus: $((ORIG_BYTES / 1048576)) MiB tar (256 MiB logs, 128 MiB random, 64 MiB zeros, ~64 MiB small files, symlinks + hardlink)"
	echo "- Correctness: every archive round-trips via \`<decompressor> | tar -x\` with a byte-identical tree; stach archives also verified via \`stach -x\`"
	echo
	echo "| Candidate | Parallel | Pack (s) | Extract (s) | Size (MiB) | Ratio | Pack MiB/s |"
	echo "|---|---|---:|---:|---:|---:|---:|"
	tail -n +2 "$CSV" | while IFS= read -r line; do fmt_row "$line"; done
	echo
	echo "## Summary"
	echo
	echo "- Fastest pack: **$best_pack**"
	echo "- Fastest extract: **$best_extract**"
	echo "- Best ratio (compressed candidates): **$best_ratio**"
	echo
	echo "## Notes"
	echo
	echo "- \`stach zstd-1 (embedded)\` includes in-memory tar building; pipeline candidates stream \`tar -cf - | compressor\`."
	echo "- lz4 CLI has no multithreading; it is chunked into $((WORKERS * 4)) parts compressed with \`xargs -P $WORKERS\` and concatenated (same model as stach multi-frame zstd). \`lz4 --fast=3\` is shown instead of \`--fast=1\`, which is identical to the default."
	echo "- gzip and brotli ran single-threaded (no pigz installed)."
	echo "- Ratio is archive size / uncompressed tar size; lower is better."
} > "$REPORT"

echo
echo "== Done"
cat "$REPORT"
