#!/bin/sh
# Build a statically-linked bash for the Zurvan rootfs.
#
# bash is an explicit requirement — the system should have real bash, not just
# busybox's `sh`. Output: userland/build/bash (static).
#
# Override version with BASHVER. Static linking against glibc can be fussy; if it
# fights you, building against musl (musl-gcc) is the path of least resistance.
set -eu

BASHVER="${BASHVER:-5.2.21}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
# See kernel/build.sh: ZURVAN_SRC_BASE moves source trees off /mnt/* under WSL.
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/src}"
SRC_DIR="$SRC_BASE/bash-$BASHVER"
OUT_DIR="$HERE/build"
TARBALL="bash-$BASHVER.tar.gz"
URL="https://ftp.gnu.org/gnu/bash/$TARBALL"

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

# --- configure + build (static) --------------------------------------------
# --enable-static-link asks bash's build to link statically.
# CC can be overridden to musl-gcc for a cleaner static build.
echo ">> configuring bash (static)"
# GCC >= 14 compatibility for bash 5.2's K&R-era C:
#   -std=gnu17                            C23 turns empty-parameter declarations
#                                         (e.g. xmalloc) into hard errors
#   -Wno-implicit-function-declaration    the bundled termcap calls write()
#                                         without declaring it, error by default
CC="${CC:-cc}" CFLAGS="${CFLAGS:--g -O2 -std=gnu17 -Wno-implicit-function-declaration}" ./configure \
	--without-bash-malloc \
	--enable-static-link

echo ">> building bash with -j$JOBS"
make -j"$JOBS"

cp -f bash "$OUT_DIR/bash"
echo ">> done: $OUT_DIR/bash"
file "$OUT_DIR/bash" 2>/dev/null || true
