#!/bin/sh
# Boot Zurvan in QEMU as an initramfs, headless over serial.
#
#   kernel: kernel/build/bzImage
#   initrd: build/rootfs.cpio.gz
#
# Networking: QEMU user-mode net (-netdev user) gives a 10.0.2.0/24 with DHCP
# and DNS forwarding — no host setup or root needed. eth0 inside the guest is
# the virtio-net NIC below.
#
# Leave the session with:  Ctrl-A  then  X
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_IMG="${KERNEL_IMG:-$HERE/kernel/build/bzImage}"
INITRD="${INITRD:-$HERE/build/rootfs.cpio.gz}"

# Extra YAML for the first-boot provisioner can be passed on the cmdline, e.g.
#   APPEND_EXTRA="zurvan.config=/etc/zurvan.yaml" scripts/run-qemu.sh
APPEND_EXTRA="${APPEND_EXTRA:-}"

# Persistent /data disk (v2): attach a raw image, e.g.
#   DATA_DISK=build/data.img scripts/run-qemu.sh
# DATA_IF picks the bus: virtio (default, /dev/vda) or ide (/dev/sda, the
# closest -kernel-boot stand-in for the VMware SATA path).
DATA_DISK="${DATA_DISK:-}"
DATA_IF="${DATA_IF:-virtio}"
DISK_ARGS=""
if [ -n "$DATA_DISK" ]; then
	[ -f "$DATA_DISK" ] || { echo "!! missing disk image: $DATA_DISK" >&2; exit 1; }
	DISK_ARGS="-drive file=$DATA_DISK,format=raw,if=$DATA_IF"
fi

[ -f "$KERNEL_IMG" ] || { echo "!! missing kernel: $KERNEL_IMG (run: make kernel)" >&2; exit 1; }
[ -f "$INITRD" ]     || { echo "!! missing initrd: $INITRD (run: make rootfs)" >&2; exit 1; }

QEMU="${QEMU:-qemu-system-x86_64}"

# KVM if available, otherwise plain TCG (slower but works anywhere).
ACCEL=""
[ -e /dev/kvm ] && ACCEL="-enable-kvm"

echo ">> booting Zurvan (Ctrl-A X to quit)"
exec "$QEMU" \
	$ACCEL \
	-m 256 \
	-kernel "$KERNEL_IMG" \
	-initrd "$INITRD" \
	-append "console=ttyS0 $APPEND_EXTRA" \
	-netdev user,id=net0 \
	-device virtio-net-pci,netdev=net0 \
	$DISK_ARGS \
	-nographic
