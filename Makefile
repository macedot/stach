# stach — standalone Odin backup tool
CC      ?= cc
CFLAGS  ?= -O2 -fPIC -Ivendor
ODIN    ?= odin
BUILD   := build
ZSTD_LIB_DIR := vendor/zstd/lib
ZSTD_A  := $(ZSTD_LIB_DIR)/libzstd.a
LIB     := $(BUILD)/libstachzstd.a
OUT     ?= stach

# Linux needs pthread for zstd multi-threaded compress; macOS has it in libSystem.
UNAME_S := $(shell uname -s 2>/dev/null || echo unknown)
ifeq ($(UNAME_S),Linux)
  EXTRA_LINKER := -extra-linker-flags:"-lpthread"
else
  EXTRA_LINKER :=
endif

.PHONY: all clean test zstd

all: $(OUT)

$(BUILD):
	mkdir -p $(BUILD)

# Multi-threaded static libzstd (nbWorkers support).
$(ZSTD_A):
	$(MAKE) -C $(ZSTD_LIB_DIR) libzstd.a-mt

$(BUILD)/stach_zstd_wrap.o: vendor/stach_zstd_wrap.c vendor/zstd/lib/zstd.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ vendor/stach_zstd_wrap.c

# Combine wrap + libzstd into one archive for Odin foreign import.
$(LIB): $(BUILD)/stach_zstd_wrap.o $(ZSTD_A) | $(BUILD)
	rm -rf $(BUILD)/zstd_objs
	mkdir -p $(BUILD)/zstd_objs
	cd $(BUILD)/zstd_objs && ar x ../../$(ZSTD_A)
	ar rcs $@ $(BUILD)/zstd_objs/*.o $(BUILD)/stach_zstd_wrap.o
	rm -rf $(BUILD)/zstd_objs

$(OUT): $(LIB) src/*.odin
	$(ODIN) build src -out:$(OUT) -o:speed $(EXTRA_LINKER)

clean:
	rm -rf $(BUILD) stach stach.exe
	$(MAKE) -C $(ZSTD_LIB_DIR) clean >/dev/null 2>&1 || true

# Functional smoke: file copy, .tar.zst with symlink+hardlink, extract
test: $(OUT)
	@set -e; \
	TMP=$$(mktemp -d); \
	mkdir -p "$$TMP/dir/sub"; \
	echo hello > "$$TMP/a.txt"; \
	echo world > "$$TMP/dir/sub/b.txt"; \
	cp "$$TMP/a.txt" "$$TMP/dir/"; \
	ln -s a.txt "$$TMP/dir/link.txt"; \
	ln "$$TMP/dir/a.txt" "$$TMP/dir/hard.txt"; \
	OUT_TXT=$$(cd "$$TMP" && "$(CURDIR)/$(OUT)" -j 2 -c 2 a.txt dir 2>"$$TMP/err"); \
	echo "$$OUT_TXT"; \
	test -z "$$(cat "$$TMP/err")" || (echo "STDERR:" && cat "$$TMP/err" && exit 1); \
	echo "$$OUT_TXT" | grep -q 'a.txt -> a.txt.'; \
	echo "$$OUT_TXT" | grep -q 'dir -> dir.'; \
	TZST=$$(ls "$$TMP"/dir.*.tar.zst); \
	test -f "$$TZST"; \
	diff -u "$$TMP/a.txt" "$$TMP"/a.txt.*; \
	mkdir -p "$$TMP/out"; \
	XOUT=$$(cd "$$TMP" && "$(CURDIR)/$(OUT)" -c 2 -x "$$(basename "$$TZST")" out 2>"$$TMP/err2"); \
	echo "$$XOUT"; \
	test -z "$$(cat "$$TMP/err2")" || (echo "STDERR:" && cat "$$TMP/err2" && exit 1); \
	test "$$(readlink "$$TMP/out/dir/link.txt")" = "a.txt"; \
	diff -u "$$TMP/dir/a.txt" "$$TMP/out/dir/hard.txt"; \
	diff -u "$$TMP/dir/sub/b.txt" "$$TMP/out/dir/sub/b.txt"; \
	echo quiet > "$$TMP/q.txt"; \
	mkdir -p "$$TMP/qd/sub"; \
	echo zipped > "$$TMP/qd/sub/z.txt"; \
	QOUT=$$(cd "$$TMP" && "$(CURDIR)/$(OUT)" --quiet q.txt qd 2>"$$TMP/errq"); \
	test -z "$$QOUT" || (echo "Expected empty stdout with --quiet backup" && echo "$$QOUT" && exit 1); \
	test -z "$$(cat "$$TMP/errq")" || (echo "STDERR (--quiet backup):" && cat "$$TMP/errq" && exit 1); \
	QZST=$$(ls "$$TMP"/qd.*.tar.zst); \
	mkdir -p "$$TMP/outq"; \
	QXOUT=$$(cd "$$TMP" && "$(CURDIR)/$(OUT)" --quiet -x "$$(basename "$$QZST")" outq 2>"$$TMP/errq2"); \
	test -z "$$QXOUT" || (echo "Expected empty stdout with --quiet extract" && echo "$$QXOUT" && exit 1); \
	test -z "$$(cat "$$TMP/errq2")" || (echo "STDERR (--quiet extract):" && cat "$$TMP/errq2" && exit 1); \
	diff -u "$$TMP/qd/sub/z.txt" "$$TMP/outq/qd/sub/z.txt"; \
	mkdir -p "$$TMP/big/sub"; \
	dd if=/dev/zero bs=1024 count=1536 2>/dev/null | tr '\0' 'Z' > "$$TMP/big/a.bin"; \
	dd if=/dev/urandom bs=1024 count=256 2>/dev/null > "$$TMP/big/b.bin"; \
	echo x > "$$TMP/big/sub/c.txt"; \
	ln -s c.txt "$$TMP/big/sub/link.txt"; \
	BOUT=$$(cd "$$TMP" && "$(CURDIR)/$(OUT)" --quiet -c 4 big 2>"$$TMP/errb"); \
	test -z "$$BOUT"; \
	test -z "$$(cat "$$TMP/errb")" || (echo "STDERR (big pack):" && cat "$$TMP/errb" && exit 1); \
	BTGZ=$$(ls "$$TMP"/big.*.tar.zst); \
	mkdir -p "$$TMP/outb"; \
	BX=$$(cd "$$TMP" && "$(CURDIR)/$(OUT)" --quiet -c 4 -x "$$(basename "$$BTGZ")" outb 2>"$$TMP/errbx"); \
	test -z "$$BX"; \
	test -z "$$(cat "$$TMP/errbx")" || (echo "STDERR (big extract):" && cat "$$TMP/errbx" && exit 1); \
	diff -q "$$TMP/big/a.bin" "$$TMP/outb/big/a.bin"; \
	diff -q "$$TMP/big/b.bin" "$$TMP/outb/big/b.bin"; \
	test "$$(readlink "$$TMP/outb/big/sub/link.txt")" = "c.txt"; \
	LISTTMP=$$(mktemp -d); \
	BASE=$$(basename "$$LISTTMP"); \
	mkdir -p "$$LISTTMP/cfg" "$$LISTTMP/docs"; \
	echo keep > "$$LISTTMP/cfg/a.txt"; \
	echo one > "$$LISTTMP/docs/one.pdf"; \
	echo two > "$$LISTTMP/docs/two.pdf"; \
	echo root > "$$LISTTMP/root.txt"; \
	printf '%s\n' \
		'# comment' \
		'cfg' \
		'root.txt' \
		'docs/*.pdf' \
		'missing-file-xyz' \
		> "$$LISTTMP/$$BASE.list"; \
	LOUT=$$(cd "$$LISTTMP" && "$(CURDIR)/$(OUT)" -c 2 2>"$$LISTTMP/errl"); \
	echo "$$LOUT"; \
	test -z "$$(grep -v 'skip (not found)' "$$LISTTMP/errl" || true)" || (echo "STDERR (list default):" && cat "$$LISTTMP/errl" && exit 1); \
	grep -q 'skip (not found)' "$$LISTTMP/errl"; \
	echo "$$LOUT" | grep -q "$$BASE -> $$BASE."; \
	LTZST=$$(ls "$$LISTTMP"/$$BASE.*.tar.zst); \
	test -f "$$LTZST"; \
	test $$(ls "$$LISTTMP"/*.tar.zst | wc -l | tr -d ' ') -eq 1; \
	mkdir -p "$$LISTTMP/outl"; \
	LX=$$(cd "$$LISTTMP" && "$(CURDIR)/$(OUT)" -c 2 -x "$$(basename "$$LTZST")" outl 2>"$$LISTTMP/errlx"); \
	echo "$$LX"; \
	test -z "$$(cat "$$LISTTMP/errlx")" || (echo "STDERR (list extract):" && cat "$$LISTTMP/errlx" && exit 1); \
	diff -u "$$LISTTMP/cfg/a.txt" "$$LISTTMP/outl/cfg/a.txt"; \
	diff -u "$$LISTTMP/root.txt" "$$LISTTMP/outl/root.txt"; \
	diff -u "$$LISTTMP/docs/one.pdf" "$$LISTTMP/outl/docs/one.pdf"; \
	diff -u "$$LISTTMP/docs/two.pdf" "$$LISTTMP/outl/docs/two.pdf"; \
	rm -f "$$LTZST"; \
	printf '%s\n' 'root.txt' 'cfg' > "$$LISTTMP/custom.list"; \
	QLOUT=$$(cd "$$LISTTMP" && "$(CURDIR)/$(OUT)" --quiet -f custom.list 2>"$$LISTTMP/errql"); \
	test -z "$$QLOUT" || (echo "Expected empty stdout with --quiet list mode" && echo "$$QLOUT" && exit 1); \
	test -z "$$(cat "$$LISTTMP/errql")" || (echo "STDERR (--quiet list):" && cat "$$LISTTMP/errql" && exit 1); \
	test $$(ls "$$LISTTMP"/$$BASE.*.tar.zst | wc -l | tr -d ' ') -eq 1; \
	rm -rf "$$LISTTMP"; \
	echo "OK"; \
	rm -rf "$$TMP"
