#!/bin/sh
# Build a static gpgv for the Zurvan image (v2 M3, "the seal").
#
# gpgv is the minimal GPG signature verifier — no keyring management, no agent,
# no network: it checks a detached signature against a key file and exits. That
# is exactly what zurvan-upgrade needs to reject an unsigned/wrong-key bundle
# BEFORE writing it to a slot, and it verifies the SAME .sig files GRUB checks
# at boot, so there is one signature format and one trust story.
#
# We build it from GnuPG 1.4 on purpose. Modern gnupg 2.x drags in five
# separate libraries (libgpg-error, libgcrypt, libassuan, libksba, npth) even
# for a gpgv-only build — a static-linking rabbit hole. GnuPG 1.4 is a single
# self-contained tarball with its crypto built in, links static cleanly, and
# its gpgv verifies RSA/SHA-256/SHA-512 detached signatures made by gpg 2.x.
#
# Output: userland/build/gpgv  (single static binary)
set -eu

GNUPG_VER="${GNUPG_VER:-1.4.23}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/src}"
SRC_DIR="$SRC_BASE/gnupg-$GNUPG_VER"
OUT_DIR="$HERE/build"
TARBALL="gnupg-$GNUPG_VER.tar.bz2"
MIRROR="${GNUPG_MIRROR:-https://gnupg.org/ftp/gcrypt}"
URL="$MIRROR/gnupg/$TARBALL"

mkdir -p "$SRC_BASE" "$OUT_DIR"

# --- fetch ------------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
	[ -f "$SRC_BASE/$TARBALL" ] \
		|| curl -fL --retry 3 -o "$SRC_BASE/$TARBALL" "$URL"
	tar -C "$SRC_BASE" -xf "$SRC_BASE/$TARBALL"
fi

cd "$SRC_DIR"

# --- configure (static, verifier only) --------------------------------------
# We only need gpgv, so drop everything optional. LDFLAGS=-static makes the
# binary self-contained for the loader-less image.
if [ ! -f config.status ]; then
	echo ">> configure gnupg $GNUPG_VER (static)"
	./configure \
		--enable-static-rnd=linux \
		--disable-nls \
		--disable-card-support \
		--disable-gnupg-iconv \
		--disable-ldap \
		--disable-photo-viewers \
		--disable-exec \
		CFLAGS="-O2 -std=gnu17 -fcommon" LDFLAGS="-static" >/dev/null
		# -fcommon: 1.4.23 relies on common tentative definitions that GCC 10+
		# rejects by default (multiple-definition link errors otherwise).
fi

# --- build just the verifier ------------------------------------------------
echo ">> building gpgv with -j$JOBS"
# util/ and other libs first, then the g10 dir's gpgv target.
make -j"$JOBS" >/dev/null 2>&1 || true   # full build may trip on optional bits
make -C g10 gpgv >/dev/null

cp -f g10/gpgv "$OUT_DIR/gpgv"
echo ">> done: $OUT_DIR/gpgv"
file "$OUT_DIR/gpgv" 2>/dev/null || true
