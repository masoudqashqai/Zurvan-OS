#!/bin/sh
# Build static e2fsprogs (mke2fs + e2fsck) for the Zurvan rootfs.
#
# Why not busybox? Its mke2fs applet only makes ext2. The persistent /data
# partition (v2 milestone 1) is ext4, so zurvan-install needs the real mke2fs
# and rc.init wants the real e2fsck -p before mounting.
#
# Output: userland/build/mke2fs, userland/build/e2fsck, userland/build/mke2fs.conf
# Override version with E2VER. E2MIRROR switches the download base (same layout
# as kernel.org, e.g. https://mirrors.tuna.tsinghua.edu.cn/kernel).
set -eu

E2VER="${E2VER:-1.47.1}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
# See kernel/build.sh: ZURVAN_SRC_BASE moves source trees off /mnt/* under WSL.
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/src}"
SRC_DIR="$SRC_BASE/e2fsprogs-$E2VER"
OUT_DIR="$HERE/build"
TARBALL="e2fsprogs-$E2VER.tar.xz"
E2MIRROR="${E2MIRROR:-https://cdn.kernel.org/pub/linux/kernel}"
URL="$E2MIRROR/people/tytso/e2fsprogs/v$E2VER/$TARBALL"

mkdir -p "$SRC_BASE" "$OUT_DIR"

# --- fetch ------------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
	if [ ! -f "$SRC_BASE/$TARBALL" ]; then
		echo ">> downloading $URL"
		curl -fL --retry 3 -o "$SRC_BASE/$TARBALL" "$URL"
	fi
	echo ">> extracting $TARBALL"
	tar -C "$SRC_BASE" -xf "$SRC_BASE/$TARBALL"
fi

cd "$SRC_DIR"

# --- configure --------------------------------------------------------------
# LDFLAGS=-static makes every shipped binary fully static (no dynamic loader
# in the image). The disables trim daemons/tools Zurvan never runs.
if [ ! -f Makefile ]; then
	echo ">> configure (static)"
	./configure \
		--disable-nls \
		--disable-uuidd \
		--disable-fuse2fs \
		--disable-debugfs \
		--disable-imager \
		--disable-defrag \
		CFLAGS="-O2 -std=gnu17" LDFLAGS="-static"
		# -std=gnu17: 1.47.1's bundled tdb typedef's `bool`, which GCC 15's
		# C23 default rejects (same era-mismatch as the busybox/bash fixes).
fi

# --- build ------------------------------------------------------------------
echo ">> building e2fsprogs with -j$JOBS"
make -j"$JOBS"

cp -f e2fsck/e2fsck "$OUT_DIR/e2fsck"
cp -f misc/mke2fs   "$OUT_DIR/mke2fs"
# mke2fs without a config falls back to pre-ext4 feature defaults; ship the one
# the build generated so `mkfs.ext4` means what it says.
cp -f misc/mke2fs.conf "$OUT_DIR/mke2fs.conf"

echo ">> done: $OUT_DIR/mke2fs, $OUT_DIR/e2fsck"
file "$OUT_DIR/mke2fs" "$OUT_DIR/e2fsck" 2>/dev/null || true
