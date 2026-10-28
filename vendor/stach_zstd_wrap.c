/*
 * Thin C wrapper around libzstd for stach:
 * - zstd compress into a caller-owned buffer (bound + fill, like decompress_into)
 * - multi-frame scan helpers
 * - decompress one frame into a caller-owned buffer
 *
 * All buffers are caller-owned; nothing here allocates. The Goose side
 * declares matching `extern fn`s in src/shim.goose. Byte buffers cross the
 * boundary the way Goose slices do: one { data, len } struct by value.
 */
#include <zstd.h>
#include <stddef.h>
#include <stdint.h>

/* Matches a Goose u8[:] slice: { pointer, length }. */
typedef struct { unsigned char *data; int64_t len; } stach_bytes;
typedef struct { const unsigned char *data; int64_t len; } stach_cbytes;

/* Worst-case compressed size for src_len bytes (headroom for the caller's buffer). */
int64_t stach_zstd_compress_bound(int64_t src_len)
{
	return (int64_t)ZSTD_compressBound((size_t)(src_len < 0 ? 0 : src_len));
}

/* Compress src into caller-owned dst with zstd. workers > 1 enables
 * multi-threaded compress when libzstd was built with ZSTD_MULTITHREAD
 * (falls back to single-thread if not). Returns 0 on success, -1 on failure;
 * *out_len = compressed bytes written to dst.
 */
int32_t stach_zstd_compress_into(stach_cbytes src, int32_t level, int32_t workers,
                                 stach_bytes dst, int64_t *out_len)
{
	ZSTD_CCtx *cctx;
	size_t csize;
	int w;

	if (!out_len || !dst.data)
		return -1;
	*out_len = 0;

	if (level < 1)
		level = 1;
	w = workers < 1 ? 1 : workers;

	cctx = ZSTD_createCCtx();
	if (!cctx)
		return -1;

	if (ZSTD_isError(ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, level))) {
		ZSTD_freeCCtx(cctx);
		return -1;
	}
	if (w > 1) {
		size_t r = ZSTD_CCtx_setParameter(cctx, ZSTD_c_nbWorkers, w);
		if (ZSTD_isError(r))
			(void)ZSTD_CCtx_setParameter(cctx, ZSTD_c_nbWorkers, 0);
	}

	csize = ZSTD_compress2(cctx, dst.data, (size_t)dst.len,
	                       src.data ? src.data : (const unsigned char *)"",
	                       (size_t)(src.len < 0 ? 0 : src.len));
	ZSTD_freeCCtx(cctx);
	if (ZSTD_isError(csize))
		return -1;
	if (csize > (size_t)dst.len)
		return -1;

	*out_len = (int64_t)csize;
	return 0;
}

/* Compressed size of the first frame at src, or 0 on error. */
int64_t stach_zstd_frame_compressed_size(stach_cbytes src)
{
	size_t n;

	if (!src.data || src.len == 0)
		return 0;
	n = ZSTD_findFrameCompressedSize(src.data, (size_t)src.len);
	if (ZSTD_isError(n))
		return 0;
	return (int64_t)n;
}

/* Uncompressed size of the first frame at src.
 * Returns -1 on error or unknown content size.
 */
int64_t stach_zstd_frame_content_size(stach_cbytes src)
{
	unsigned long long sz;

	if (!src.data || src.len == 0)
		return -1;
	sz = ZSTD_getFrameContentSize(src.data, (size_t)src.len);
	if (sz == ZSTD_CONTENTSIZE_ERROR || sz == ZSTD_CONTENTSIZE_UNKNOWN)
		return -1;
	return (int64_t)sz;
}

/* Decompress one frame into caller-owned dst. Returns 0 on success, -1 on failure.
 * *out_len = bytes written.
 */
int32_t stach_zstd_decompress_into(stach_cbytes src, stach_bytes dst, int64_t *out_len)
{
	size_t dsize;

	if (!out_len)
		return -1;
	*out_len = 0;
	if (!src.data || !dst.data)
		return -1;

	dsize = ZSTD_decompress(dst.data, (size_t)dst.len, src.data, (size_t)src.len);
	if (ZSTD_isError(dsize))
		return -1;
	*out_len = (int64_t)dsize;
	return 0;
}
