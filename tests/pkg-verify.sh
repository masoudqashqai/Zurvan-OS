#!/bin/sh
# Signature-verified package installs, driven over SSH.
#   - a catalog package (tick, shipped to /data by the installer WITH its
#     .sig) installs: the signature gate passes good packages.
#   - a tarball with no .sig beside it is refused, with a message that says
#     what is missing.
#   - a tampered tarball (one flipped byte, original .sig) is refused.
#   - `zurvan-pkg install --unsigned` is the explicit override, and works.
#   - a refused install leaves the root sealed (the rw toggle unwinds).
#
# Run as root (losetup/mount); needs qemu-system-x86_64, a built kernel,
# rootfs, and ISO (make all && make catalog && scripts/make-iso.sh), and
# port 2224 free. Rewrites build/pkgverify.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGDIR="${LOGDIR:-/tmp/zurvan-pkgverify-logs}"; mkdir -p "$LOGDIR"
BOOT=/mnt/zpkgv; mkdir -p "$BOOT"

KEY=/tmp/zpkgv_key; rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH="ssh -p 2224 -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"

rm -f build/pkgverify.img; truncate -s 2G build/pkgverify.img
echo "=== install to disk ==="
{ sleep 25; printf 'zurvan-install --yes /dev/sda\n'; sleep 25; printf 'poweroff -f\n'; sleep 5; } \
 | timeout 100 qemu-system-x86_64 -m 256 -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
   -append console=ttyS0 -drive file=build/pkgverify.img,format=raw,if=ide -cdrom build/zurvan.iso -nographic \
   > "$LOGDIR/inst.log" 2>&1 || true
tr -d '\0' < "$LOGDIR/inst.log" | grep -aq '\[install\] done' || { echo FAIL install; exit 1; }

echo "=== seed ssh key ==="
LOOP="$(losetup -P -f --show build/pkgverify.img)"; mount "${LOOP}p2" "$BOOT"
cat > "$BOOT/zurvan.yaml" <<EOF
hostname: zurvan-pkgv
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
EOF
ls "$BOOT"/tick-1.0.tar.gz.sig >/dev/null || { echo "FAIL: installer did not ship .sig files to /data"; umount "$BOOT"; losetup -d "$LOOP"; exit 1; }
umount "$BOOT"; losetup -d "$LOOP"

echo "=== boot ==="
qemu-system-x86_64 -m 256 -drive file=build/pkgverify.img,format=raw,if=ide \
    -netdev user,id=n0,hostfwd=tcp::2224-:22 -device virtio-net-pci,netdev=n0 \
    -display none > "$LOGDIR/boot.log" 2>&1 &
QPID=$!
ok=0
for _ in $(seq 1 60); do sleep 2; $SSH true 2>/dev/null && { ok=1; break; }; done
[ "$ok" = 1 ] || { echo "FAIL: ssh never came up"; kill "$QPID" 2>/dev/null; exit 1; }

echo "=== probes ==="
R="$($SSH '
  echo SIGOK=$(zurvan-pkg install /data/tick-1.0.tar.gz >/dev/null 2>&1 && echo OK || echo FAIL)
  cp /data/tick-1.0.tar.gz /data/nosig.tar.gz
  echo NOSIG=$(zurvan-pkg install /data/nosig.tar.gz >/dev/null 2>&1 && echo BAD || echo REFUSED)
  echo NOSIGMSG=$(zurvan-pkg install /data/nosig.tar.gz 2>&1 | grep -c "no signature")
  cp /data/tick-1.0.tar.gz /data/tamper.tar.gz
  cp /data/tick-1.0.tar.gz.sig /data/tamper.tar.gz.sig
  printf X | dd of=/data/tamper.tar.gz bs=1 seek=100 conv=notrunc 2>/dev/null
  echo TAMPER=$(zurvan-pkg install /data/tamper.tar.gz >/dev/null 2>&1 && echo BAD || echo REFUSED)
  echo SEALED=$(touch /usr/bin/zzz 2>/dev/null && echo WRITABLE || echo EROFS)
  echo OVERRIDE=$(zurvan-pkg install --unsigned /data/nosig.tar.gz >/dev/null 2>&1 && echo OK || echo FAIL)
  echo RESEALED=$(touch /usr/bin/zzz 2>/dev/null && echo WRITABLE || echo EROFS)
')"
$SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
echo "$R"

echo "=== verdict ==="
g() { echo "$R" | grep "^$1=" | cut -d= -f2; }
pass=1
[ "$(g SIGOK)" = OK ]        || { echo "FAIL: signed catalog package refused"; pass=0; }
[ "$(g NOSIG)" = REFUSED ]   || { echo "FAIL: missing .sig was not refused"; pass=0; }
[ "$(g NOSIGMSG)" = 1 ]      || { echo "FAIL: missing-sig error doesn't say 'no signature'"; pass=0; }
[ "$(g TAMPER)" = REFUSED ]  || { echo "FAIL: tampered package was not refused"; pass=0; }
[ "$(g SEALED)" = EROFS ]    || { echo "FAIL: refused install left the root writable"; pass=0; }
[ "$(g OVERRIDE)" = OK ]     || { echo "FAIL: --unsigned override does not work"; pass=0; }
[ "$(g RESEALED)" = EROFS ]  || { echo "FAIL: root left writable after --unsigned install"; pass=0; }
[ "$pass" = 1 ] && echo "PKG VERIFY: PASS" || { echo "PKG VERIFY: FAIL"; exit 1; }
