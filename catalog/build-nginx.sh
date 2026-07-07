#!/bin/sh
# catalog/build-nginx.sh — a real-world example package: the nginx web server.
#
# This is what a non-toy catalog entry looks like. The interesting parts are all
# about making a mainstream daemon behave on Zurvan:
#
#   * STATIC, no dependencies. nginx's optional modules pull in external
#     libraries — rewrite needs PCRE, gzip needs zlib, ssl needs OpenSSL — none
#     of which a loader-less image can link. We disable those modules and build
#     one self-contained static binary. (The panel already gives you HTTPS; a
#     plain static file server is the honest minimal example.)
#   * WRITABLE PATHS on a read-only root. Everything nginx writes at runtime is
#     compiled to point at /run (tmpfs): pid, lock, and the request temp dirs.
#     Its logs go to stdout/stderr, so the supervisor captures them — the
#     Zurvan-native place for a service's output.
#   * SELF-CONTAINED PREFIX. The package unpacks into /data/apps/nginx/, which
#     lives on the writable /data, so the binary, nginx.conf, and the web root
#     all ship together and nginx reads them from there.
#
# Enable it after installing by adding "- nginx" to services: in the YAML; it
# serves /data/apps/nginx/html on port 80.
#
# Output: build/catalog/nginx-<version>.tar.gz
set -eu

NGINX_VER="${NGINX_VER:-1.26.2}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC_BASE="${ZURVAN_SRC_BASE:-$HERE/catalog/src}"
SRC_DIR="$SRC_BASE/nginx-$NGINX_VER"
OUT_DIR="${OUT_DIR:-$HERE/build/catalog}"
TARBALL="nginx-$NGINX_VER.tar.gz"
MIRROR="${NGINX_MIRROR:-https://nginx.org/download}"

mkdir -p "$SRC_BASE" "$OUT_DIR"

# --- fetch ------------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
	[ -f "$SRC_BASE/$TARBALL" ] \
		|| curl -fL --retry 3 -o "$SRC_BASE/$TARBALL" "$MIRROR/$TARBALL"
	tar -C "$SRC_BASE" -xf "$SRC_BASE/$TARBALL"
fi

cd "$SRC_DIR"

# --- configure: static, dependency-free, /run for writable state -----------
if [ ! -f objs/Makefile ]; then
	echo ">> configure nginx $NGINX_VER (static, no PCRE/zlib/openssl)"
	./configure \
		--prefix=/data/apps/nginx \
		--sbin-path=/data/apps/nginx/bin/nginx \
		--conf-path=/data/apps/nginx/conf/nginx.conf \
		--error-log-path=stderr \
		--http-log-path=/dev/stdout \
		--pid-path=/run/nginx.pid \
		--lock-path=/run/nginx.lock \
		--http-client-body-temp-path=/run/nginx_client \
		--http-proxy-temp-path=/run/nginx_proxy \
		--http-fastcgi-temp-path=/run/nginx_fastcgi \
		--http-uwsgi-temp-path=/run/nginx_uwsgi \
		--http-scgi-temp-path=/run/nginx_scgi \
		--without-http_rewrite_module \
		--without-http_gzip_module \
		--with-cc-opt="-O2" \
		--with-ld-opt="-static" >/dev/null
fi

echo ">> building nginx with -j$JOBS"
make -j"$JOBS" >/dev/null

# --- stage the package tree -------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/conf" "$STAGE/html"
cp objs/nginx "$STAGE/bin/nginx"
strip "$STAGE/bin/nginx" 2>/dev/null || true

# --- the config: foreground (supervised), logs to the supervisor ------------
# daemon off keeps nginx in the foreground for zurvan-svc. A minimal mime map
# is inlined so we don't have to ship mime.types. user root avoids needing a
# dedicated worker user (production would add one via the service user: field).
cat > "$STAGE/conf/nginx.conf" <<'CONF'
daemon off;
worker_processes 1;
user root;
events { worker_connections 256; }
http {
    types {
        text/html    html htm;
        text/css     css;
        text/plain   txt;
        application/javascript js;
        image/png    png;
        image/jpeg   jpg jpeg;
        image/svg+xml svg;
        image/x-icon ico;
    }
    default_type application/octet-stream;
    sendfile on;
    server {
        listen 80 default_server;
        server_name _;
        root /data/apps/nginx/html;
        location / { index index.html; }
    }
}
CONF

# --- a branded landing page -------------------------------------------------
cat > "$STAGE/html/index.html" <<'HTML'
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>nginx on Zurvan</title><style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;
background:#0f1115;color:#d7dbe0;font:16px/1.6 system-ui,sans-serif}
.card{max-width:560px;margin:24px;padding:32px;background:#161a21;border:1px solid #262c36;border-radius:14px}
h1{margin:0 0 4px;font-size:26px;color:#fff}.dim{color:#8b93a1}code{background:#0b0d11;padding:2px 6px;border-radius:6px}
.b{display:inline-block;margin-top:8px;font-size:13px;color:#5ad18b}</style></head><body>
<div class=card>
<h1>&#129443; nginx is running on Zurvan</h1>
<p class=dim>A static, dependency-free nginx, installed from the catalog with
<code>zurvan-pkg</code> and supervised by <code>zurvan-svc</code>.</p>
<p>Its files live under <code>/data/apps/nginx</code>; edit
<code>conf/nginx.conf</code> or drop files in <code>html/</code> and restart the
service from the panel.</p>
<span class=b>the snake sheds &middot; the lion remembers</span>
</div></body></html>
HTML

# --- the manifest -----------------------------------------------------------
cat > "$STAGE/manifest.yaml" <<EOF
name: nginx
version: "$NGINX_VER"
links:
  - /usr/sbin/nginx -> bin/nginx
service:
  exec: /usr/sbin/nginx
  restart: yes
EOF

# --- pack -------------------------------------------------------------------
OUT="$OUT_DIR/nginx-$NGINX_VER.tar.gz"
tar -czf "$OUT" -C "$STAGE" manifest.yaml bin conf html
echo ">> done: $OUT"
tar -tzf "$OUT"
file "$STAGE/bin/nginx" 2>/dev/null || true
