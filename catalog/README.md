# The Zurvan package catalog

## Two words, two meanings

- A **package** is one installable thing: a gzipped tarball of *statically
  linked* binaries plus one `manifest.yaml`. `nginx` is a package.
- The **catalog** is the curated set of every package Zurvan offers. It is a
  collective noun. There is exactly one of it. `nginx` is *in* the catalog; it
  is not "a catalog."

The word is "catalog" and not "repository" on purpose. A repository implies
anything may be uploaded to it. A catalog implies somebody chose these, and
stands behind the choice — which is the actual promise:

> Zurvan's promise is not "runs any Linux software" — it is **"everything in
> the catalog works perfectly and cannot break each other."**

No dynamic loader ships in the image, so a package carries everything it needs
inside itself. One file, zero shared-library dependencies, no version conflicts
possible.

## What's in it

The ISO is a boot-and-install medium, not a software repository, so it carries
only a small **on-ISO tier** — the packages a disconnected box needs to be
useful on the day you install it. `zurvan-install` copies that tier to `/data`.
Everything else lives in the **catalog pack**, a separate download.

This is what keeps a growing catalog from growing the ISO: a new package goes
in the pack unless it earns a line in [`on-iso.txt`](on-iso.txt).

| Package | On the ISO | What it is | Notes |
|---------|:---:|-----------|-------|
| `nginx`  | ✅ | Web server | Static, no PCRE/zlib/OpenSSL; a service (`- nginx` in `services:`). Serves `/data/apps/nginx/html` on :80. |
| `sqlite3` | ✅ | The embedded SQL database | One static shell binary; a database is one file — put it under `/data/srv`. FTS5 + R-Tree on; loadable extensions off (no loader to load them). |
| `curl`   | ✅ | TLS-capable HTTP/FTP client | TLS is **BearSSL**, the same stack the panel uses — no OpenSSL enters the image. Ships Mozilla's CA bundle at `/data/apps/curl/etc/`. |
| `tick`   | ✅ | A heartbeat daemon | Demo service for the supervisor — logs to `/data/srv/tick` on a timer. Also the fixture `tests/m3-seal.sh` installs. |
| `caddy`  | — | Web server / reverse proxy | The catalog's first Go package — static by construction (CGO off), and at ~40 MB exactly what the pack tier is for. Serves :8080 by default (nginx keeps :80); the Caddyfile ships reverse-proxy and auto-HTTPS recipes; caddy state lives in `/data/srv/caddy`. |
| `syncthing` | — | Continuous file sync between machines | Static Go (pure-Go sqlite), self-upgrade compiled out — new versions come from the catalog. State in `/data/srv/syncthing`; **create sync folders under `/data`** (anywhere else evaporates at reboot). GUI on loopback :8384 — tunnel in with `ssh -L 8384:127.0.0.1:8384 root@box`, or set a GUI password and change the address (persists in config.xml). Sync protocol on :22000. |
| `hello`  | — | The smallest possible package | Proves the pipeline: a link, a state link, a counter that survives reboot. |
| `zurvanos` | — | An animated banner, and nothing else | A cheerful demo for exercising the panel's upload + install flow. |

## The catalog pack

```sh
make catalog-pack     # -> build/zurvan-catalog-<DATE>.tar.gz (+ .sig, .sha256)
```

Published as its own date-stamped release (tag `catalog-<DATE>`) on the
[releases page](https://github.com/masoudqashqai/Zurvan-OS/releases) — the
catalog has its own cadence, and an OS version only ever means the image
changed. Packages are static binaries with no OS coupling, so any pack runs on
any v2.x image. The pack holds **every** package, including the four already
on the ISO — one artifact, so you never have to work out which half you have.

The pack is signed with the same key that signs the kernel and initrd, so you
can verify it in either place. On your own machine:

```sh
gpg --verify zurvan-catalog-2026.07.12.tar.gz.sig zurvan-catalog-2026.07.12.tar.gz
sha256sum -c zurvan-catalog-2026.07.12.tar.gz.sha256
```

Or on the box itself — every Zurvan image carries `gpgv` and the trust anchor
at `/etc/zurvan-signing.pub`, which is the same check `zurvan-upgrade` runs on
an image before it will touch a disk:

```sh
gpgv --keyring /etc/zurvan-signing.pub zurvan-catalog-2026.07.12.tar.gz.sig \
                                       zurvan-catalog-2026.07.12.tar.gz
```

Then get packages onto the box. The fast path: **upload the pack itself** on
the panel's **Packages** page — every package inside is staged onto `/data`
with its `.sig`, ready to install. Or move packages one at a time, the way
you'd move any other file: the same upload button takes a tarball and its
`.sig` together (multi-select), and `scp` to `/data` works as it always did.
**Keep each package's `.sig` beside it** (the pack ships one per tarball):
`zurvan-pkg install` verifies it with that same `gpgv` + trust anchor *before
unpacking*, and refuses a package with a missing or bad signature. The panel
does the same — a tarball on `/data` without its `.sig` only offers an
explicit, confirmed **Install unsigned** button, mirroring the CLI escape
hatch for packages you built yourself:

```sh
zurvan-pkg install --unsigned my-own-thing.tar.gz
```

**There is deliberately no `zurvan-pkg install <url>`.** Nothing on the box
fetches software over the network. That would mean TLS, a repository server,
and trusting the network during install — precisely the trust the seal
milestone exists to avoid. Downloading on your machine and uploading to the box
costs one extra step and keeps the install path offline.

## Building

Each `build-<name>.sh` here fetches/compiles its program (in the same style as
`userland/build-*.sh`) and packs `build/catalog/<name>-<version>.tar.gz`:

```sh
make catalog          # build every package
catalog/build-hello.sh   # or just one
```

## Installing (on a running Zurvan with a /data disk)

```sh
zurvan-pkg install hello-1.0.tar.gz   # unpack + plant links, usable immediately
zurvan-pkg list
zurvan-pkg remove hello               # keeps /data/srv/hello (your state)
```

The app lands in `/data/apps/<name>/`, its persistent state in
`/data/srv/<name>/`, and the standard paths (`/usr/bin/...`, `/var/lib/...`)
are symlinks into those — rebuilt from the manifests on every boot by
`zurvan-pkg dress`, so they can never rot.

## Manifest reference

```yaml
name: hello            # required; also the /data/apps + /data/srv dir name
version: "1.0"
needs:                 # optional: packages that must already be installed.
  - openssl            # names only — no versions, no graphs, ON PURPOSE.
links:                 # /abs/path -> path inside /data/apps/<name>/
  - /usr/bin/hello -> bin/hello
state_links:           # /abs/path -> path inside /data/srv/<name>/
  - /var/lib/hello -> .
```

## Contributing a package

Write one `build-<name>.sh`. Rules:

1. Static binaries only. `file` must say `statically linked` or it's not a package.
2. Runtime junk (pids, sockets, tmp) stays on the RAM root — don't link it into `/data`.
3. State the program would cry about losing goes under `state_links:` → `/data/srv/<name>`.
4. If the build script gets clever, it's wrong.
5. **Your package goes in the pack, not on the ISO.** Adding a line to
   `on-iso.txt` needs a reason a disconnected box couldn't live without it.
   "It's useful" is not that reason — everything here is useful.
