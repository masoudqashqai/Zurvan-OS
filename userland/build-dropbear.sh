#!/bin/sh
# Build a statically-linked dropbear (SSH server + client) for the Zurvan rootfs.
#
# One multi-call binary, busybox-style: dropbearmulti contains dropbear (server),
# dropbearkey, dbclient (ssh) and scp; scripts/build.sh installs the symlinks.
#
# Output: userland/build/dropbearmulti
#
# Static getpwnam() note: works because modern glibc compiles the "files" NSS
# backend into libc itself — user lookups against /etc/passwd need no shared
# libraries at runtime.
set -eu

DBVER="${DBVER:-2026.91}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
# See kernel/build.sh: ZURVAN_SRC_BASE moves source trees off /mnt/* under WSL.
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/src}"
SRC_DIR="$SRC_BASE/dropbear-$DBVER"
OUT_DIR="$HERE/build"
TARBALL="dropbear-$DBVER.tar.bz2"
URL="https://matt.ucc.asn.au/dropbear/releases/$TARBALL"

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

# --- configure + build (static, multi-call) ----------------------------------
# --disable-zlib: compression is optional and drops the only external library.
echo ">> configuring dropbear (static)"
CC="${CC:-cc}" ./configure \
	--enable-static \
	--disable-zlib

echo ">> building dropbearmulti with -j$JOBS"
make -j"$JOBS" MULTI=1 PROGRAMS="dropbear dropbearkey dbclient scp"

cp -f dropbearmulti "$OUT_DIR/dropbearmulti"
echo ">> done: $OUT_DIR/dropbearmulti"
file "$OUT_DIR/dropbearmulti" 2>/dev/null || true
