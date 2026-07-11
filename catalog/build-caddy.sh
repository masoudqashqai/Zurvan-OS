#!/bin/sh
# catalog/build-caddy.sh — caddy: a web server / reverse proxy in one Go binary.
#
# The catalog's first Go package — and the kind of package the catalog pack was
# invented for: the binary alone is tens of megabytes, so it ships in the pack
# and never touches the ISO. Go also flips the static story from "hard-won"
# (nginx's ./configure archaeology, curl's -all-static fight) to "free":
#
#   * STATIC BY CONSTRUCTION. CGO_ENABLED=0 forbids C linkage entirely, so the
#     result is one self-contained binary with no loader dependency.
#   * HERMETIC TOOLCHAIN. The build host carries no Go, so this script fetches
#     a pinned toolchain into $SRC_BASE and builds with it. Module downloads
#     and the build cache land under $SRC_BASE too — nothing leaks into $HOME,
#     and GOTOOLCHAIN=local stops Go from quietly downloading a different
#     compiler than the one we pinned.
#   * VERIFIED SOURCES. `go install <module>@v<version>` (instead of unpacking
#     a source tarball) makes Go check every module against its public
#     checksum database, and stamps the real version into the binary — so
#     `caddy version` answers honestly on the box.
#   * WRITABLE PATHS on a read-only root. caddy persists TLS certificates and
#     autosaved config under $HOME by default. The shipped Caddyfile pins
#     storage to /data/srv/caddy (certs survive reboot, the lion snapshots
#     them) and turns the admin API off (no localhost:2019, no autosave — the
#     Caddyfile is the only source of truth, which is very Zurvan).
#   * COEXISTENCE. nginx from the catalog owns :80 and the panel owns :8443,
#     so the default Caddyfile serves :8080 — installing everything at once
#     breaks nothing. That is the catalog promise.
#
# Enable after installing with "- caddy" in services:. The Caddyfile ships
# commented recipes for the two jobs you'd actually give it: a reverse proxy
# in front of an app on the box, and real HTTPS for a public domain.
#
# Output: build/catalog/caddy-<version>.tar.gz
set -eu

CADDY_VER="${CADDY_VER:-2.11.4}"
GO_VER="${GO_VER:-1.25.9}"          # caddy 2.11.4 wants go >= 1.25.1

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/catalog/src}"
OUT_DIR="${OUT_DIR:-$HERE/build/catalog}"
GO_ROOT="$SRC_BASE/go-$GO_VER"

mkdir -p "$SRC_BASE" "$OUT_DIR"

# --- fetch the pinned Go toolchain -------------------------------------------
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

# --- build: CGO off => static; pinned toolchain; caches kept out of $HOME ----
# go install fetches the module (sumdb-verified), builds, and drops the binary
# in GOBIN — no source tree to manage. One wrinkle: caddy's Version() only
# looks for itself in the *dependency* list (the xcaddy build layout), so a
# build where caddy is the main module reports "unknown" — its CustomVersion
# ldflags var exists for exactly this case, so we stamp it ourselves.
echo ">> building caddy $CADDY_VER with go $GO_VER (static, CGO off)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/html"

env PATH="$GO_ROOT/bin:$PATH" \
    CGO_ENABLED=0 GOTOOLCHAIN=local \
    GOPATH="$SRC_BASE/go-path" GOCACHE="$SRC_BASE/go-cache" \
    GOBIN="$STAGE/bin" \
	"$GO_ROOT/bin/go" install -trimpath \
	-ldflags "-s -w -X github.com/caddyserver/caddy/v2.CustomVersion=v$CADDY_VER" \
	"github.com/caddyserver/caddy/v2/cmd/caddy@v$CADDY_VER"

# --- the config: :8080, no admin API, state on /data --------------------------
cat > "$STAGE/Caddyfile" <<'CONF'
# /data/apps/caddy/Caddyfile — edit here, then restart the caddy service.
#
# The default site is :8080 on purpose: nginx from the catalog owns :80 and
# the Zurvan panel owns :8443. Catalog packages must never fight over a port.

{
	# No admin API: nothing listens on localhost:2019, and caddy never
	# autosaves a mutated config — this file is the only source of truth.
	admin off
	# The plain :8080 site below needs no certificates. Remove this line
	# when you give caddy a real domain (recipe at the bottom).
	auto_https off
	# TLS certificates and other caddy state live on /data: they survive
	# reboot and the lion snapshots them.
	storage file_system /data/srv/caddy
}

:8080 {
	root * /data/apps/caddy/html
	file_server
}

# Reverse proxy: put caddy in front of an app running on the box.
#:8080 {
#	reverse_proxy localhost:3000
#}

# Real HTTPS with automatic certificates. Needs a public domain pointing at
# this box, ports 80 + 443 reachable from the internet, and the auto_https
# line above removed.
#example.com {
#	reverse_proxy localhost:3000
#}
CONF

# --- a branded landing page ---------------------------------------------------
cat > "$STAGE/html/index.html" <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>caddy on Zurvan</title><style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;
background:#0f1115;color:#d7dbe0;font:16px/1.6 system-ui,sans-serif}
.card{max-width:560px;margin:24px;padding:32px;background:#161a21;border:1px solid #262c36;border-radius:14px}
h1{margin:0 0 4px;font-size:26px;color:#fff}.dim{color:#8b93a1}code{background:#0b0d11;padding:2px 6px;border-radius:6px}
.b{display:inline-block;margin-top:8px;font-size:13px;color:#5ad18b}</style></head><body>
<div class=card>
<h1>&#127794; caddy is running on Zurvan</h1>
<p class=dim>One static Go binary, installed from the catalog with
<code>zurvan-pkg</code> and supervised by <code>zurvan-svc</code>.</p>
<p>Its config is <code>/data/apps/caddy/Caddyfile</code> — recipes for a
reverse proxy and automatic HTTPS are commented inside. Edit it and restart
the service from the panel.</p>
<span class=b>the snake sheds &middot; the lion remembers</span>
</div></body></html>
HTML

# --- the manifest --------------------------------------------------------------
cat > "$STAGE/manifest.yaml" <<EOF
name: caddy
version: "$CADDY_VER"
links:
  - /usr/bin/caddy -> bin/caddy
service:
  exec: /usr/bin/caddy run --config /data/apps/caddy/Caddyfile --adapter caddyfile
  restart: yes
EOF

# --- pack ----------------------------------------------------------------------
OUT="$OUT_DIR/caddy-$CADDY_VER.tar.gz"
tar -czf "$OUT" -C "$STAGE" manifest.yaml bin html Caddyfile
echo ">> done: $OUT"
tar -tzf "$OUT"
file "$STAGE/bin/caddy" 2>/dev/null || true
"$STAGE/bin/caddy" version || true
