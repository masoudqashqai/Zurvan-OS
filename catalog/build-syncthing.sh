#!/bin/sh
# catalog/build-syncthing.sh — syncthing: continuous file sync between machines.
#
# The second Go package, built on the pattern build-caddy.sh established
# (pinned toolchain into $SRC_BASE, `go install module@version`, static by
# CGO_ENABLED=0 — syncthing 2.x carries a pure-Go sqlite exactly for this).
# The Zurvan-specific decisions:
#
#   * NO SELF-UPGRADE, compiled out. syncthing ships its own auto-upgrader;
#     on Zurvan a package never mutates itself — new versions arrive through
#     the catalog, verified, like everything else. The `noupgrade` build tag
#     removes the machinery instead of asking it nicely.
#   * NO SELF-RESTART. `--no-restart` makes syncthing exit when it wants a
#     restart (config changes ask for one) and zurvan-svc brings it back —
#     one restart story, owned by the supervisor.
#   * STATE ON /data. `--home=/data/srv/syncthing` puts keys, config, and the
#     index database where they survive reboot and the lion snapshots them.
#     Create your sync folders under /data too — a path outside /data lives
#     on the RAM root and evaporates at reboot.
#   * GUI ON LOOPBACK, deliberately. The admin GUI starts with no password,
#     so it binds 127.0.0.1:8384 (syncthing's own default) rather than the
#     network. Reach it with `ssh -L 8384:127.0.0.1:8384 root@box`, or set a
#     GUI user+password and change the address in the GUI — it persists in
#     /data/srv/syncthing/config.xml. Key-only SSH guards the tunnel path,
#     which is the same posture the seal gave everything else. (The sync
#     protocol itself listens on :22000 regardless — syncing needs no GUI.)
#
# Enable after installing with "- syncthing" in services:.
#
# Output: build/catalog/syncthing-<version>.tar.gz
set -eu

SYNCTHING_VER="${SYNCTHING_VER:-2.1.2}"
GO_VER="${GO_VER:-1.25.9}"          # syncthing 2.1.2 wants go >= 1.25.0

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/catalog/src}"
SRC_DIR="$SRC_BASE/syncthing-$SYNCTHING_VER"
OUT_DIR="${OUT_DIR:-$HERE/build/catalog}"
GO_ROOT="$SRC_BASE/go-$GO_VER"

mkdir -p "$SRC_BASE" "$OUT_DIR"

# --- fetch the pinned Go toolchain (shared with build-caddy.sh) ---------------
if [ ! -x "$GO_ROOT/bin/go" ]; then
	echo ">> fetch go $GO_VER"
	[ -f "$SRC_BASE/go$GO_VER.tar.gz" ] \
		|| curl -fL --retry 3 -o "$SRC_BASE/go$GO_VER.tar.gz" \
			"https://go.dev/dl/go$GO_VER.linux-amd64.tar.gz"
	rm -rf "$SRC_BASE/go.tmp" "$GO_ROOT"
	mkdir "$SRC_BASE/go.tmp"
	tar -C "$SRC_BASE/go.tmp" -xzf "$SRC_BASE/go$GO_VER.tar.gz"
	mv "$SRC_BASE/go.tmp/go" "$GO_ROOT"
	rmdir "$SRC_BASE/go.tmp"
fi

# --- fetch the release source ---------------------------------------------------
# NOT `go install module@version` like caddy: syncthing 2.x kept its module
# path without the /v2 suffix Go's semantic-import-versioning demands, so
# `go install ...@v2.x` is refused outright. Upstream builds from a source
# tree (their build.go); we do the same, minus their wrapper. Dependencies
# still verify against the tree's go.sum on download.
TARBALL="syncthing-src-$SYNCTHING_VER.tar.gz"
if [ ! -d "$SRC_DIR" ]; then
	[ -f "$SRC_BASE/$TARBALL" ] \
		|| curl -fL --retry 3 -o "$SRC_BASE/$TARBALL" \
			"https://github.com/syncthing/syncthing/archive/refs/tags/v$SYNCTHING_VER.tar.gz"
	tar -C "$SRC_BASE" -xzf "$SRC_BASE/$TARBALL"
fi

# --- generate the embedded GUI ---------------------------------------------------
# The web GUI is compiled in as a generated Go file (lib/api/auto/gui.files.go)
# that a tag tarball doesn't carry — without it the build stops at
# "undefined: auto.Assets". Upstream's build.go runs exactly this `go
# generate`; SOURCE_DATE_EPOCH pins the timestamp it bakes in, so the
# package doesn't change just because it was rebuilt.
if [ ! -f "$SRC_DIR/lib/api/auto/gui.files.go" ]; then
	echo ">> generating embedded GUI assets"
	(cd "$SRC_DIR" && \
		env PATH="$GO_ROOT/bin:$PATH" \
		    GOTOOLCHAIN=local SOURCE_DATE_EPOCH=0 \
		    GOPATH="$SRC_BASE/go-path" GOCACHE="$SRC_BASE/go-cache" \
		"$GO_ROOT/bin/go" generate github.com/syncthing/syncthing/lib/api/auto)
fi

# --- build: CGO off => static + pure-Go sqlite --------------------------------
# syncthing's version is normally injected by its own build.go; building the
# tree directly we stamp lib/build.Version ourselves or the binary says
# "unknown-dev" (same story as caddy's CustomVersion).
echo ">> building syncthing $SYNCTHING_VER with go $GO_VER (static, CGO off, noupgrade)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin"

(cd "$SRC_DIR" && \
	env PATH="$GO_ROOT/bin:$PATH" \
	    CGO_ENABLED=0 GOTOOLCHAIN=local \
	    GOPATH="$SRC_BASE/go-path" GOCACHE="$SRC_BASE/go-cache" \
	"$GO_ROOT/bin/go" build -trimpath -tags noupgrade \
	-ldflags "-s -w -X github.com/syncthing/syncthing/lib/build.Version=v$SYNCTHING_VER" \
	-o "$STAGE/bin/syncthing" ./cmd/syncthing)

# --- the manifest --------------------------------------------------------------
cat > "$STAGE/manifest.yaml" <<EOF
name: syncthing
version: "$SYNCTHING_VER"
links:
  - /usr/bin/syncthing -> bin/syncthing
service:
  exec: /usr/bin/syncthing serve --home=/data/srv/syncthing --no-browser --no-restart
  after:
    - networking
  restart: yes
EOF

# --- pack ----------------------------------------------------------------------
OUT="$OUT_DIR/syncthing-$SYNCTHING_VER.tar.gz"
tar -czf "$OUT" -C "$STAGE" manifest.yaml bin
echo ">> done: $OUT"
tar -tzf "$OUT"
file "$STAGE/bin/syncthing" 2>/dev/null || true
"$STAGE/bin/syncthing" --version || true
