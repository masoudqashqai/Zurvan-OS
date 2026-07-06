# The Zurvan package catalog

Zurvan's promise is not "runs any Linux software" — it is **"everything in the
catalog works perfectly and cannot break each other."** A package is a gzipped
tarball of *statically linked* binaries plus one `manifest.yaml`; no dynamic
loader ships in the image, so a package carries everything it needs inside
itself. One file, zero shared-library dependencies, no version conflicts
possible.

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
