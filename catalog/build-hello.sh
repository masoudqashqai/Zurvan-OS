#!/bin/sh
# catalog/build-hello.sh — the first (and simplest possible) catalog entry.
#
# `hello` exists to prove the package pipeline end to end: a static binary,
# a manifest with both link kinds, and persistent state in /data/srv/hello.
# Each run prints a greeting and bumps a counter in /var/lib/hello/count —
# which the set-dresser points at /data/srv/hello, so the count survives
# reboots while the OS itself is reborn. The package IS the demo.
#
# Output: build/catalog/hello-1.0.tar.gz
# This is the catalog contribution model: one build-<name>.sh per package,
# fetching/compiling STATIC binaries and tarring them up with a manifest.
set -eu

VERSION=1.0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/build/catalog}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT_DIR" "$STAGE/bin"

# --- the program ---------------------------------------------------------------
cat > "$STAGE/hello.c" <<'EOF'
/* hello — Zurvan's smallest package. Persistent state or it didn't happen. */
#include <stdio.h>

int main(void)
{
    long n = 0;
    FILE *f = fopen("/var/lib/hello/count", "r");
    if (f) { if (fscanf(f, "%ld", &n) != 1) n = 0; fclose(f); }
    n++;

    printf("Hello from Zurvan! This box has said hello %ld time%s.\n",
           n, n == 1 ? "" : "s");

    f = fopen("/var/lib/hello/count", "w");
    if (!f) { perror("hello: /var/lib/hello/count"); return 1; }
    fprintf(f, "%ld\n", n);
    fclose(f);
    return 0;
}
EOF
cc -static -O2 -o "$STAGE/bin/hello" "$STAGE/hello.c"
rm "$STAGE/hello.c"

# --- the manifest ----------------------------------------------------------------
cat > "$STAGE/manifest.yaml" <<EOF
name: hello
version: "$VERSION"
links:
  - /usr/bin/hello -> bin/hello
state_links:
  - /var/lib/hello -> .
EOF

# --- pack --------------------------------------------------------------------------
TARBALL="$OUT_DIR/hello-$VERSION.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" manifest.yaml bin
echo ">> done: $TARBALL"
tar -tzf "$TARBALL"
