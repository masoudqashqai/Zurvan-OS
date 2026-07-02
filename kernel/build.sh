#!/bin/sh
# Fetch, configure and build the Linux kernel for Zurvan's QEMU/initramfs path.
#
# Output: kernel/build/bzImage
#
# This is a starting point. The CONFIG bits that matter live in ./config-fragment;
# read kernel/README.md before trusting the result. Override the version with KVER.
set -eu

# 6.6 LTS. kernel.org prunes old point releases — if the download 404s, pick
# the current 6.6.y from https://www.kernel.org/releases.json (was 6.6.30).
KVER="${KVER:-6.6.143}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
# Source/build trees can be redirected off the repo with ZURVAN_SRC_BASE —
# needed under WSL, where compiling on a /mnt/* Windows mount is ~10x slower
# than on the native ext4 filesystem. Final artifacts still land in $OUT_DIR.
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/src}"
SRC_DIR="$SRC_BASE/linux-$KVER"
OUT_DIR="$HERE/build"
TARBALL="linux-$KVER.tar.xz"
# major version dir on kernel.org, e.g. 6.6.30 -> v6.x
MAJOR="$(printf '%s' "$KVER" | cut -d. -f1)"
# KMIRROR: alternate download base when cdn.kernel.org is unreachable, e.g.
#   KMIRROR=https://mirrors.tuna.tsinghua.edu.cn/kernel
KMIRROR="${KMIRROR:-https://cdn.kernel.org/pub/linux/kernel}"
URL="$KMIRROR/v${MAJOR}.x/$TARBALL"

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
# Start from defconfig, then merge in the symbols our boot path needs.
echo ">> make defconfig"
make defconfig

if [ -x scripts/kconfig/merge_config.sh ]; then
	echo ">> merging config-fragment"
	# merge_config.sh mishandles paths containing spaces (unquoted expansion
	# inside the script), so stage the fragment at a space-free temp path.
	FRAG="$(mktemp /tmp/zurvan-config-fragment.XXXXXX)"
	cp "$HERE/config-fragment" "$FRAG"
	scripts/kconfig/merge_config.sh -m .config "$FRAG"
	rm -f "$FRAG"
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
