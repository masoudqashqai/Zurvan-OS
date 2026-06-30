#!/bin/sh
# Fetch, configure and build the Linux kernel for Zurvan's QEMU/initramfs path.
#
# Output: kernel/build/bzImage
#
# This is a starting point. The CONFIG bits that matter live in ./config-fragment;
# read kernel/README.md before trusting the result. Override the version with KVER.
set -eu

KVER="${KVER:-6.6.30}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$HERE/src/linux-$KVER"
OUT_DIR="$HERE/build"
TARBALL="linux-$KVER.tar.xz"
# major version dir on kernel.org, e.g. 6.6.30 -> v6.x
MAJOR="$(printf '%s' "$KVER" | cut -d. -f1)"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/$TARBALL"

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
# Start from defconfig, then merge in the symbols our boot path needs.
echo ">> make defconfig"
make defconfig

if [ -x scripts/kconfig/merge_config.sh ]; then
	echo ">> merging config-fragment"
	scripts/kconfig/merge_config.sh -m .config "$HERE/config-fragment"
	make olddefconfig
else
	echo "!! merge_config.sh not found; ensure these are set by hand (menuconfig):"
	echo "   $(grep -v '^#' "$HERE/config-fragment" | grep . | tr '\n' ' ')"
fi

echo ">> review the config now if you want:  (cd $SRC_DIR && make menuconfig)"

# --- build ------------------------------------------------------------------
echo ">> building bzImage with -j$JOBS"
make -j"$JOBS" bzImage

cp -f arch/x86/boot/bzImage "$OUT_DIR/bzImage"
echo ">> done: $OUT_DIR/bzImage"
