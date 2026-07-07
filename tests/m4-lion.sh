#!/bin/sh
# Milestone 4 done-when: deleting a file from /data, then restoring a
# snapshot, brings it back — and filling the disk makes the lion eat its own
# oldest snapshot rather than fail.
#
# Driven over SSH against the installed disk (sealed root, supervised lion):
#   A: provisioner digested lion: block; daemon up; first snapshot at boot
#   B: schedule honored (every: 10s -> second snapshot appears)
#   C: no snowballing (the archive contains /data but never /data/lion)
#   D: delete a file, restore, file is back           <- done-when part 1
#   E: corrupted archive is refused
#   F: ring buffer holds at keep=3
#   G: tight disk -> oldest snapshot eaten, new one still lands  <- part 2
#
# Run as root (losetup/mount); needs qemu-system-x86_64, a built kernel,
# rootfs, and ISO (make all && scripts/make-iso.sh), and port 2222 free.
# Rewrites build/disk.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGDIR="${LOGDIR:-/tmp/zurvan-m4-logs}"; mkdir -p "$LOGDIR"
BOOT=/mnt/zboot; mkdir -p "$BOOT"

KEY=/tmp/zm4_key; rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH="ssh -p 2222 -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"

rm -f build/disk.img; truncate -s 2G build/disk.img
echo "=== install ==="
{ sleep 25; printf 'zurvan-install --yes /dev/sda\n'; sleep 25; printf 'poweroff -f\n'; sleep 5; } \
 | timeout 100 qemu-system-x86_64 -m 256 -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
   -append console=ttyS0 -drive file=build/disk.img,format=raw,if=ide -cdrom build/zurvan.iso -nographic \
   > "$LOGDIR/inst.log" 2>&1 || true
tr -d '\0' < "$LOGDIR/inst.log" | grep -aq '\[install\] done' || { echo FAIL install; exit 1; }

LOOP="$(losetup -P -f --show build/disk.img)"; mount "${LOOP}p2" "$BOOT"
cat > "$BOOT/zurvan.yaml" <<EOF
hostname: zurvan-m4
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
lion:
  every: 10s
  keep: 3
services:
  - networking
  - ssh
  - lion
EOF
umount "$BOOT"; losetup -d "$LOOP"

qemu-system-x86_64 -m 256 -drive file=build/disk.img,format=raw,if=ide \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
    -display none > "$LOGDIR/boot.log" 2>&1 &
QPID=$!
ok=0
for _ in $(seq 1 60); do sleep 2; $SSH true 2>/dev/null && { ok=1; break; }; done
[ "$ok" = 1 ] || { echo "FAIL: ssh never came up"; kill "$QPID" 2>/dev/null; exit 1; }

echo "=== A: config digested, daemon supervised, first snapshot at boot ==="
$SSH 'grep -q "^every=10s$" /run/lion.conf && grep -q "^keep=3$" /run/lion.conf' \
    || { echo "FAIL A: /run/lion.conf wrong"; exit 1; }
$SSH 'kill -0 "$(cat /run/svc/lion.pid)"' || { echo "FAIL A: lion not running under svc"; exit 1; }
ok=0
for _ in $(seq 1 15); do
    $SSH 'ls /data/lion/lion-*.manifest >/dev/null 2>&1' && { ok=1; break; }; sleep 2
done
[ "$ok" = 1 ] || { echo "FAIL A: no first snapshot"; exit 1; }
echo "PASS A"

echo "=== B: schedule honored (a second snapshot within ~25s) ==="
N0="$($SSH 'ls /data/lion/lion-*.manifest | wc -l')"
sleep 25
N1="$($SSH 'ls /data/lion/lion-*.manifest | wc -l')"
[ "$N1" -gt "$N0" ] || { echo "FAIL B: no new snapshot ($N0 -> $N1)"; exit 1; }
echo "PASS B ($N0 -> $N1)"

echo "=== C: no snowballing; the archive really holds /data ==="
$SSH 'a=$(zurvan-lion list | sed -n "\$s/ .*//p");
      tar -tzf "/data/lion/$a.tar.gz" > /tmp/toc;
      grep -q "zurvan.yaml" /tmp/toc || exit 1;
      grep -q "lion" /tmp/toc && exit 2 || exit 0' \
    || { echo "FAIL C (rc $?): archive contents wrong"; exit 1; }
echo "PASS C"

echo "=== D: delete a file, restore brings it back ==="
$SSH 'echo precious > /data/precious && zurvan-lion snap >/dev/null && rm /data/precious
      a=$(zurvan-lion list | sed -n "\$s/ .*//p"); zurvan-lion restore "$a" >/dev/null
      [ "$(cat /data/precious)" = precious ]' \
    || { echo "FAIL D: restore did not bring the file back"; exit 1; }
echo "PASS D"

echo "=== E: corrupted archive refused ==="
$SSH 'a=$(zurvan-lion list | sed -n "\$s/ .*//p")
      dd if=/dev/urandom of="/data/lion/$a.tar.gz" bs=1 seek=100 count=16 conv=notrunc 2>/dev/null
      if zurvan-lion restore "$a" >/tmp/rout 2>&1; then exit 1; fi
      grep -q "refusing" /tmp/rout' \
    || { echo "FAIL E: corrupt snapshot was not refused"; exit 1; }
echo "PASS E"

echo "=== F: ring buffer holds at keep=3 ==="
sleep 35    # several 10s cycles beyond 3 snapshots
NF="$($SSH 'ls /data/lion/lion-*.manifest | wc -l')"
[ "$NF" = 3 ] || { echo "FAIL F: keep=3 but $NF snapshots"; exit 1; }
echo "PASS F"

echo "=== G: tight disk -> eat oldest, new snapshot still lands ==="
# Park the daemon on a 24h interval (it reloads /run/lion.conf when svc
# respawns it), then drive snaps by hand like an admin would. The squeeze:
# a fast zero filler parked in /data/lion (excluded from snapshots, ignored
# by the sweeper) plus a small incompressible ballast that IS snapshotted.
$SSH 'printf "every=24h\nkeep=2\n" > /run/lion.conf; kill "$(cat /run/svc/lion.pid)"; sleep 3
      free_mb=$(df -m /data | awk "NR==2{print \$4}")
      dd if=/dev/zero    of=/data/lion/filler bs=1M count=$(( free_mb - 300 )) 2>/dev/null
      dd if=/dev/urandom of=/data/ballast     bs=1M count=80 2>/dev/null
      zurvan-lion snap >/dev/null && sleep 1 && zurvan-lion snap >/dev/null' \
    || { echo "FAIL G: setup"; exit 1; }
GOUT="$($SSH 'old=$(zurvan-lion list | sed -n "1s/ .*//p")
      kept=$(zurvan-lion list | sed -n "\$s/ .*//p")
      sleep 1; zurvan-lion snap 2>&1 || true
      echo "OLD_GONE=$([ -f /data/lion/$old.tar.gz ] && echo no || echo yes)"
      echo "KEPT_OK=$([ -f /data/lion/$kept.tar.gz ] && echo yes || echo no)"
      echo "COUNT=$(ls /data/lion/lion-*.manifest | wc -l)"')"
echo "$GOUT" | grep -a 'making room\|OLD_GONE\|KEPT_OK\|COUNT'
echo "$GOUT" | grep -q 'OLD_GONE=yes' || { echo "FAIL G: oldest survived"; exit 1; }
echo "$GOUT" | grep -q 'KEPT_OK=yes'  || { echo "FAIL G: newest was eaten"; exit 1; }
echo "$GOUT" | grep -q 'COUNT=2'      || { echo "FAIL G: ring wrong after pressure"; exit 1; }
echo "PASS G"

$SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
echo "MILESTONE 4 DONE-WHEN: PASS"
