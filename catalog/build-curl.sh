#!/bin/sh
# catalog/build-curl.sh — a TLS-capable fetch tool for the box.
#
# busybox wget speaks plain HTTP only; real servers need HTTPS for webhooks,
# health checks, and pulling package tarballs straight onto /data. The
# interesting choices:
#
#   * TLS is BEARSSL — the exact library the panel already uses, reused from
#     userland/build (libbearssl.a + headers). No OpenSSL enters the image,
#     and the catalog stays on one TLS stack. curl kept its BearSSL backend
#     through 8.14; the version is pinned accordingly.
#   * CERTIFICATES ship inside the package: Mozilla's CA bundle (via curl.se)
#     lands at /data/apps/curl/etc/ca-bundle.crt and the binary is compiled to
#     look exactly there — a read-only root has no /etc/ssl to lean on.
#   * PROTOCOLS are http/https/ftp(s) only; every optional dependency (zlib,
#     brotli, nghttp2, idn, psl, ldap...) is disabled so the binary is one
#     self-contained file, like every Zurvan package.
#
# Output: build/catalog/curl-<version>.tar.gz
set -eu

CURL_VER="${CURL_VER:-8.12.1}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/catalog/src}"
SRC_DIR="$SRC_BASE/curl-$CURL_VER"
OUT_DIR="${OUT_DIR:-$HERE/build/catalog}"
TARBALL="curl-$CURL_VER.tar.gz"
MIRROR="${CURL_MIRROR:-https://curl.se/download}"
CA_URL="${CA_URL:-https://curl.se/ca/cacert.pem}"

BSSL_LIB="$HERE/userland/build/libbearssl.a"
BSSL_INC="$HERE/userland/build/bearssl-inc"
[ -f "$BSSL_LIB" ] && [ -d "$BSSL_INC" ] \
	|| { echo "!! BearSSL not built — run userland/build-bearssl.sh first" >&2; exit 1; }

mkdir -p "$SRC_BASE" "$OUT_DIR"

# --- fetch --------------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
	[ -f "$SRC_BASE/$TARBALL" ] \
		|| curl -fL --retry 3 -o "$SRC_BASE/$TARBALL" "$MIRROR/$TARBALL"
	tar -C "$SRC_BASE" -xf "$SRC_BASE/$TARBALL"
fi
[ -f "$SRC_BASE/cacert.pem" ] \
	|| curl -fL --retry 3 -o "$SRC_BASE/cacert.pem" "$CA_URL"

# --- a prefix-shaped view of the already-built BearSSL --------------------------
# configure wants --with-bearssl=PREFIX with lib/ and include/ inside it.
BSSL_PREFIX="$SRC_BASE/bearssl-prefix"
mkdir -p "$BSSL_PREFIX/lib" "$BSSL_PREFIX/include"
cp "$BSSL_LIB" "$BSSL_PREFIX/lib/"
cp "$BSSL_INC"/*.h "$BSSL_PREFIX/include/"

cd "$SRC_DIR"

# --- configure: static, BearSSL, nothing optional --------------------------------
if [ ! -f lib/curl_config.h ]; then
	echo ">> configure curl $CURL_VER (static, BearSSL, http/https/ftp only)"
	LDFLAGS="-static" CFLAGS="-Os" ./configure \
		--with-bearssl="$BSSL_PREFIX" \
		--with-ca-bundle=/data/apps/curl/etc/ca-bundle.crt \
		--disable-shared --enable-static \
		--without-libpsl --without-zlib --without-brotli --without-zstd \
		--without-nghttp2 --without-libidn2 --without-librtmp \
		--disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
		--disable-telnet --disable-tftp --disable-pop3 --disable-imap \
		--disable-smtp --disable-mqtt --disable-gopher --disable-smb \
		--disable-manual --disable-docs --disable-libcurl-option \
		--disable-ntlm >/dev/null
fi

# libtool quietly drops a plain -static from LDFLAGS on the final link;
# curl_LDFLAGS=-all-static is the supported way to force a static binary.
echo ">> building curl with -j$JOBS"
make -j"$JOBS" curl_LDFLAGS=-all-static >/dev/null

# --- stage the package tree -------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/etc"
cp src/curl "$STAGE/bin/curl"
strip "$STAGE/bin/curl" 2>/dev/null || true
file "$STAGE/bin/curl" | grep -q 'statically linked' \
	|| { echo "!! curl is not static" >&2; exit 1; }
cp "$SRC_BASE/cacert.pem" "$STAGE/etc/ca-bundle.crt"

# --- the manifest ------------------------------------------------------------------
cat > "$STAGE/manifest.yaml" <<EOF
name: curl
version: "$CURL_VER"
links:
  - /usr/bin/curl -> bin/curl
EOF

# --- pack ----------------------------------------------------------------------------
OUT="$OUT_DIR/curl-$CURL_VER.tar.gz"
tar -czf "$OUT" -C "$STAGE" manifest.yaml bin etc
echo ">> done: $OUT"
tar -tzf "$OUT"
