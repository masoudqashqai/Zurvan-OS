#!/bin/sh
# The pack-tier install flow, proven with a real package. syncthing is NOT on
# the ISO — it travels as a tarball + .sig, like anything from the catalog
# pack — so this exercises the path a downloaded package actually takes:
#   - fresh install to disk, tarball + .sig shipped to /data by hand
#     (standing in for the panel upload / scp)
#   - `zurvan-pkg install` passes the signature gate
#   - `zurvan-pkg enable` starts it live, no reboot
#   - the daemon comes up with its state under /data/srv/syncthing
#   - the GUI listens on 127.0.0.1:8384 and NOWHERE else (it has no
#     password until you set one — loopback-only is the security posture)
#   - the sync protocol listens on :22000
#   - the GUI actually serves its page over HTTP
#
# Run as root (losetup/mount); needs qemu-system-x86_64, a built kernel,
# rootfs, ISO, and build/catalog/syncthing-*.tar.gz with its .sig
# (catalog/build-syncthing.sh, signed via `make catalog`), and port 2225
# free. Rewrites build/syncsmoke.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGDIR="${LOGDIR:-/tmp/zurvan-syncsmoke-logs}"; mkdir -p "$LOGDIR"
BOOT=/mnt/zsyncsmoke; mkdir -p "$BOOT"

PKG="$(ls build/catalog/syncthing-*.tar.gz 2>/dev/null | head -1)"
[ -n "$PKG" ] || { echo "no build/catalog/syncthing-*.tar.gz — run catalog/build-syncthing.sh" >&2; exit 1; }
[ -f "$PKG.sig" ] || { echo "$PKG has no .sig — sign it (make catalog / scripts/sign.sh)" >&2; exit 1; }
PKGBASE="$(basename "$PKG")"

KEY=/tmp/zsync_key; rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH="ssh -p 2225 -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"

rm -f build/syncsmoke.img; truncate -s 2G build/syncsmoke.img
echo "=== install to disk ==="
{ sleep 25; printf 'zurvan-install --yes /dev/sda\n'; sleep 25; printf 'poweroff -f\n'; sleep 5; } \
 | timeout 100 qemu-system-x86_64 -m 256 -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
   -append console=ttyS0 -drive file=build/syncsmoke.img,format=raw,if=ide -cdrom build/zurvan.iso -nographic \
   > "$LOGDIR/inst.log" 2>&1 || true
tr -d '\0' < "$LOGDIR/inst.log" | grep -aq '\[install\] done' || { echo FAIL install; exit 1; }

echo "=== seed ssh key + ship $PKGBASE to /data ==="
LOOP="$(losetup -P -f --show build/syncsmoke.img)"; mount "${LOOP}p2" "$BOOT"
cat > "$BOOT/zurvan.yaml" <<EOF
hostname: zurvan-syncsmoke
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
EOF
cp "$PKG" "$PKG.sig" "$BOOT/"
umount "$BOOT"; losetup -d "$LOOP"

echo "=== boot ==="
qemu-system-x86_64 -m 512 -drive file=build/syncsmoke.img,format=raw,if=ide \
    -netdev user,id=n0,hostfwd=tcp::2225-:22 -device virtio-net-pci,netdev=n0 \
    -display none > "$LOGDIR/boot.log" 2>&1 &
QPID=$!
ok=0
for _ in $(seq 1 60); do sleep 2; $SSH true 2>/dev/null && { ok=1; break; }; done
[ "$ok" = 1 ] || { echo "FAIL: ssh never came up"; kill "$QPID" 2>/dev/null; exit 1; }

echo "=== install + enable + probe ==="
R="$($SSH "
  echo INSTALL=\$(zurvan-pkg install /data/$PKGBASE >/dev/null 2>&1 && echo OK || echo FAIL)
  echo ENABLE=\$(zurvan-pkg enable syncthing >/dev/null 2>&1 && echo OK || echo FAIL)
  up=FAIL
  for i in \$(seq 1 30); do
    sleep 2
    pid=\$(cat /run/svc/syncthing.pid 2>/dev/null || echo)
    [ -n \"\$pid\" ] && kill -0 \"\$pid\" 2>/dev/null && [ -f /data/srv/syncthing/config.xml ] && { up=OK; break; }
  done
  echo UP=\$up
  sleep 3
  echo GUILOOP=\$(netstat -tln 2>/dev/null | grep -c '127\.0\.0\.1:8384')
  echo GUIWORLD=\$(netstat -tln 2>/dev/null | grep ':8384' | grep -vc '127\.0\.0\.1')
  echo SYNCPORT=\$(netstat -tln 2>/dev/null | grep -c ':22000')
  echo GUIHTTP=\$(wget -qO- http://127.0.0.1:8384/ 2>/dev/null | grep -ci syncthing)
  echo STATE=\$(ls /data/srv/syncthing/config.xml >/dev/null 2>&1 && echo OK || echo FAIL)
")"
$SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
echo "$R"

echo "=== verdict ==="
g() { echo "$R" | grep "^$1=" | cut -d= -f2; }
pass=1
[ "$(g INSTALL)" = OK ]      || { echo "FAIL: signed syncthing package refused"; pass=0; }
[ "$(g ENABLE)" = OK ]       || { echo "FAIL: zurvan-pkg enable syncthing failed"; pass=0; }
[ "$(g UP)" = OK ]           || { echo "FAIL: syncthing never came up with config on /data"; pass=0; }
[ "$(g GUILOOP)" -ge 1 ]     || { echo "FAIL: GUI not listening on 127.0.0.1:8384"; pass=0; }
[ "$(g GUIWORLD)" = 0 ]      || { echo "FAIL: GUI listening beyond loopback"; pass=0; }
[ "$(g SYNCPORT)" -ge 1 ]    || { echo "FAIL: sync protocol not listening on :22000"; pass=0; }
[ "$(g GUIHTTP)" -ge 1 ]     || { echo "FAIL: GUI HTTP did not serve the syncthing page"; pass=0; }
[ "$(g STATE)" = OK ]        || { echo "FAIL: no config.xml under /data/srv/syncthing"; pass=0; }
[ "$pass" = 1 ] && echo "PKG SYNCTHING: PASS" || { echo "PKG SYNCTHING: FAIL"; exit 1; }
