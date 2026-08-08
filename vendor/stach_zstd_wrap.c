/*
 * Thin C wrapper around libzstd for stach:
 * - zstd compress (optional multi-thread for single-frame path)
 * - multi-frame scan helpers for parallel decompress
 * - free helper
 */
#include "zstd/lib/zstd.h"
#include <stdlib.h>
#include <string.h>

/* Compress with zstd. workers > 1 enables multi-threaded compress when
 * libzstd was built with ZSTD_MULTITHREAD (single-frame path).
 * Returns malloc'd buffer (free with stach_free). NULL on failure.
 */
unsigned char *stach_zstd_compress(const unsigned char *src, size_t src_len,
                                 int level, int workers, size_t *out_len)
{
	ZSTD_CCtx *cctx;
	size_t bound;
	unsigned char *out;
	size_t csize;
	int w;

	if (!out_len)
		return NULL;
	*out_len = 0;

	if (level < 1)
		level = 1;
	w = workers < 1 ? 1 : workers;

	cctx = ZSTD_createCCtx();
	if (!cctx)
		return NULL;

	if (ZSTD_isError(ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, level))) {
		ZSTD_freeCCtx(cctx);
		return NULL;
	}
	if (w > 1) {
		size_t r = ZSTD_CCtx_setParameter(cctx, ZSTD_c_nbWorkers, w);
		if (ZSTD_isError(r)) {
			(void)ZSTD_CCtx_setParameter(cctx, ZSTD_c_nbWorkers, 0);
		}
	}

	bound = ZSTD_compressBound(src_len);
	out = (unsigned char *)malloc(bound);
	if (!out) {
		ZSTD_freeCCtx(cctx);
		return NULL;
	}

	csize = ZSTD_compress2(cctx, out, bound, src ? src : (const unsigned char *)"", src_len);
	ZSTD_freeCCtx(cctx);
	if (ZSTD_isError(csize)) {
		free(out);
		return NULL;
	}

	if (csize < bound) {
		unsigned char *shrunk = (unsigned char *)realloc(out, csize ? csize : 1);
		if (shrunk)
			out = shrunk;
	}

	*out_len = csize;
	return out;
}

/* Compressed size of the first frame at src, or 0 on error. */
size_t stach_zstd_frame_compressed_size(const unsigned char *src, size_t src_len)
{
	size_t n;

	if (!src || src_len == 0)
		return 0;
	n = ZSTD_findFrameCompressedSize(src, src_len);
	if (ZSTD_isError(n))
		return 0;
	return n;
}

/* Uncompressed size of the first frame at src.
 * Returns (size_t)-1 on error or unknown content size.
 */
size_t stach_zstd_frame_content_size(const unsigned char *src, size_t src_len)
{
	unsigned long long sz;

	if (!src || src_len == 0)
		return (size_t)-1;
	sz = ZSTD_getFrameContentSize(src, src_len);
	if (sz == ZSTD_CONTENTSIZE_ERROR || sz == ZSTD_CONTENTSIZE_UNKNOWN)
		return (size_t)-1;
	return (size_t)sz;
}

/* Decompress one frame into caller-owned dst. Returns 0 on success, -1 on failure.
 * *out_len = bytes written.
 */
int stach_zstd_decompress_into(const unsigned char *src, size_t src_len,
                             unsigned char *dst, size_t dst_cap, size_t *out_len)
{
	size_t dsize;

	if (!out_len)
		return -1;
	*out_len = 0;
	if (!src || !dst)
		return -1;

	dsize = ZSTD_decompress(dst, dst_cap, src, src_len);
	if (ZSTD_isError(dsize))
		return -1;
	*out_len = dsize;
	return 0;
}

/* Decompress full multi-frame stream into a single malloc'd buffer (serial).
 * Parallel path uses frame scan + decompress_into instead.
 */
unsigned char *stach_zstd_decompress(const unsigned char *src, size_t src_len, size_t *out_len)
{
	ZSTD_DCtx *dctx;
	ZSTD_inBuffer input;
	size_t cap;
	size_t used = 0;
	unsigned char *out;

	if (!out_len || !src)
		return NULL;
	*out_len = 0;

	dctx = ZSTD_createDCtx();
	if (!dctx)
		return NULL;

	cap = src_len * 4;
	if (cap < 64 * 1024)
		cap = 64 * 1024;
	out = (unsigned char *)malloc(cap);
	if (!out) {
		ZSTD_freeDCtx(dctx);
		return NULL;
	}

	input.src = src;
	input.size = src_len;
	input.pos = 0;
	while (input.pos < input.size) {
		ZSTD_outBuffer output;
		size_t ret;
		if (used + 64 * 1024 > cap) {
			size_t ncap = cap * 2;
			unsigned char *n = (unsigned char *)realloc(out, ncap);
			if (!n) {
				free(out);
				ZSTD_freeDCtx(dctx);
				return NULL;
			}
			out = n;
			cap = ncap;
		}
		output.dst = out + used;
		output.size = cap - used;
		output.pos = 0;
		ret = ZSTD_decompressStream(dctx, &output, &input);
		if (ZSTD_isError(ret)) {
			free(out);
			ZSTD_freeDCtx(dctx);
			return NULL;
		}
		used += output.pos;
	}
	ZSTD_freeDCtx(dctx);
	*out_len = used;
	return out;
}

void stach_free(void *p)
{
	if (p)
		free(p);
}
