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

# --- signatures (v2 milestone 3, "the seal") -------------------------------------
# Everything the INSTALLED DISK's GRUB will read gets a detached signature,
# made here at build time — the private key never leaves the build machine.
# The ISO itself stays unverified on purpose: install media is in your hands
# and checked by its SHA-256; enforcement defends the installed box.
SIGN="$HERE/scripts/sign.sh"
[ -f "$HERE/keys/zurvan-signing.pub" ] \
	|| { echo "!! no signing key — run scripts/make-keys.sh first" >&2; exit 1; }
"$SIGN" "$STAGE/boot/bzImage" "$STAGE/boot/initrd.img"

# --- installer payload (v2 milestone 1 + 3) --------------------------------------
# zurvan-install writes these to a target disk: boot.img goes in the MBR,
# core.img at sector 1. The core embeds the signing PUBLIC key, which turns on
# GRUB signature enforcement for everything it loads from the disk — config,
# modules, kernel, initrd — so they all travel with .sig files.
GRUB_LIB="${GRUB_LIB:-/usr/lib/grub/i386-pc}"
command -v grub-mkimage >/dev/null 2>&1 \
	|| { echo "!! grub-mkimage not found (install grub-pc-bin)" >&2; exit 1; }
[ -f "$GRUB_LIB/boot.img" ] \
	|| { echo "!! $GRUB_LIB/boot.img not found (install grub-pc-bin)" >&2; exit 1; }
mkdir -p "$STAGE/install"
grub-mkimage -O i386-pc -o "$STAGE/install/core.img" \
	--prefix='(hd0,msdos1)/boot/grub' \
	--pubkey "$HERE/keys/zurvan-signing.pub" \
	biosdisk part_msdos ext2 pgp gcry_rsa gcry_sha256 gcry_sha512
cp "$GRUB_LIB/boot.img" "$STAGE/install/boot.img"

# The disk's grub.cfg is FIXED at build time (it must be signed). It knows the
# A/B slot layout; the unsigned grubenv block only says which signed slot to
# try — the worst a grubenv tamper can do is boot the other signed image.
cat > "$STAGE/install/grub-disk.cfg" <<'CFG'
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial

# grubenv carries: active (committed slot) and ab_try (1 = a freshly
# upgraded other-slot deserves one trial boot). It is written by Linux
# (zurvan-upgrade / the boot-health commit) and by save_env below.
set check_signatures=no
load_env active ab_try
set check_signatures=enforce

if [ "$active" != "b" ]; then set active=a; fi
if [ "$active" = "b" ]; then set other=a; else set other=b; fi

# Trial boot: consume the token NOW (save_env), then try the new slot.
# If it panics, the kernel reboots (panic=10) and this config — finding
# ab_try spent and active unchanged — boots the good slot again.
if [ "$ab_try" = "1" ]; then
	set ab_try=0
	save_env ab_try
	set trial=$other
else
	set trial=$active
fi
if [ "$trial" = "b" ]; then set standby=a; else set standby=b; fi

set default=0
# Load failure (bad signature, missing file) falls through immediately:
set fallback=1
set timeout=3

menuentry "Zurvan (slot $trial)" {
	linux  /boot/slot-$trial/bzImage console=tty0 panic=10 zurvan.slot=$trial
	initrd /boot/slot-$trial/initrd.img
}
menuentry "Zurvan (slot $standby)" {
	linux  /boot/slot-$standby/bzImage console=tty0 panic=10 zurvan.slot=$standby
	initrd /boot/slot-$standby/initrd.img
}
menuentry "Zurvan (slot $trial, serial console)" {
	linux  /boot/slot-$trial/bzImage console=ttyS0 panic=10 zurvan.slot=$trial
	initrd /boot/slot-$trial/initrd.img
}
menuentry "Zurvan (slot $standby, serial console)" {
	linux  /boot/slot-$standby/bzImage console=ttyS0 panic=10 zurvan.slot=$standby
	initrd /boot/slot-$standby/initrd.img
}
CFG
"$SIGN" "$STAGE/install/grub-disk.cfg"

# Signed copies of every GRUB module/list the disk install will serve —
# with enforcement on, an unsigned normal.mod is a boot failure.
echo ">> signing GRUB modules for the disk install"
mkdir -p "$STAGE/install/i386-pc"
cp "$GRUB_LIB"/*.mod "$GRUB_LIB"/*.lst "$STAGE/install/i386-pc/"
"$SIGN" "$STAGE/install/i386-pc"/*

# --- catalog packages (v2 milestone 2) ------------------------------------------
# Ship whatever `make catalog` built; zurvan-install copies them onto /data so
# a freshly installed box can `zurvan-pkg install /data/<pkg>.tar.gz` offline.
if ls "$BUILD"/catalog/*.tar.gz >/dev/null 2>&1; then
	mkdir -p "$STAGE/catalog"
	cp "$BUILD"/catalog/*.tar.gz "$STAGE/catalog/"
	echo ">> catalog packages on ISO: $(ls "$BUILD"/catalog/*.tar.gz | wc -l)"
fi

# --- build --------------------------------------------------------------------
echo ">> grub-mkrescue -> $ISO"
grub-mkrescue -o "$ISO" "$STAGE"

echo ">> done: $ISO"
ls -lh "$ISO"
echo ">> try it:  qemu-system-x86_64 -cdrom $ISO -m 256   (VGA window)"
echo ">>     or:  qemu-system-x86_64 -cdrom $ISO -m 256 -nographic  (pick the serial entry)"
