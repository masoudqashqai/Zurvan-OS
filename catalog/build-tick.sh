#!/bin/sh
# catalog/build-tick.sh — a daemon-shaped package for the supervisor era.
#
# `tick` appends a timestamp to /var/lib/tick/log every 5 seconds, forever.
# It exists to prove the milestone-2 pipeline: a package whose manifest carries
# a service: block, enabled with one line in the YAML, started by zurvan-svc,
# restarted when it dies — with its log surviving reboots in /data/srv/tick.
#
# Output: build/catalog/tick-1.0.tar.gz
set -eu

VERSION=1.0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/build/catalog}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT_DIR" "$STAGE/bin"

# --- the program ---------------------------------------------------------------
cat > "$STAGE/tick.c" <<'EOF'
/* tick — a supervised heartbeat. Runs in the FOREGROUND (supervised services
 * must never daemonize themselves) and writes proof-of-life every 5 seconds. */
#include <stdio.h>
#include <time.h>
#include <unistd.h>

int main(void)
{
    for (;;) {
        FILE *f = fopen("/var/lib/tick/log", "a");
        if (f) {
            fprintf(f, "tick %lld pid %d\n",
                    (long long)time(NULL), (int)getpid());
            fclose(f);
        }
        sleep(5);
    }
}
EOF
cc -static -O2 -o "$STAGE/bin/tick" "$STAGE/tick.c"
rm "$STAGE/tick.c"

# --- the manifest ----------------------------------------------------------------
cat > "$STAGE/manifest.yaml" <<EOF
name: tick
version: "$VERSION"
links:
  - /usr/bin/tick -> bin/tick
state_links:
  - /var/lib/tick -> .
service:
  exec: /usr/bin/tick
  restart: yes
EOF

# --- pack --------------------------------------------------------------------------
TARBALL="$OUT_DIR/tick-$VERSION.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" manifest.yaml bin
echo ">> done: $TARBALL"
tar -tzf "$TARBALL"
