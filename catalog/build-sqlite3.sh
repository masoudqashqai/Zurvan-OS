#!/bin/sh
# catalog/build-sqlite3.sh — the database that matches the philosophy.
#
# SQLite is what a Zurvan package wants to be when it grows up: the whole
# engine is one C file (the amalgamation), the whole database is one file on
# disk. Compiled here into one static shell binary; point it at a file under
# /data and the state story is done — the lion snapshots it like anything else.
#
#   * SQLITE_OMIT_LOAD_EXTENSION is not an optimization: there is no dynamic
#     loader in the image, so .load could never work — omitting it removes the
#     only dlopen() in the tree and keeps the binary honestly static.
#   * No readline on the box; the shell falls back to plain stdin, which works
#     fine on the console and over ssh.
#
# Output: build/catalog/sqlite3-<version>.tar.gz
set -eu

SQLITE_VER="${SQLITE_VER:-3.46.1}"
# sqlite.org paths use a release year + a 7-digit version (3.46.1 -> 3460100)
SQLITE_YEAR="${SQLITE_YEAR:-2024}"
SQLITE_NUM="${SQLITE_NUM:-3460100}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/catalog/src}"
SRC_DIR="$SRC_BASE/sqlite-autoconf-$SQLITE_NUM"
OUT_DIR="${OUT_DIR:-$HERE/build/catalog}"
TARBALL="sqlite-autoconf-$SQLITE_NUM.tar.gz"
MIRROR="${SQLITE_MIRROR:-https://sqlite.org/$SQLITE_YEAR}"

mkdir -p "$SRC_BASE" "$OUT_DIR"

# --- fetch ------------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
	[ -f "$SRC_BASE/$TARBALL" ] \
		|| curl -fL --retry 3 -o "$SRC_BASE/$TARBALL" "$MIRROR/$TARBALL"
	tar -C "$SRC_BASE" -xf "$SRC_BASE/$TARBALL"
fi

# --- build: one cc invocation, no configure ----------------------------------
# The amalgamation needs no build system — which is the whole point of it.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin"

echo ">> building sqlite3 $SQLITE_VER (static, no loadable extensions)"
cc -static -Os -o "$STAGE/bin/sqlite3" \
	"$SRC_DIR/shell.c" "$SRC_DIR/sqlite3.c" \
	-DSQLITE_THREADSAFE=0 \
	-DSQLITE_OMIT_LOAD_EXTENSION \
	-DSQLITE_ENABLE_FTS5 \
	-DSQLITE_ENABLE_RTREE \
	-DSQLITE_ENABLE_MATH_FUNCTIONS \
	-DHAVE_READLINE=0 -DHAVE_EDITLINE=0 \
	-lm
strip "$STAGE/bin/sqlite3" 2>/dev/null || true
file "$STAGE/bin/sqlite3" | grep -q 'statically linked' \
	|| { echo "!! sqlite3 is not static" >&2; exit 1; }

# --- the manifest -------------------------------------------------------------
# A CLI tool, not a daemon: links only, no service block. Databases belong on
# /data (e.g. /data/srv/<yourapp>/app.db) so they persist and get snapshotted.
cat > "$STAGE/manifest.yaml" <<EOF
name: sqlite3
version: "$SQLITE_VER"
links:
  - /usr/bin/sqlite3 -> bin/sqlite3
EOF

# --- pack ---------------------------------------------------------------------
OUT="$OUT_DIR/sqlite3-$SQLITE_VER.tar.gz"
tar -czf "$OUT" -C "$STAGE" manifest.yaml bin
echo ">> done: $OUT"
tar -tzf "$OUT"
