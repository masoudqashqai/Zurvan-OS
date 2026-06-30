#!/bin/sh
# Build a statically-linked busybox for the Zurvan rootfs.
#
# Output: userland/build/busybox  (single static binary; applets are symlinks
#         to it, created later by scripts/build.sh when assembling the rootfs)
#
# Override version with BBVER. Drop a curated config next to this script as
# `busybox.config` to use it instead of `make defconfig`.
set -eu

BBVER="${BBVER:-1.36.1}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$HERE/src/busybox-$BBVER"
OUT_DIR="$HERE/build"
TARBALL="busybox-$BBVER.tar.bz2"
URL="https://busybox.net/downloads/$TARBALL"

mkdir -p "$HERE/src" "$OUT_DIR"

# --- fetch ------------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
	if [ ! -f "$HERE/src/$TARBALL" ]; then
		echo ">> downloading $URL"
		curl -fL --retry 3 -o "$HERE/src/$TARBALL" "$URL"
	fi
	echo ">> extracting $TARBALL"
	tar -C "$HERE/src" -xf "$HERE/src/$TARBALL"
fi

cd "$SRC_DIR"

# --- configure --------------------------------------------------------------
if [ -f "$HERE/busybox.config" ]; then
	echo ">> using curated busybox.config"
	cp "$HERE/busybox.config" .config
	make oldconfig
else
	echo ">> make defconfig"
	make defconfig
fi

# Force static linking (no dynamic loader to ship).
echo ">> enabling CONFIG_STATIC"
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config || true
grep -q '^CONFIG_STATIC=y' .config || echo 'CONFIG_STATIC=y' >> .config
make oldconfig

# --- build ------------------------------------------------------------------
echo ">> building busybox with -j$JOBS"
make -j"$JOBS"

cp -f busybox "$OUT_DIR/busybox"
echo ">> done: $OUT_DIR/busybox"
file "$OUT_DIR/busybox" 2>/dev/null || true
