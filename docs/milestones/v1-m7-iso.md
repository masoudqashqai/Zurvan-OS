---
id: v1-m7
version: v1
milestone: 7
title: "Bootable ISO — GRUB, VMware/QEMU, the v1 final product"
status: done
completed: 2026-07-02
commits: [0083b39]
key_files: [scripts/make-iso.sh]
verification: "ISO boots the full chain (DHCP, provisioner, shell) in QEMU serial and VMware VGA"
---

## Goal
Turn the -kernel/-initrd development boot into a distributable artifact: a
GRUB-booted ISO (~23 MB) that works in VMware Workstation and on BIOS
machines. This was the v1 deliverable — the thing a stranger can download
and run.

## Done-when
The same system boots from CD in VMware (VGA) and QEMU (serial), through
DHCP and the provisioner to a bash prompt. Still 100% RAM — no disk touched.

## Design decisions
- **`grub-mkrescue`** does the heavy lifting (stage dir with
  `/boot/grub/grub.cfg`, bzImage, initrd.img → hybrid BIOS ISO). Host deps:
  `grub-pc-bin xorriso mtools`.
- **Two menu entries, and why they must stay separate**: `console=tty0` (VGA,
  default — VMware/real hardware) vs `console=ttyS0` (headless QEMU). The
  last `console=` decides where the kernel console AND therefore PID 1's
  supervised shell land, so one entry cannot serve both worlds.
- 3-second auto-boot timeout (changed to 10s on the *installed disk* menu in
  v2 M3; the ISO's own menu kept its behavior).
- **e1000 verified deliberately** — it's VMware's default NIC for "Other
  Linux"; virtio-only testing would have shipped a VMware-blind image.

## How it was built
`scripts/make-iso.sh`: stage `iso/boot/{bzImage,initrd.img}` +
`grub.cfg` with the two entries → `grub-mkrescue -o build/zurvan.iso stage/`.
`make iso`. (The script grew a lot in v2: the `/install/` payload for
zurvan-install, catalog packages, GPG signing of everything, and the
upgrade-bundle emission.)

## Key files
| path | role |
|---|---|
| `scripts/make-iso.sh` | staging + grub-mkrescue; later the home of all v2 boot-artifact logic |

## Problems hit
Nothing notable at v1 — the pain in this area arrived in v2 M3 (core.img
size vs MBR gap; see v2-m3). The subtlety worth keeping: the `console=`
split, which looks cosmetic and is functional.

## Verification
Serial entry: full chain green over e1000 (DHCP, provisioner, ping). VGA
entry: screenshot of boot through provisioner to bash prompt in a VMware-
style window. Release: v1.0.0 with the ISO + SHA-256 on GitHub releases,
README rewritten around the download (ec5a0bb, 591c052), MIT license
(4ef4f58).

## Deferred / rabbit holes avoided
UEFI boot (still deferred as of v2 M3 — BIOS/MBR only), secure boot,
hybrid-USB polish beyond what grub-mkrescue gives for free.
