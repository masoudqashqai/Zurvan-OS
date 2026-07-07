#!/bin/sh
# Build BearSSL for the Zurvan web panel (v2 M6, "the face").
#
# BearSSL is a from-scratch TLS implementation in standalone C: no autotools,
# no external libraries, no dynamic anything — it compiles to one static
# archive (libbearssl.a) with a plain `make`. That is exactly the fit for a
# loader-less image where the panel must be a single static binary. It gives
# us a TLS 1.2 server engine (and the `brssl` tool, which we don't ship).
#
# We build it from source on purpose, same as every other Zurvan component.
#
# Output:
#   userland/build/libbearssl.a        the static archive zurvan-face links
#   userland/build/bearssl-inc/        its headers (bearssl.h + friends)
set -eu

BEARSSL_VER="${BEARSSL_VER:-0.6}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/src}"
SRC_DIR="$SRC_BASE/BearSSL-$BEARSSL_VER"
OUT_DIR="$HERE/build"
TARBALL="bearssl-$BEARSSL_VER.tar.gz"
MIRROR="${BEARSSL_MIRROR:-https://bearssl.org}"
URL="$MIRROR/$TARBALL"

mkdir -p "$SRC_BASE" "$OUT_DIR"

# --- fetch ------------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
	[ -f "$SRC_BASE/$TARBALL" ] \
		|| curl -fL --retry 3 -o "$SRC_BASE/$TARBALL" "$URL"
	tar -C "$SRC_BASE" -xf "$SRC_BASE/$TARBALL"
fi

cd "$SRC_DIR"

# --- build the static archive -----------------------------------------------
echo ">> building libbearssl.a with -j$JOBS"
make -j"$JOBS" lib >/dev/null 2>&1 || make -j"$JOBS" >/dev/null

# BearSSL's makefile drops the archive under build/ inside its own tree.
ARCHIVE="$(find . -name 'libbearssl.a' | head -1)"
[ -n "$ARCHIVE" ] || { echo "!! libbearssl.a not produced" >&2; exit 1; }
cp -f "$ARCHIVE" "$OUT_DIR/libbearssl.a"

rm -rf "$OUT_DIR/bearssl-inc"
mkdir -p "$OUT_DIR/bearssl-inc"
cp -f inc/*.h "$OUT_DIR/bearssl-inc/"

echo ">> done: $OUT_DIR/libbearssl.a"
ls -l "$OUT_DIR/libbearssl.a"
