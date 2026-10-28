/*
 * Filesystem shim for stach: the operations the Goose stdlib (v2026.3) lacks,
 * implemented over POSIX or Win32. All paths are UTF-8 (Goose's convention,
 * converted to UTF-16 for the Windows API).
 *
 * Layout contract with src/zstd.goose / src/pathutil.goose (the Goose side
 * declares matching `extern fn`s; the compiler maps slices and struct
 * references to these shapes):
 *   - stach_bytes mirrors a Goose u8[:] slice: { data, len }.
 *   - stach_stat mirrors the Goose Stach_Stat struct: u64 u64 u64 i64 u32 i32
 *     in that order, no padding on either side.
 *   - out-buffers arrive as (pointer, capacity) pairs into caller memory.
 *
 * Functions return 0 (or a length) on success, -1 on failure; errno /
 * GetLastError distinguishes causes only insofar as stach needs (exists vs
 * broke), so the Goose side re-checks with os::file_exists / os::is_dir.
 */

#include <stdint.h>

#define STACH_TYPE_OTHER   0
#define STACH_TYPE_FILE    1
#define STACH_TYPE_DIR     2
#define STACH_TYPE_SYMLINK 3

typedef struct { const unsigned char *data; int64_t len; } stach_bytes;
typedef struct { unsigned char *data; int64_t len; } stach_mutbytes;

typedef struct {
	uint64_t dev;
	uint64_t ino;
	uint64_t size;
	int64_t mtime;   /* unix seconds */
	uint32_t mode;   /* permission bits, 0..07777 */
	int32_t type;    /* STACH_TYPE_* */
} stach_stat;

int32_t stach_lstat(stach_bytes path, stach_stat *out);
int64_t stach_readlink(stach_bytes path, stach_mutbytes buf);
int32_t stach_symlink(stach_bytes target, stach_bytes linkpath, int32_t target_is_dir);
int32_t stach_hardlink(stach_bytes existing, stach_bytes newpath);
int32_t stach_chmod(stach_bytes path, uint32_t mode);
int64_t stach_getcwd(stach_mutbytes buf);

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <io.h>
#include <stdlib.h>
#include <string.h>

/* UTF-8 -> UTF-16; returns malloc'd string (NUL-terminated) or NULL. */
static wchar_t *stach_to_wide(const unsigned char *data, int64_t len)
{
	int wlen;
	wchar_t *out;

	if (len < 0 || len > INT32_MAX)
		return NULL;
	if (!data)
		return NULL;
	wlen = MultiByteToWideChar(CP_UTF8, 0, (const char *)data, (int)len, NULL, 0);
	if (wlen <= 0)
		return NULL;
	out = (wchar_t *)malloc((size_t)(wlen + 1) * sizeof(wchar_t));
	if (!out)
		return NULL;
	if (MultiByteToWideChar(CP_UTF8, 0, (const char *)data, (int)len, out, wlen) != wlen) {
		free(out);
		return NULL;
	}
	out[wlen] = 0;
	return out;
}

/* UTF-16 -> UTF-8 into caller's buffer; returns bytes written or -1. */
static int64_t stach_from_wide(const wchar_t *w, unsigned char *buf, int64_t cap)
{
	int n;

	if (cap < 0 || cap > INT32_MAX)
		return -1;
	n = WideCharToMultiByte(CP_UTF8, 0, w, -1, (char *)buf, (int)cap, NULL, NULL);
	if (n <= 0)
		return -1;
	return (int64_t)n - 1; /* without the NUL */
}

static int64_t stach_filetime_unix(const FILETIME *ft)
{
	uint64_t t = ((uint64_t)ft->dwHighDateTime << 32) | ft->dwLowDateTime;
	return (int64_t)((t - 116444736000000000ULL) / 10000000ULL);
}

static void stach_mode_from_attrs(DWORD attrs, uint32_t *mode)
{
	if (attrs & FILE_ATTRIBUTE_DIRECTORY)
		*mode = (attrs & FILE_ATTRIBUTE_READONLY) ? 0555 : 0755;
	else
		*mode = (attrs & FILE_ATTRIBUTE_READONLY) ? 0444 : 0644;
}

int32_t stach_lstat(stach_bytes path, stach_stat *out)
{
	wchar_t *w;
	HANDLE h;
	BY_HANDLE_FILE_INFORMATION info;
	DWORD tag_bits;

	if (!out || !path.data)
		return -1;
	memset(out, 0, sizeof(*out));
	out->type = STACH_TYPE_OTHER;

	w = stach_to_wide(path.data, path.len);
	if (!w)
		return -1;
	h = CreateFileW(w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
	                NULL, OPEN_EXISTING,
	                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
	if (h == INVALID_HANDLE_VALUE) {
		free(w);
		return -1;
	}
	if (!GetFileInformationByHandle(h, &info)) {
		CloseHandle(h);
		free(w);
		return -1;
	}
	CloseHandle(h);

	out->dev = info.dwVolumeSerialNumber;
	out->ino = ((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow;
	out->size = ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
	out->mtime = stach_filetime_unix(&info.ftLastWriteTime);

	tag_bits = info.dwFileAttributes;
	if (tag_bits & FILE_ATTRIBUTE_REPARSE_POINT) {
		/* Symlinks (and junctions) carry a reparse tag; use FindFirstFileW
		 * to read it without opening the target. */
		WIN32_FIND_DATAW fd;
		HANDLE f = FindFirstFileW(w, &fd);
		if (f != INVALID_HANDLE_VALUE) {
			if (fd.dwReserved0 == IO_REPARSE_TAG_SYMLINK)
				out->type = STACH_TYPE_SYMLINK;
			FindClose(f);
		}
	}
	if (out->type != STACH_TYPE_SYMLINK) {
		if (tag_bits & FILE_ATTRIBUTE_DIRECTORY)
			out->type = STACH_TYPE_DIR;
		else
			out->type = STACH_TYPE_FILE;
	}
	stach_mode_from_attrs(tag_bits, &out->mode);
	free(w);
	return 0;
}

/* Reads a symlink's target via the reparse point. Serves the substitute name
 * (absolute targets may carry a "\??\" prefix, which is stripped). */
int64_t stach_readlink(stach_bytes path, stach_mutbytes buf)
{
	wchar_t *w;
	HANDLE h;
	unsigned char rbuf[MAXIMUM_REPARSE_DATA_BUFFER_SIZE];
	REPARSE_DATA_BUFFER *rp = (REPARSE_DATA_BUFFER *)rbuf;
	DWORD got = 0;
	wchar_t *base, *target;
	USHORT sublen;
	int64_t n = -1;

	if (!path.data || !buf.data)
		return -1;
	w = stach_to_wide(path.data, path.len);
	if (!w)
		return -1;
	h = CreateFileW(w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
	                NULL, OPEN_EXISTING,
	                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
	free(w);
	if (h == INVALID_HANDLE_VALUE)
		return -1;
	if (!DeviceIoControl(h, FSCTL_GET_REPARSE_POINT, NULL, 0, rbuf,
	                     sizeof(rbuf), &got, NULL)) {
		CloseHandle(h);
		return -1;
	}
	CloseHandle(h);
	if (rp->ReparseTag != IO_REPARSE_TAG_SYMLINK)
		return -1;

	base = (wchar_t *)malloc(((size_t)rp->SubstituteNameLength / sizeof(wchar_t) + 1) * sizeof(wchar_t));
	if (!base)
		return -1;
	sublen = rp->SubstituteNameLength / sizeof(wchar_t);
	memcpy(base, (const wchar_t *)(rbuf + rp->SubstituteNameOffset),
	       (size_t)sublen * sizeof(wchar_t));
	base[sublen] = 0;
	target = base;
	/* Strip the Win32 namespace prefix when present. */
	if (sublen >= 4 && target[0] == L'\\' && target[1] == L'?' && target[2] == L'?' &&
	    target[3] == L'\\') {
		target += 4;
		sublen = (USHORT)(sublen - 4);
	}
	n = stach_from_wide(target, buf.data, buf.len);
	free(base);
	return n;
}

int32_t stach_symlink(stach_bytes target, stach_bytes linkpath, int32_t target_is_dir)
{
	wchar_t *wt, *wl;
	DWORD flags;
	BOOL ok;

	wt = stach_to_wide(target.data, target.len);
	wl = stach_to_wide(linkpath.data, linkpath.len);
	if (!wt || !wl) {
		free(wt);
		free(wl);
		return -1;
	}
	flags = target_is_dir ? SYMBOLIC_LINK_FLAG_DIRECTORY : 0;
	ok = CreateSymbolicLinkW(wl, wt, flags | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE);
	if (!ok && GetLastError() == ERROR_INVALID_PARAMETER)
		ok = CreateSymbolicLinkW(wl, wt, flags); /* pre-1703 Windows */
	free(wt);
	free(wl);
	return ok ? 0 : -1;
}

int32_t stach_hardlink(stach_bytes existing, stach_bytes newpath)
{
	wchar_t *we, *wn;
	BOOL ok;

	we = stach_to_wide(existing.data, existing.len);
	wn = stach_to_wide(newpath.data, newpath.len);
	if (!we || !wn) {
		free(we);
		free(wn);
		return -1;
	}
	ok = CreateHardLinkW(wn, we, NULL);
	free(we);
	free(wn);
	return ok ? 0 : -1;
}

int32_t stach_chmod(stach_bytes path, uint32_t mode)
{
	wchar_t *w;
	int r;

	w = stach_to_wide(path.data, path.len);
	if (!w)
		return -1;
	r = _wchmod(w, (int)(mode & 07777));
	free(w);
	return r == 0 ? 0 : -1;
}

int64_t stach_getcwd(stach_mutbytes buf)
{
	wchar_t wbuf[4096];
	DWORD n;

	n = GetCurrentDirectoryW(4096, wbuf);
	if (n == 0 || n >= 4096)
		return -1;
	return stach_from_wide(wbuf, buf.data, buf.len);
}

#else /* POSIX */

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* NUL-terminate a goose slice into a stack buffer when it fits, else malloc. */
static char *stach_to_cstr(stach_bytes path, char *stack_buf, size_t stack_cap)
{
	char *out;

	if (!path.data || path.len < 0 || (size_t)path.len >= stack_cap)
		return NULL;
	out = stack_buf;
	memcpy(out, path.data, (size_t)path.len);
	out[path.len] = 0;
	return out;
}

int32_t stach_lstat(stach_bytes path, stach_stat *out)
{
	char stack_buf[4096];
	char *p = stach_to_cstr(path, stack_buf, sizeof(stack_buf));
	struct stat st;

	if (!p || !out)
		return -1;
	memset(out, 0, sizeof(*out));
	if (lstat(p, &st) != 0)
		return -1;
	out->dev = (uint64_t)st.st_dev;
	out->ino = (uint64_t)st.st_ino;
	out->size = (uint64_t)st.st_size;
#if defined(__APPLE__)             /* macOS: st_mtime is a macro for st_mtimespec.tv_sec */
	out->mtime = (int64_t)st.st_mtimespec.tv_sec;
#elif defined(st_mtime)            /* glibc: st_mtime expands to st_mtim.tv_sec */
	out->mtime = (int64_t)st.st_mtim.tv_sec;
#else
	out->mtime = (int64_t)st.st_mtime;
#endif
	out->mode = (uint32_t)(st.st_mode & 07777);
	if (S_ISLNK(st.st_mode))
		out->type = STACH_TYPE_SYMLINK;
	else if (S_ISDIR(st.st_mode))
		out->type = STACH_TYPE_DIR;
	else if (S_ISREG(st.st_mode))
		out->type = STACH_TYPE_FILE;
	else
		out->type = STACH_TYPE_OTHER;
	return 0;
}

int64_t stach_readlink(stach_bytes path, stach_mutbytes buf)
{
	char stack_buf[4096];
	char *p = stach_to_cstr(path, stack_buf, sizeof(stack_buf));
	ssize_t n;

	if (!p || !buf.data || buf.len <= 0)
		return -1;
	n = readlink(p, (char *)buf.data, (size_t)buf.len);
	if (n < 0)
		return -1;
	return (int64_t)n;
}

int32_t stach_symlink(stach_bytes target, stach_bytes linkpath, int32_t target_is_dir)
{
	char stack_t[4096], stack_l[4096];
	char *t = stach_to_cstr(target, stack_t, sizeof(stack_t));
	char *l = stach_to_cstr(linkpath, stack_l, sizeof(stack_l));

	(void)target_is_dir; /* POSIX symlinks carry no dir flag */
	if (!t || !l)
		return -1;
	if (symlink(t, l) != 0)
		return -1;
	return 0;
}

int32_t stach_hardlink(stach_bytes existing, stach_bytes newpath)
{
	char stack_e[4096], stack_n[4096];
	char *e = stach_to_cstr(existing, stack_e, sizeof(stack_e));
	char *n = stach_to_cstr(newpath, stack_n, sizeof(stack_n));

	if (!e || !n)
		return -1;
	if (link(e, n) != 0)
		return -1;
	return 0;
}

int32_t stach_chmod(stach_bytes path, uint32_t mode)
{
	char stack_buf[4096];
	char *p = stach_to_cstr(path, stack_buf, sizeof(stack_buf));

	if (!p)
		return -1;
	if (chmod(p, (mode_t)(mode & 07777)) != 0)
		return -1;
	return 0;
}

int64_t stach_getcwd(stach_mutbytes buf)
{
	if (!buf.data || buf.len <= 0)
		return -1;
	if (getcwd((char *)buf.data, (size_t)buf.len) == NULL)
		return -1;
	return (int64_t)strlen((char *)buf.data);
}

#endif /* POSIX */
