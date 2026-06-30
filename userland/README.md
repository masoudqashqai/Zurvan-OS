# userland/

The userspace tools, built **statically** so the rootfs needs no dynamic loader or
shared libraries.

## Two pieces

1. **busybox** — one statically-linked binary that provides `sh`, `ls`, `mount`, `ip`,
   `udhcpc`, `vi`, and dozens more as applets (symlinks to the one binary). This is the
   backbone of the rootfs.
2. **bash** — built on top of busybox. An **explicit requirement**: the system should
   have real bash, not only busybox's `ash`-derived `sh`. Built static too, to avoid
   shipping libc.

## Build

```sh
userland/build-busybox.sh   # -> userland/build/busybox (static)
userland/build-bash.sh      # -> userland/build/bash    (static)
```

`scripts/build.sh` copies both into the rootfs and creates the busybox applet symlinks.

## busybox config

`build-busybox.sh` starts from `make defconfig` and forces `CONFIG_STATIC=y`. If you want
a curated applet list, drop a saved `.config` next to the script as `busybox.config` and
the build will use it instead of defconfig. Keep `udhcpc`, `ip`, `mount`, `vi`, and `sh`
enabled — the boot path and networking depend on them.

## Notes

- Static linking needs static libc archives present (e.g. `glibc-static`, or build
  against musl). If static bash fights with glibc, musl is the path of least resistance.
- These are the "boilerplate" layers — fine to lean on generated configs and iterate.
