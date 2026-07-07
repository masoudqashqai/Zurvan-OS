---
id: v2-m1
version: v2
milestone: 1
title: "The memory box — persistent /data, zurvan-install, static packages"
status: done
completed: 2026-07-06
commits: [e8181f6, c83faa4, 7d71359, 2579f01, ed00ef3, 11bd8f8, ec89014]
key_files: [packages/installer/zurvan-install, packages/pkgtool/zurvan-pkg, rootfs/etc/rc.init, userland/build-e2fsprogs.sh, kernel/config-fragment, catalog/]
verification: tests/m1-e2e.sh
---

## Goal
Give the ephemeral OS its missing half: ONE persistent ext4 partition
(`/data`) holding the YAML, installed apps, and service state — while the OS
itself keeps booting from RAM, untouched and identical every time. Plus the
official answer to "how do I install software": a curated static-package
system. v2's thesis in one line: **the OS is never installed — only the data
is.** A machine = image version + one YAML + /data contents.

## Done-when
A box reboots and comes back with hostname, SSH fingerprint, and an installed
app intact — and byte-copying the disk produces a provably identical second
server.

## Design decisions
- **Persistence is opt-in per path, never global.** Root stays RAM/tmpfs;
  only paths that deliberately point into /data survive. No overlay-on-root.
- **Discovery by filesystem LABEL** (`ZURVAN-DATA`, later `ZURVAN-BOOT`), not
  device names — works identically across virtio (/dev/vda), IDE/SATA
  (/dev/sda), and VMware SCSI.
- **zurvan-install is the only program allowed to touch a raw disk.** The
  disk carries exactly: GRUB boot code (boot.img in MBR + core.img following
  it, both prebuilt by make-iso into the ISO's `/install/`), p1 = 256M ext4
  ZURVAN-BOOT (kernel + initrd + grub modules copied off the CD), p2 = rest,
  ext4 ZURVAN-DATA. Upgrading = replacing files on p1 (formalized in M3).
- **Packages = tarball of static binaries + manifest.yaml** (same YAML dialect
  as the provisioner). Install unpacks to `/data/apps/<name>/`; mutable state
  lives in `/data/srv/<name>/`; runtime junk stays in RAM and evaporates.
- **The set-dresser trick** (the milestone's central idea): programs expect
  `/usr/bin`, `/var/lib` — and the RAM root is freely writable — so symlinks
  from standard paths into /data are planted at install time AND rebuilt from
  manifests on every boot (`zurvan-pkg dress` in rc.init). Links can never
  rot because they never persist.
- **Dependencies deliberately shallow**: static linking deleted the hard
  problem; `needs:` is an existence check in a ten-line loop. Roadmap rule:
  "the moment the resolver wants to be clever, stop."
- **Curated catalog** (`catalog/build-<name>.sh`, same style as userland
  builds) — the promise is "everything in the catalog works perfectly", not
  "runs any Linux software". First entries: `hello` (run-counter in
  /var/lib/hello → /data/srv/hello), later `tick` (M2).

## How it was built (order matters — each step boot-verified before the next)
1. **Kernel disk stack** (e8181f6): AHCI + PIIX IDE + virtio-blk + VMware's
   mptspi/PVSCSI + SD/SCSI + partition tables + ext4 in config-fragment;
   kernel rebuilt. `run-qemu.sh` learned `DATA_DISK=`/`DATA_IF=` (ide = the
   closest -kernel-boot stand-in for VMware's SATA path).
2. **rc.init mounts /data**: settle-retry loop for device probe, best-effort
   `e2fsck -p`, mount by LABEL. No labeled disk = unchanged v1 boot.
   Static `mke2fs`/`e2fsck` from `userland/build-e2fsprogs.sh` (busybox's
   mke2fs is ext2-only); `-std=gnu17` again.
3. **zurvan-install** (c83faa4): fdisk-scripted MBR, dd boot.img/core.img,
   mkfs + label both partitions, copy boot files off the CD, seed /data.
4. **zurvan-pkg + manifests + catalog** (7d71359): install/remove/list/dress.
5. **Persistence wiring** (2579f01): provisioner prefers /data/zurvan.yaml;
   dropbear host keys moved to /data via /etc/dropbear symlink (stable SSH
   fingerprint); rc.init runs dress after mount, before services.
6. Post-milestone fixes: DHCP example default + catalog shipped on ISO and
   seeded to /data by the installer (11bd8f8); reinstall over an old Zurvan
   disk auto-unmounts the previous /data (ec89014).

## Key files
| path | role |
|---|---|
| `packages/installer/zurvan-install` | partition + GRUB + copy + seed; only raw-disk writer |
| `packages/pkgtool/zurvan-pkg` | install/remove/list/dress + service export (M2) |
| `rootfs/etc/rc.init` | /data mount, dress call — the boot-order source of truth |
| `catalog/build-hello.sh`, `catalog/build-tick.sh` | the catalog contribution model |

## Problems hit
- **WSL's drvfs poisoned the initramfs**: on /mnt/* every file is uid 1000 /
  mode 777; those modes leaked into the cpio archive, and dropbear (strict
  permission checks) rejected `authorized_keys` for baked-in users. Fix:
  build.sh packs from a **root-owned staging copy**; the provisioner also
  normalizes home dir ownership at apply time as a belt.
- **Reinstalling over an existing Zurvan disk always failed**: rc.init had
  auto-mounted the old ZURVAN-DATA, tripping the installer's
  mounted-partitions safety check. Fix: the installer releases that specific
  mount itself; anything else mounted still refuses (ec89014).
- **QEMU-specific static IP as the example default silently broke VMware
  NAT** — changed to DHCP (11bd8f8).

## Verification
`tests/m1-e2e.sh` (run as root, WSL): install from CD to blank 2G disk →
seed YAML+key on /data → boot A: install hello, runs "1 time" → boot B:
same hostname, same ed25519 fingerprint, hello says "2 times" → boot C on a
byte-copied clone: "3 times". All PASS.

## Deferred / rabbit holes avoided
No dependency solver, no versioned upgrades of packages, no package signing
(image signing came in M3), no FHS completeness — only the paths manifests
actually declare.
