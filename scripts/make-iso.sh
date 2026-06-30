#!/bin/sh
# make-iso.sh — (ROADMAP, NOT v1) build a bootable ISO with GRUB.
#
# v1 boots purely from an initramfs in QEMU; there is no bootloader and no disk
# image. This script is the scaffold for the "graduate to a real distro" roadmap
# item: bundle the kernel + initrd into a GRUB-bootable ISO that runs on real
# hardware or a VM.
#
# It is intentionally a stub so the intent is captured without pulling ISO/GRUB
# work into v1. Flesh it out only after the v1 spine + provisioner work.
set -eu

cat <<'EOF'
make-iso.sh is a ROADMAP placeholder, not part of v1.

Planned shape:
  1. Build kernel (kernel/build/bzImage) and initrd (build/rootfs.cpio.gz).
  2. Lay out an ISO tree:
       iso/boot/bzImage
       iso/boot/initrd.img
       iso/boot/grub/grub.cfg   (menuentry: linux /boot/bzImage; initrd /boot/initrd.img)
  3. grub-mkrescue -o build/zurvan.iso iso/
  4. Boot it:  qemu-system-x86_64 -cdrom build/zurvan.iso -nographic

See ROADMAP.md -> "Graduate to a real distro".
EOF
exit 0
