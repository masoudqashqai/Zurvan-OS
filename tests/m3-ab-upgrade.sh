#!/bin/sh
# M3 phase 2: A/B upgrades, verification gate, and automatic fallback.
#
# Driven over SSH, not the GRUB serial menu: we let GRUB auto-boot its default
# entry (and auto-fall-back on a bad slot), then drive the running box over
# ssh. grubenv is inspected offline (VM down) via losetup — ground truth.
#
#   install (slot a active)
#   T1: unsigned bundle -> zurvan-upgrade rejects it, slot b untouched
#   T2: good signed bundle -> upgrade, reboot, slot b boots + commits active=b
#   T3: upgrade then corrupt the new slot -> GRUB falls back to the good slot,
#       active unchanged.
#
# Run as root (losetup/mount); needs qemu-system-x86_64, gpg, a built kernel,
# rootfs, ISO, and upgrade bundle (make all && scripts/make-iso.sh), and port
# 2222 free. Rewrites build/disk.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGDIR="${LOGDIR:-/tmp/zurvan-m3ab-logs}"; mkdir -p "$LOGDIR"
BOOT=/mnt/zboot; mkdir -p "$BOOT"

KEY=/tmp/zm3_key; rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH="ssh -p 2222 -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"

# grubenv reader at a space-free path: the repo may sit under a path with
# spaces, which is miserable to pass through the helpers below.
cp packages/upgrade/zurvan-grubenv "$LOGDIR/zge"; chmod +x "$LOGDIR/zge"
envget() {  # $1 key
    LOOP="$(losetup -P -f --show build/disk.img)"; mount "${LOOP}p1" "$BOOT"
    "$LOGDIR/zge" "$BOOT/boot/grub/grubenv" get "$1"
    umount "$BOOT"; losetup -d "$LOOP"
}
slot_has() {  # $1 slot $2 file -> size or MISSING
    LOOP="$(losetup -P -f --show build/disk.img)"; mount "${LOOP}p1" "$BOOT"
    if [ -f "$BOOT/boot/slot-$1/$2" ]; then wc -c < "$BOOT/boot/slot-$1/$2"; else echo MISSING; fi
    umount "$BOOT"; losetup -d "$LOOP"
}
put_data() {  # copy $1 to /data (p2) as $2, while VM is down
    LOOP="$(losetup -P -f --show build/disk.img)"; mount "${LOOP}p2" "$BOOT"
    cp "$1" "$BOOT/$2"; umount "$BOOT"; losetup -d "$LOOP"
}
corrupt_slot() {  # $1 slot $2 file
    LOOP="$(losetup -P -f --show build/disk.img)"; mount "${LOOP}p1" "$BOOT"
    dd if=/dev/urandom of="$BOOT/boot/slot-$1/$2" bs=1 seek=200 count=64 conv=notrunc 2>/dev/null
    umount "$BOOT"; losetup -d "$LOOP"
}

QPID=""
disk_up() {  # boot disk headless; GRUB auto-boots default (+auto-fallback)
    qemu-system-x86_64 -m 256 -drive file=build/disk.img,format=raw,if=ide \
        -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
        -display none >"$1" 2>&1 &
    QPID=$!
}
wait_ssh() {
    for _ in $(seq 1 60); do sleep 2; $SSH true 2>/dev/null && return 0; done
    echo "FAIL: ssh never came up"; kill "$QPID" 2>/dev/null; return 1
}
disk_down() { $SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; QPID=""; }

# --- install (serial, via direct -kernel boot; not through GRUB) --------------
rm -f build/disk.img; truncate -s 2G build/disk.img
echo "=== install (slot a) ==="
{ sleep 25; printf 'zurvan-install --yes /dev/sda\n'; sleep 25; printf 'poweroff -f\n'; sleep 5; } \
 | timeout 100 qemu-system-x86_64 -m 256 -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
   -append console=ttyS0 -drive file=build/disk.img,format=raw,if=ide -cdrom build/zurvan.iso -nographic \
   > "$LOGDIR/inst.log" 2>&1 || true
tr -d '\0' < "$LOGDIR/inst.log" | grep -aq '\[install\] done' || { echo FAIL install; exit 1; }

# our YAML on /data: root key + ssh, so we can drive over ssh
cat > /tmp/zm3.yaml <<EOF
hostname: zurvan-m3
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
EOF
put_data /tmp/zm3.yaml zurvan.yaml
echo "  active=$(envget active)  slot-b=$(slot_has b bzImage)"

# --- build a WRONG-KEY (attacker) bundle for T1 -------------------------------
rm -rf /tmp/bad && mkdir -p /tmp/bad && cd /tmp/bad
cp "$ROOT/build/iso/boot/bzImage" .
cp "$ROOT/build/iso/boot/initrd.img" .
export GNUPGHOME=/tmp/badgpg; rm -rf "$GNUPGHOME"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key attacker@evil rsa2048 sign 2>/dev/null
gpg --batch --quiet --detach-sign -o bzImage.sig bzImage
gpg --batch --quiet --detach-sign -o initrd.img.sig initrd.img
tar -cf /tmp/bad-bundle.tar bzImage bzImage.sig initrd.img initrd.img.sig
cd "$ROOT"
put_data /tmp/bad-bundle.tar bad-bundle.tar
put_data build/zurvan-upgrade.tar good.tar

echo "=== T1: unsigned/wrong-key bundle must be rejected ==="
disk_up "$LOGDIR/t1.log"; wait_ssh || exit 1
T1OUT="$($SSH 'zurvan-upgrade /data/bad-bundle.tar 2>&1; echo RC=$?')"
echo "  $T1OUT" | tr '\n' '|'; echo
disk_down
B_AFTER="$(slot_has b bzImage)"
echo "$T1OUT" | grep -qi 'signature check FAILED' && [ "$B_AFTER" = MISSING ] \
    && echo "PASS T1: unsigned rejected, slot b untouched" \
    || { echo "FAIL T1 (slot b: $B_AFTER)"; exit 1; }

echo "=== T2: good signed bundle -> upgrade + commit ==="
disk_up "$LOGDIR/t2a.log"; wait_ssh || exit 1
$SSH 'zurvan-upgrade /data/good.tar 2>&1' | sed 's/^/  /'
disk_down
[ "$(envget ab_try)" = "1" ] || { echo "FAIL T2: ab_try not armed"; exit 1; }
echo "  armed ab_try=1, slot-b now=$(slot_has b bzImage)"
disk_up "$LOGDIR/t2b.log"; wait_ssh || exit 1
SLOTB="$($SSH 'sed -n "s/.*zurvan.slot=//p" /proc/cmdline')"
disk_down
echo "  booted slot=$SLOTB  active=$(envget active)  ab_try=$(envget ab_try)"
[ "$(envget active)" = "b" ] && [ "$(envget ab_try)" = "0" ] && [ "$SLOTB" = "b" ] \
    && echo "PASS T2: upgraded, slot b booted and committed" \
    || { echo "FAIL T2"; exit 1; }

echo "=== T3: broken upgrade must fall back to the good slot ==="
put_data build/zurvan-upgrade.tar good2.tar
disk_up "$LOGDIR/t3a.log"; wait_ssh || exit 1
$SSH 'zurvan-upgrade /data/good2.tar 2>&1' | sed 's/^/  /'   # active=b -> writes slot a, arms
disk_down
corrupt_slot a initrd.img            # trial slot a will fail its signature
disk_up "$LOGDIR/t3b.log"; wait_ssh || exit 1
SLOT3="$($SSH 'sed -n "s/.*zurvan.slot=//p" /proc/cmdline')"
disk_down
echo "  after fallback: booted slot=$SLOT3  active=$(envget active)"
[ "$(envget active)" = "b" ] && [ "$SLOT3" = "b" ] \
    && echo "PASS T3: trial slot a rejected, fell back to good slot b" \
    || { echo "FAIL T3 (slot=$SLOT3 active=$(envget active))"; exit 1; }

echo "ALL A/B TESTS PASSED"
