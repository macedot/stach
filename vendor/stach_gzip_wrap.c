/*
 * Thin gzip wrapper for stach, built on vendored miniz.
 *
 * Streams are standard multi-member gzip (RFC 1952):
 *
 *   member := 10-byte header | raw deflate | CRC32 (LE) | ISIZE (LE)
 *
 * gzip(1), tar -z and friends decode concatenated members transparently, so
 * stach can deflate independent tar chunks in parallel and still emit a plain
 * .tgz file. Members carry only the minimal fixed header (no FNAME/FCOMMENT/
 * FEXTRA, MTIME=0) so archives stay reproducible.
 *
 * Compress: one member per call (stach emits one per tar chunk, in parallel).
 * Decompress: inflates all members sequentially into one malloc'd buffer,
 * verifying each member's CRC32 and ISIZE trailer (and FHCRC when present).
 * Input/output windows are fed in <=1 GiB slices so the 32-bit mz_stream
 * counters never overflow regardless of archive size.
 */
#include "miniz/miniz.h"
#include <stdlib.h>
#include <string.h>

#define GZIP_HDR_SIZE 10
#define GZIP_TRAILER_SIZE 8
/* mz_stream avail_in/avail_out are 32-bit: never ask for more than 1 GiB. */
#define FEED_CHUNK ((size_t)1 << 30)

static const unsigned char gzip_fixed_header[GZIP_HDR_SIZE] = {
	0x1f, 0x8b, /* ID1 ID2 */
	8,          /* CM = deflate */
	0,          /* FLG: no FTEXT/FHCRC/FEXTRA/FNAME/FCOMMENT */
	0, 0, 0, 0, /* MTIME = 0 (reproducible) */
	0,          /* XFL */
	0xff        /* OS = unknown */
};

static void put_le32(unsigned char *p, mz_uint32 v)
{
	p[0] = (unsigned char)(v & 0xffu);
	p[1] = (unsigned char)((v >> 8) & 0xffu);
	p[2] = (unsigned char)((v >> 16) & 0xffu);
	p[3] = (unsigned char)((v >> 24) & 0xffu);
}

static mz_uint32 get_le32(const unsigned char *p)
{
	return (mz_uint32)p[0] | ((mz_uint32)p[1] << 8) |
	       ((mz_uint32)p[2] << 16) | ((mz_uint32)p[3] << 24);
}

/* Compress src into one gzip member. Returns a malloc'd buffer (free with
 * stach_free), NULL on failure. level is clamped to 1..9; <=0 means the gzip
 * default (6).
 */
unsigned char *stach_gzip_compress(const unsigned char *src, size_t src_len,
                                 int level, size_t *out_len)
{
	mz_stream s;
	size_t bound, cap, in_left;
	const unsigned char *in_next;
	unsigned char *out;
	int status;

	if (!out_len)
		return NULL;
	*out_len = 0;
	if (level < 1)
		level = 6;
	if (level > 9)
		level = 9;

	bound = (size_t)mz_compressBound((mz_ulong)src_len);
	cap = bound + GZIP_HDR_SIZE + GZIP_TRAILER_SIZE;
	out = (unsigned char *)malloc(cap);
	if (!out)
		return NULL;

	memcpy(out, gzip_fixed_header, GZIP_HDR_SIZE);

	memset(&s, 0, sizeof(s));
	in_next = src;
	in_left = src_len;
	s.next_in = in_next;
	s.avail_in = 0;
	s.next_out = out + GZIP_HDR_SIZE;
	s.avail_out = (mz_uint32)((cap - GZIP_HDR_SIZE) < FEED_CHUNK
	                             ? (cap - GZIP_HDR_SIZE)
	                             : FEED_CHUNK);

	if (mz_deflateInit2(&s, level, MZ_DEFLATED, -MZ_DEFAULT_WINDOW_BITS, 8,
	                    MZ_DEFAULT_STRATEGY) != MZ_OK) {
		free(out);
		return NULL;
	}

	for (;;) {
		if (s.avail_in == 0 && in_left > 0) {
			size_t n = in_left < FEED_CHUNK ? in_left : FEED_CHUNK;
			s.next_in = in_next;
			s.avail_in = (mz_uint32)n;
			in_next += n;
			in_left -= n;
		}
		status = mz_deflate(&s,
		    (in_left == 0 && s.avail_in == 0) ? MZ_FINISH : MZ_NO_FLUSH);
		if (status == MZ_STREAM_END)
			break;
		if (status != MZ_OK && status != MZ_BUF_ERROR) {
			mz_deflateEnd(&s);
			free(out);
			return NULL;
		}
		if (s.avail_out == 0) {
			/* Cannot happen: deflate bound covers the worst case. */
			mz_deflateEnd(&s);
			free(out);
			return NULL;
		}
	}
	mz_deflateEnd(&s);

	put_le32(s.next_out,
	    (mz_uint32)mz_crc32(MZ_CRC32_INIT, src ? src : (const unsigned char *)"",
	        src_len));
	put_le32(s.next_out + 4, (mz_uint32)(src_len & 0xffffffffu));

	{
		size_t total = (size_t)(s.next_out - out) + GZIP_TRAILER_SIZE;
		unsigned char *shrunk = (unsigned char *)realloc(out, total ? total : 1);
		if (shrunk)
			out = shrunk;
		*out_len = total;
	}
	return out;
}

/* Decompress a full multi-member gzip stream into one malloc'd buffer.
 * Every member's trailer CRC32/ISIZE is verified; trailing garbage and
 * truncation are errors. NULL on failure.
 */
unsigned char *stach_gzip_decompress(const unsigned char *src, size_t src_len,
                                   size_t *out_len)
{
	mz_stream s;
	size_t cap, used, pos;
	unsigned char *out;

	if (!out_len || !src)
		return NULL;
	*out_len = 0;
	if (src_len == 0)
		return NULL;

	cap = src_len * 4;
	if (cap < 64 * 1024)
		cap = 64 * 1024;
	out = (unsigned char *)malloc(cap);
	if (!out)
		return NULL;
	used = 0;
	pos = 0;

	while (pos < src_len) {
		unsigned flags;
		size_t p, in_fed, member_start;
		int status;

		if (src_len - pos < GZIP_HDR_SIZE + GZIP_TRAILER_SIZE)
			goto fail;
		if (src[pos] != 0x1f || src[pos + 1] != 0x8b || src[pos + 2] != 8)
			goto fail;
		flags = src[pos + 3];
		if (flags & ~0x1fu)
			goto fail; /* reserved FLG bits must be zero */
		p = pos + GZIP_HDR_SIZE;

		if (flags & 0x04) { /* FEXTRA */
			size_t xlen;
			if (src_len - p < 2)
				goto fail;
			xlen = (size_t)src[p] | ((size_t)src[p + 1] << 8);
			p += 2;
			if (src_len - p < xlen)
				goto fail;
			p += xlen;
		}
		if (flags & 0x08) { /* FNAME (NUL-terminated) */
			while (p < src_len && src[p] != 0)
				p += 1;
			if (p >= src_len)
				goto fail;
			p += 1;
		}
		if (flags & 0x10) { /* FCOMMENT (NUL-terminated) */
			while (p < src_len && src[p] != 0)
				p += 1;
			if (p >= src_len)
				goto fail;
			p += 1;
		}
		if (flags & 0x02) { /* FHCRC: CRC16 over the header so far */
			mz_uint32 expect, stored;
			if (src_len - p < 2)
				goto fail;
			expect = (mz_uint32)(mz_crc32(MZ_CRC32_INIT, src + pos, p - pos) & 0xffffu);
			stored = (mz_uint32)src[p] | ((mz_uint32)src[p + 1] << 8);
			if (expect != stored)
				goto fail;
			p += 2;
		}

		memset(&s, 0, sizeof(s));
		in_fed = 0;
		member_start = used;
		s.next_in = src + p;
		s.avail_in = 0;
		s.next_out = out + used;
		s.avail_out = 0; /* grown at the top of the loop */

		if (mz_inflateInit2(&s, -MZ_DEFAULT_WINDOW_BITS) != MZ_OK)
			goto fail;

		for (;;) {
			if (s.avail_out == 0) {
				size_t written = (size_t)(s.next_out - (out + member_start));
				size_t cur = member_start + written;
				size_t ncap = cap * 2;
				unsigned char *n;
				if (ncap < cur + 65536)
					ncap = cur + 65536;
				n = (unsigned char *)realloc(out, ncap);
				if (!n) {
					mz_inflateEnd(&s);
					goto fail;
				}
				out = n;
				cap = ncap;
				s.next_out = out + cur;
				s.avail_out = (mz_uint32)((cap - cur) < FEED_CHUNK
				                             ? (cap - cur)
				                             : FEED_CHUNK);
			}
			if (s.avail_in == 0) {
				size_t remain = src_len - p - in_fed;
				size_t n;
				if (remain == 0) {
					/* Input exhausted without reaching STREAM_END. */
					mz_inflateEnd(&s);
					goto fail;
				}
				n = remain < FEED_CHUNK ? remain : FEED_CHUNK;
				s.next_in = src + p + in_fed;
				s.avail_in = (mz_uint32)n;
				in_fed += n;
			}

			status = mz_inflate(&s, MZ_NO_FLUSH);
			if (status == MZ_STREAM_END)
				break;
			if (status == MZ_BUF_ERROR) {
				/* Progress was ensured above (input fed / output grown);
				 * a BUF here with both windows open means corruption. */
				if (s.avail_in > 0 && s.avail_out > 0) {
					mz_inflateEnd(&s);
					goto fail;
				}
				continue;
			}
			if (status != MZ_OK) {
				mz_inflateEnd(&s);
				goto fail;
			}
		}

		{
			size_t written = (size_t)(s.next_out - (out + member_start));
			size_t consumed = in_fed - s.avail_in;
			const unsigned char *trailer;
			mz_uint32 crc_expect, crc_stored, isize_stored;

			if (src_len - (p + consumed) < GZIP_TRAILER_SIZE) {
				mz_inflateEnd(&s);
				goto fail;
			}
			trailer = src + p + consumed;
			crc_expect = (mz_uint32)mz_crc32(MZ_CRC32_INIT,
			    out + member_start, written);
			crc_stored = get_le32(trailer);
			isize_stored = get_le32(trailer + 4);
			if (crc_expect != crc_stored ||
			    isize_stored != (mz_uint32)(written & 0xffffffffu)) {
				mz_inflateEnd(&s);
				goto fail;
			}
			used = member_start + written;
			pos = p + consumed + GZIP_TRAILER_SIZE;
		}
		mz_inflateEnd(&s);
	}

	{
		unsigned char *shrunk = (unsigned char *)realloc(out, used ? used : 1);
		if (shrunk)
			out = shrunk;
		*out_len = used;
	}
	return out;

fail:
	free(out);
	return NULL;
}

void stach_free(void *p)
{
	if (p)
		free(p);
}
