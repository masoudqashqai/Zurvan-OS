#!/bin/sh
# M3 phase 3: read-only root + hardening, driven over SSH.
#   - / read-only: touch /usr/bin/x -> EROFS; /data writable.
#   - zurvan-pkg install works THROUGH the seal (rw toggle) and reseals after.
#   - hardening sysctls applied; supervised services have no_new_privs.
#   - key-only SSH by default.
#
# Run as root (losetup/mount); needs qemu-system-x86_64, a built kernel,
# rootfs, and ISO (make all && scripts/make-iso.sh), and port 2222 free.
# Rewrites build/disk.img. The tick package must be in the ISO catalog
# (catalog/build-tick.sh before make-iso.sh) — the installer ships it to /data.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGDIR="${LOGDIR:-/tmp/zurvan-m3seal-logs}"; mkdir -p "$LOGDIR"
BOOT=/mnt/zboot; mkdir -p "$BOOT"

KEY=/tmp/zseal_key; rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH="ssh -p 2222 -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"

rm -f build/disk.img; truncate -s 2G build/disk.img
echo "=== install ==="
{ sleep 25; printf 'zurvan-install --yes /dev/sda\n'; sleep 25; printf 'poweroff -f\n'; sleep 5; } \
 | timeout 100 qemu-system-x86_64 -m 256 -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
   -append console=ttyS0 -drive file=build/disk.img,format=raw,if=ide -cdrom build/zurvan.iso -nographic \
   > "$LOGDIR/inst.log" 2>&1 || true
tr -d '\0' < "$LOGDIR/inst.log" | grep -aq '\[install\] done' || { echo FAIL install; exit 1; }

# write our key + ssh into /data yaml
LOOP="$(losetup -P -f --show build/disk.img)"; mount "${LOOP}p2" "$BOOT"
cat > "$BOOT/zurvan.yaml" <<EOF
hostname: zurvan-seal
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
EOF
umount "$BOOT"; losetup -d "$LOOP"

qemu-system-x86_64 -m 256 -drive file=build/disk.img,format=raw,if=ide \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
    -display none > "$LOGDIR/boot.log" 2>&1 &
QPID=$!
ok=0
for _ in $(seq 1 60); do sleep 2; $SSH true 2>/dev/null && { ok=1; break; }; done
[ "$ok" = 1 ] || { echo "FAIL: ssh never came up"; kill "$QPID" 2>/dev/null; exit 1; }

echo "=== probes ==="
R="$($SSH '
  echo RO=$(touch /usr/bin/x 2>/dev/null && echo WRITABLE || echo EROFS)
  echo DATA=$(touch /data/wp 2>/dev/null && echo WRITABLE && rm -f /data/wp || echo RO)
  echo MOUNT=$(grep -oE " / [^ ]+ (ro|rw)" /proc/mounts | awk "{print \$3}")
  echo INST=$(zurvan-pkg install /data/tick-1.0.tar.gz >/dev/null 2>&1 && echo OK || echo FAIL)
  echo POSTRO=$(touch /usr/bin/y 2>/dev/null && echo WRITABLE || echo EROFS)
  echo DMESGR=$(sysctl -n kernel.dmesg_restrict 2>/dev/null)
  echo KPTR=$(sysctl -n kernel.kptr_restrict 2>/dev/null)
  echo NNP=$(grep -i NoNewPrivs /proc/$(cat /run/svc/ssh.pid)/status | awk "{print \$2}")
  echo BAKEDSSH=$(grep -q -- "-s" /etc/svc/ssh.def && echo keyonly || echo password)
  echo RUNSSH=$([ -f /run/svc/ssh.def ] && echo present || echo absent)
')"
$SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
echo "$R"

echo "=== verdict ==="
g() { echo "$R" | grep "^$1=" | cut -d= -f2; }
pass=1
[ "$(g RO)" = EROFS ]     || { echo "FAIL: root writable"; pass=0; }
[ "$(g DATA)" = WRITABLE ]|| { echo "FAIL: /data not writable"; pass=0; }
[ "$(g MOUNT)" = ro ]     || { echo "FAIL: / not mounted ro ($(g MOUNT))"; pass=0; }
[ "$(g INST)" = OK ]      || { echo "FAIL: install through seal"; pass=0; }
[ "$(g POSTRO)" = EROFS ] || { echo "FAIL: root left writable after install"; pass=0; }
[ "$(g DMESGR)" = 1 ]     || { echo "FAIL: dmesg_restrict=$(g DMESGR)"; pass=0; }
[ "$(g KPTR)" = 2 ]       || { echo "FAIL: kptr_restrict=$(g KPTR)"; pass=0; }
[ "$(g NNP)" = 1 ]        || { echo "FAIL: dropbear no_new_privs=$(g NNP)"; pass=0; }
[ "$(g BAKEDSSH)" = keyonly ]|| { echo "FAIL: ssh not key-only by default"; pass=0; }
[ "$(g RUNSSH)" = absent ]|| { echo "FAIL: ssh override present (should be key-only)"; pass=0; }
[ "$pass" = 1 ] && echo "SEAL PHASE 3: PASS" || { echo "SEAL PHASE 3: FAIL"; exit 1; }
