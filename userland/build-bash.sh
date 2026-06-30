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
SRC_DIR="$HERE/src/bash-$BASHVER"
OUT_DIR="$HERE/build"
TARBALL="bash-$BASHVER.tar.gz"
URL="https://ftp.gnu.org/gnu/bash/$TARBALL"

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

# --- configure + build (static) --------------------------------------------
# --enable-static-link asks bash's build to link statically.
# CC can be overridden to musl-gcc for a cleaner static build.
echo ">> configuring bash (static)"
CC="${CC:-cc}" ./configure \
	--without-bash-malloc \
	--enable-static-link

echo ">> building bash with -j$JOBS"
make -j"$JOBS"

cp -f bash "$OUT_DIR/bash"
echo ">> done: $OUT_DIR/bash"
file "$OUT_DIR/bash" 2>/dev/null || true
