#!/bin/sh
# M3 phase 1: verified boot on the installed disk.
#  boot 1: signature-enforced GRUB boots slot a normally.
#  boot 2: after flipping bytes in slot-a's initrd, GRUB must refuse it.
#
# Run as root (losetup/mount); needs qemu-system-x86_64 and a built kernel,
# rootfs, and ISO (make all && scripts/make-iso.sh). Rewrites build/disk.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGDIR="${LOGDIR:-/tmp/zurvan-m3boot-logs}"; mkdir -p "$LOGDIR"

rm -f build/disk.img
truncate -s 2G build/disk.img

echo "=== install from CD ==="
{
    sleep 25
    printf 'zurvan-install --yes /dev/sda\n'
    sleep 25
    printf 'poweroff -f\n'; sleep 5
} | timeout 100 qemu-system-x86_64 -m 256 \
    -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
    -append "console=ttyS0" \
    -drive file=build/disk.img,format=raw,if=ide \
    -cdrom build/zurvan.iso \
    -nographic > "$LOGDIR/inst.log" 2>&1 || true
tr -d '\0' < "$LOGDIR/inst.log" | grep -a '\[install\]' | tail -3
tr -d '\0' < "$LOGDIR/inst.log" | grep -aq '\[install\] done' || { echo "FAIL: install"; exit 1; }

boot_serial() {   # $1 log — open the "Advanced" submenu (entry 2), boot its
                  # first item (trial slot, serial console)
    {
        sleep 2;   printf '\033[B'    # -> entry 1 (previous image)
        sleep 1;   printf '\033[B'    # -> entry 2 (Advanced submenu)
        sleep 1;   printf '\r'        # open the submenu
        sleep 2;   printf '\r'        # boot its first entry (trial, serial)
        sleep 40
        printf 'poweroff -f\n'; sleep 5
    } | timeout 120 qemu-system-x86_64 -m 256 \
        -drive file=build/disk.img,format=raw,if=ide \
        -nographic > "$1" 2>&1 || true
}

echo "=== boot 1: enforcement on, everything signed ==="
boot_serial "$LOGDIR/good.log"
tr -d '\0' < "$LOGDIR/good.log" | grep -aE 'rc.init|bad signature|error' | head -8
tr -d '\0' < "$LOGDIR/good.log" | grep -aq '\[rc.init\] done' \
    && echo "PASS: signed boot reached userspace" \
    || { echo "FAIL: signed boot did not complete"; exit 1; }

echo "=== tamper: flipping 16 bytes inside slot-a initrd ==="
LOOP="$(losetup -P -f --show build/disk.img)"
mkdir -p /mnt/zboot
mount "${LOOP}p1" /mnt/zboot
printf '\377\377\377\377\377\377\377\377\377\377\377\377\377\377\377\377' \
    | dd of=/mnt/zboot/boot/slot-a/initrd.img bs=1 seek=100 count=16 conv=notrunc 2>/dev/null
umount /mnt/zboot
losetup -d "$LOOP"

echo "=== boot 2: GRUB must refuse the tampered initrd ==="
boot_serial "$LOGDIR/tamper.log"
tr -d '\0' < "$LOGDIR/tamper.log" | grep -aiE 'bad signature|verification|error' | head -5
if tr -d '\0' < "$LOGDIR/tamper.log" | grep -aq '\[rc.init\] done'; then
    echo "FAIL: tampered image booted!"; exit 1
fi
tr -d '\0' < "$LOGDIR/tamper.log" | grep -aqi 'bad signature' \
    && echo "PASS: tampered initrd refused (bad signature)" \
    || { echo "WARN: no explicit signature error — inspect $LOGDIR/tamper.log"; exit 1; }
