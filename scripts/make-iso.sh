#!/bin/sh
# make-iso.sh — bundle the built kernel + initrd into a GRUB-bootable ISO.
#
# The ISO boots the same RAM-backed system as `make run`: GRUB loads the kernel
# and rootfs.cpio.gz from the CD, the kernel unpacks the initramfs, and /init
# takes over. No disk is touched — reboot returns to a clean state, which is
# exactly the Zurvan model (source is timeless, instances are ephemeral).
#
# Boots in VMware Workstation ("Other Linux 64-bit", attach the ISO), QEMU
# (-cdrom), and BIOS machines. Requires: grub-mkrescue (grub-pc-bin), xorriso,
# mtools.
#
# Output: build/zurvan.iso
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-$HERE/build}"
KERNEL_IMG="${KERNEL_IMG:-$HERE/kernel/build/bzImage}"
INITRD="${INITRD:-$BUILD/rootfs.cpio.gz}"
ISO="${ISO:-$BUILD/zurvan.iso}"
STAGE="$BUILD/iso"

[ -f "$KERNEL_IMG" ] || { echo "!! missing kernel: $KERNEL_IMG (run: make kernel)" >&2; exit 1; }
[ -f "$INITRD" ]     || { echo "!! missing initrd: $INITRD (run: make rootfs)" >&2; exit 1; }
command -v grub-mkrescue >/dev/null 2>&1 \
	|| { echo "!! grub-mkrescue not found (install grub-pc-bin, xorriso, mtools)" >&2; exit 1; }

# --- ISO tree -----------------------------------------------------------------
rm -rf "$STAGE"
mkdir -p "$STAGE/boot/grub"
cp "$KERNEL_IMG" "$STAGE/boot/bzImage"
cp "$INITRD"     "$STAGE/boot/initrd.img"

# GRUB drives both the VGA screen and the first serial port, so the menu works
# in VMware / on real hardware (VGA) and under `qemu -cdrom ... -nographic`
# (serial) alike. The console= choice decides where /dev/console — and thus the
# supervised shell — ends up, so they are separate menu entries.
cat > "$STAGE/boot/grub/grub.cfg" <<'CFG'
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial

set default=0
set timeout=3

# VGA console — VMware Workstation / real hardware.
menuentry "Zurvan" {
	linux  /boot/bzImage console=tty0
	initrd /boot/initrd.img
}

# Serial console — headless QEMU (-nographic).
menuentry "Zurvan (serial console)" {
	linux  /boot/bzImage console=ttyS0
	initrd /boot/initrd.img
}
CFG

# --- build --------------------------------------------------------------------
echo ">> grub-mkrescue -> $ISO"
grub-mkrescue -o "$ISO" "$STAGE"

echo ">> done: $ISO"
ls -lh "$ISO"
echo ">> try it:  qemu-system-x86_64 -cdrom $ISO -m 256   (VGA window)"
echo ">>     or:  qemu-system-x86_64 -cdrom $ISO -m 256 -nographic  (pick the serial entry)"
