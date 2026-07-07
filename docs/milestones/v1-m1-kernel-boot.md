---
id: v1-m1
version: v1
milestone: 1
title: "Kernel boots to a panic — config + serial console proven"
status: done
completed: 2026-07-02
commits: [bdcca3f, 9427def]
key_files: [kernel/build.sh, kernel/config-fragment, Makefile]
verification: "QEMU -kernel boot reaches the expected 'No working init found' panic on the serial console"
---

## Goal
Build Linux 6.6 LTS from source and boot it in QEMU with **no userspace at all**.
The expected kernel panic ("Kernel panic — not syncing: No working init found")
is the success signal: it proves the kernel config, the bzImage build, and the
serial console all work before any rootfs exists. Bottom-up layer confirmation
is the project's method — every later milestone assumes this kernel.

## Done-when
`qemu-system-x86_64 -kernel bzImage -nographic` prints boot messages over
serial and panics for lack of an init.

## Design decisions
- **defconfig + a readable fragment, not a hand-rolled config.** `make defconfig`
  gives a sane x86_64 baseline; `kernel/config-fragment` holds *only* the symbols
  the Zurvan boot path depends on, each with a comment. Merged via the kernel's
  own `scripts/kconfig/merge_config.sh -m`, then `make olddefconfig`. Rationale:
  a full config is unreviewable; a fragment is the documentation.
- **6.6 LTS** for longevity; version pinned but overridable (`KVER`).
- **Everything built in, no modules** (finalized in v2 M3, but the no-initrd-tooling
  simplicity started here): an initramfs system can't load modules before mounting
  anything anyway.
- The v1 fragment symbols: `BLK_DEV_INITRD` (unpack cpio.gz, run /init),
  `SERIAL_8250 + SERIAL_8250_CONSOLE` (qemu -nographic / console=ttyS0),
  `DEVTMPFS(+MOUNT)` (kernel populates /dev), `PCI/VIRTIO/VIRTIO_PCI/VIRTIO_NET`
  (QEMU networking), `TMPFS/PROC_FS/SYSFS`, `BINFMT_ELF`, `OVERLAY_FS` (stretch,
  enabled early because it costs nothing).

## How it was built
1. `kernel/build.sh`: download `linux-$KVER.tar.xz` from `$KMIRROR/v6.x/`,
   extract under `$ZURVAN_SRC_BASE` (NOT the repo — see problems), then:
   `make defconfig` → stage fragment at a space-free temp path → 
   `scripts/kconfig/merge_config.sh -m .config $FRAG` → `make olddefconfig` →
   `make -j$(nproc) bzImage` → copy to `kernel/build/bzImage`.
2. Top-level: `make kernel` (~30 min first build).
3. Boot check: `scripts/run-qemu.sh` (later; initially a bare qemu -kernel call).

## Key files
| path | role |
|---|---|
| `kernel/build.sh` | fetch + configure + build; all knobs are env vars |
| `kernel/config-fragment` | the commented symbol list; grew in v2 M1 (disk stack) and v2 M3 (hardening) |

## Problems hit
- **kernel.org CDN served 404s for old point releases** (they prune them):
  default bumped 6.6.30 → 6.6.143, and `KMIRROR` added to switch the download
  base (verified against `https://mirrors.tuna.tsinghua.edu.cn/kernel`).
- **WSL2 + Windows mount = ~10x slower compiles.** The repo lives on `/mnt/i`
  (drvfs); building there is painfully slow. Fix: `ZURVAN_SRC_BASE` redirects
  source/build trees to native ext4 (e.g. `/root/zurvan-src` or `~/`); final
  artifacts still land back in the repo's `kernel/build/`.
- **`merge_config.sh` breaks on paths with spaces** (unquoted expansions inside
  the kernel's own script) — and this repo lives at `I:\Github Repos\...`.
  Fix: copy the fragment to `mktemp /tmp/zurvan-config-fragment.XXXXXX` first.

## Verification
QEMU serial boot log ends in the no-init panic — config, image, and 8250
console all confirmed. (Design principle recorded in README: "Verified, not
assumed" — every layer has an observable check, and this milestone's check is
literally a panic message.)

## Deferred / rabbit holes avoided
No menuconfig spelunking beyond the fragment; no custom-from-allnoconfig
minimalism (defconfig baseline accepted as good enough for an educational
project — reviewability of the *delta* is the goal).
