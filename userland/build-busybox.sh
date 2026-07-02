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
# See kernel/build.sh: ZURVAN_SRC_BASE moves source trees off /mnt/* under WSL.
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/src}"
SRC_DIR="$SRC_BASE/busybox-$BBVER"
OUT_DIR="$HERE/build"
TARBALL="busybox-$BBVER.tar.bz2"
URL="https://busybox.net/downloads/$TARBALL"

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

# busybox 1.36's tc applet doesn't compile against kernel headers >= 6.8
# (CBQ qdisc definitions were removed). We don't ship traffic control.
echo ">> disabling CONFIG_TC"
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config

make oldconfig

# --- build ------------------------------------------------------------------
echo ">> building busybox with -j$JOBS"
make -j"$JOBS"

cp -f busybox "$OUT_DIR/busybox"
echo ">> done: $OUT_DIR/busybox"
file "$OUT_DIR/busybox" 2>/dev/null || true
