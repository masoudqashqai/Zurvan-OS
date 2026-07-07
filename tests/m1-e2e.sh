#!/bin/sh
# Milestone 1 "done when": a box reboots and comes back with hostname, keys,
# and an installed app intact — and a second identical server can be produced
# by copying the image, the YAML, and /data.
#
# Run as root (losetup/mount); needs qemu-system-x86_64, a built kernel,
# rootfs, and ISO (make all && scripts/make-iso.sh), and port 2222 free.
# Rewrites build/disk.img and build/disk-clone.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KEY=/tmp/ze2e_key
rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH="ssh -p 2222 -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"

# --- phase 1: install onto a blank disk from the CD ---------------------------
rm -f build/disk.img build/disk-clone.img
truncate -s 2G build/disk.img
catalog/build-hello.sh >/dev/null 2>&1

echo "=== phase 1: zurvan-install onto blank disk ==="
{
    sleep 25
    printf 'zurvan-install --yes /dev/sda\n'
    sleep 20
    printf 'poweroff -f\n'; sleep 5
} | timeout 90 qemu-system-x86_64 -m 256 \
    -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
    -append "console=ttyS0" \
    -drive file=build/disk.img,format=raw,if=ide \
    -cdrom build/zurvan.iso \
    -nographic > /tmp/ze2e-install.log 2>&1 || true
tr -d '\0' < /tmp/ze2e-install.log | grep -aq '\[install\] done' || { echo "FAIL: install"; exit 1; }
echo "installed."

# --- phase 2: this box's identity = one YAML + /data ---------------------------
echo "=== phase 2: seed /data with the box's YAML + the hello package ==="
LOOP="$(losetup -P -f --show build/disk.img)"
mkdir -p /mnt/zdata
mount "${LOOP}p2" /mnt/zdata
cat > /mnt/zdata/zurvan.yaml <<EOF
hostname: zurvan-e2e
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
EOF
cp build/catalog/hello-1.0.tar.gz /mnt/zdata/
umount /mnt/zdata
losetup -d "$LOOP"

# --- boot helper: default (VGA) GRUB entry, shell over SSH ----------------------
boot_disk() {  # $1 = disk image
    qemu-system-x86_64 -m 256 \
        -drive "file=$1,format=raw,if=ide" \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0 \
        -display none >/dev/null 2>&1 &
    QPID=$!
}
wait_ssh() {
    for i in $(seq 1 45); do
        sleep 2
        $SSH true 2>/dev/null && return 0
    done
    echo "FAIL: ssh never came up"; kill "$QPID" 2>/dev/null; exit 1
}
fp() { ssh-keyscan -p 2222 -t ed25519 127.0.0.1 2>/dev/null | ssh-keygen -lf - | awk '{print $2}'; }
down() { $SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; }

echo "=== boot A: install the app ==="
boot_disk build/disk.img; wait_ssh
FP1="$(fp)"; HN1="$($SSH hostname)"
OUT1="$($SSH 'zurvan-pkg install /data/hello-1.0.tar.gz >/dev/null && hello')"
echo "  $HN1 | $FP1 | $OUT1"
down

echo "=== boot B: reboot — everything must survive ==="
boot_disk build/disk.img; wait_ssh
FP2="$(fp)"; HN2="$($SSH hostname)"; OUT2="$($SSH hello)"; PKGS="$($SSH zurvan-pkg list)"
echo "  $HN2 | $FP2 | $OUT2 | pkgs: $PKGS"
down

echo "=== boot C: the clone — a second identical server ==="
cp build/disk.img build/disk-clone.img
boot_disk build/disk-clone.img; wait_ssh
FP3="$(fp)"; HN3="$($SSH hostname)"; OUT3="$($SSH hello)"
echo "  $HN3 | $FP3 | $OUT3"
down

# --- verdict ---------------------------------------------------------------------
ok=1
[ "$HN1$HN2$HN3" = "zurvan-e2ezurvan-e2ezurvan-e2e" ] || { echo "FAIL hostname: $HN1/$HN2/$HN3"; ok=0; }
{ [ -n "$FP1" ] && [ "$FP1" = "$FP2" ] && [ "$FP2" = "$FP3" ]; } || { echo "FAIL fingerprint: $FP1/$FP2/$FP3"; ok=0; }
case "$OUT1" in *"1 time."*) ;; *) echo "FAIL first run: $OUT1"; ok=0;; esac
case "$OUT2" in *"2 times."*) ;; *) echo "FAIL after reboot: $OUT2"; ok=0;; esac
case "$OUT3" in *"3 times."*) ;; *) echo "FAIL on clone: $OUT3"; ok=0;; esac
[ "$ok" = 1 ] && echo "MILESTONE 1 DONE-WHEN: PASS" || exit 1
