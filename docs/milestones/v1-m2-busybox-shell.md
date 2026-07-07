---
id: v1-m2
version: v1
milestone: 2
title: "Static busybox rootfs + throwaway shell /init — boot to a prompt"
status: done
completed: 2026-07-02
commits: [bdcca3f, 186098f, 4c5ac94]
key_files: [userland/build-busybox.sh, scripts/build.sh, Makefile]
verification: "QEMU boots the initramfs to an interactive busybox sh prompt"
---

## Goal
First userspace: a statically linked busybox providing the whole classic
toolset (`sh`, `ls`, `ip`, `udhcpc`, `vi`, `mount`, …) packed into a cpio.gz
initramfs with a trivial shell-script `/init`, booted with `-kernel -initrd`.
Proves the rootfs assembly pipeline end to end before any C code exists.

## Done-when
Boot lands at a busybox shell prompt; basic commands work.

## Design decisions
- **Static everything, forever.** No dynamic loader ships in Zurvan at all —
  this removes shared-library versioning as a problem class and later becomes
  the foundation of the v2 package system ("packages are static or they are
  not packages"). Busybox is built `CONFIG_STATIC=y`.
- **initramfs (cpio.gz), not a disk image.** The whole OS runs from RAM;
  the disk is never touched. This is the project's core thesis (later named
  "the snake").
- **A throwaway `/init` shell script first, C PID 1 later** (M3). The script
  mode survives as `USE_C_INIT=0` for debugging.
- Rootfs assembly lives in `scripts/build.sh`: stage a directory tree, then
  `find . | cpio -o -H newc | gzip > build/rootfs.cpio.gz`.

## How it was built
1. `userland/build-busybox.sh`: fetch busybox source, `make defconfig`,
   force static, build, `make install` into a staging dir consumed by
   `scripts/build.sh`.
2. `scripts/build.sh`: assemble `build/rootfs/` (busybox install + `rootfs/`
   skeleton overlay: `/etc`, `rc.init`, udhcpc hook), pack the cpio.
3. `make userland && make rootfs && make run`.

## Key files
| path | role |
|---|---|
| `userland/build-busybox.sh` | static busybox build |
| `scripts/build.sh` | rootfs staging + cpio.gz packing (grew every later milestone) |
| `rootfs/` | the skeleton /etc overlaid onto the staging tree |

## Problems hit
- **CRLF line endings silently broke every script in the image.** Windows git
  with `core.autocrlf=true` materialized shell scripts with CRLF; inside the
  booted rootfs the shebang line `#!/bin/sh\r` fails enigmatically. Fix
  (commit 186098f): `.gitattributes` forces LF for all text files regardless
  of local autocrlf. **Any future file that enters the image must be LF.**
- **busybox `tc` applet doesn't compile against kernel headers ≥ 6.8**: the
  CBQ qdisc definitions it uses were removed from the uapi headers. Fix:
  disable the `tc` applet (commit 4c5ac94) — Zurvan doesn't need traffic
  shaping.

## Verification
Interactive busybox prompt in QEMU `-nographic`; `ls /proc` etc. work
(proc mounted by the init script).

## Deferred / rabbit holes avoided
No attempt to trim busybox applets to a minimal set — defconfig's full applet
list is small anyway and the completeness is useful in a rescue-shell sense.
