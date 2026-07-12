#!/bin/sh
# Panel UX: the things that make the panel pleasant, proven end-to-end.
#   0: the URL+token box is printed exactly ONCE, after all boot chatter —
#      i.e. it sits right above the first console prompt instead of being
#      scrolled away by the lines that used to follow it (live boot, serial)
#   1: a tarball and its .sig go up in ONE multi-file request, and the
#      package installs through the signature gate
#   2: a whole zurvan-catalog-<DATE>.tar.gz release pack uploads as-is: every
#      inner package is staged onto /data with its .sig, the pack file and
#      the staging dir are cleaned up
#   3: a pack-staged package installs through the signature gate
#
# Run as root (losetup/mount); needs qemu-system-x86_64, curl, a built kernel,
# rootfs, ISO, build/catalog/hello-1.0.tar.gz (+.sig), and a catalog pack
# (make catalog-pack). Ports 2226 (ssh) and 8444 (panel) free. Rewrites
# build/paneluxu.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGDIR="${LOGDIR:-/tmp/zurvan-panelux-logs}"; mkdir -p "$LOGDIR"
BOOT=/mnt/zpanelux; mkdir -p "$BOOT"
PACK="$(ls build/zurvan-catalog-*.tar.gz 2>/dev/null | sort | tail -1)"
[ -n "$PACK" ] || { echo "no build/zurvan-catalog-*.tar.gz — run make catalog-pack" >&2; exit 1; }

echo "=== 0: panel box printed once, above the prompt (live boot) ==="
{ sleep 45; printf 'poweroff -f\n'; sleep 5; } \
 | timeout 90 qemu-system-x86_64 -m 256 -kernel kernel/build/bzImage \
   -initrd build/rootfs.cpio.gz -append console=ttyS0 -cdrom build/zurvan.iso \
   -nographic > "$LOGDIR/live.log" 2>&1 || true
tr -d '\0' < "$LOGDIR/live.log" > "$LOGDIR/live.clean"
DONE=$(grep -an 'rc.init] done' "$LOGDIR/live.clean" | tail -1 | cut -d: -f1)
BOX=$(grep -an 'Zurvan web panel' "$LOGDIR/live.clean" | tail -1 | cut -d: -f1)
NBOX=$(grep -ac 'Zurvan web panel' "$LOGDIR/live.clean")
[ -n "$DONE" ] || { echo "FAIL 0: live boot never finished rc.init"; exit 1; }
[ -n "$BOX" ] && [ "$BOX" -gt "$DONE" ] || { echo "FAIL 0: panel box not above the prompt"; exit 1; }
[ "$NBOX" = 1 ] || { echo "FAIL 0: panel box printed $NBOX times, want exactly 1"; exit 1; }
echo "PASS 0"

KEY=/tmp/zpanelux_key; rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH="ssh -p 2226 -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"
rm -f "$LOGDIR/cj"
C="curl -sk -c $LOGDIR/cj -b $LOGDIR/cj"
U="https://127.0.0.1:8444"

rm -f build/paneluxu.img; truncate -s 2G build/paneluxu.img
echo "=== install to disk ==="
{ sleep 25; printf 'zurvan-install --yes /dev/sda\n'; sleep 25; printf 'poweroff -f\n'; sleep 5; } \
 | timeout 100 qemu-system-x86_64 -m 256 -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
   -append console=ttyS0 -drive file=build/paneluxu.img,format=raw,if=ide -cdrom build/zurvan.iso -nographic \
   > "$LOGDIR/inst.log" 2>&1 || true
tr -d '\0' < "$LOGDIR/inst.log" | grep -aq '\[install\] done' || { echo FAIL install; exit 1; }

echo "=== seed ssh key ==="
LOOP="$(losetup -P -f --show build/paneluxu.img)"; mount "${LOOP}p2" "$BOOT"
cat > "$BOOT/zurvan.yaml" <<EOF
hostname: zurvan-panelux
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
  - face
EOF
# clear the installer-shipped packages so the staging checks below see only
# what the uploads brought in
rm -f "$BOOT"/*.tar.gz "$BOOT"/*.tar.gz.sig
umount "$BOOT"; losetup -d "$LOOP"

echo "=== boot ==="
qemu-system-x86_64 -m 512 -drive file=build/paneluxu.img,format=raw,if=ide \
    -netdev user,id=n0,hostfwd=tcp::2226-:22,hostfwd=tcp::8444-:8443 -device virtio-net-pci,netdev=n0 \
    -display none > "$LOGDIR/boot.log" 2>&1 &
QPID=$!
down() { $SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; }
ok=0
for _ in $(seq 1 60); do sleep 2; $SSH true 2>/dev/null && { ok=1; break; }; done
[ "$ok" = 1 ] || { echo "FAIL: ssh never came up"; kill "$QPID" 2>/dev/null; exit 1; }
for _ in $(seq 1 30); do sleep 2; $C -o /dev/null "$U/login" 2>/dev/null && { ok=2; break; }; done
[ "$ok" = 2 ] || { echo "FAIL: panel never came up"; down; exit 1; }

TOK="$($SSH 'cat /data/face/token')"
$C -o /dev/null -w '%{http_code}' -d "token=$TOK" "$U/login" | grep -q 303 || { echo "FAIL: login"; down; exit 1; }

echo "=== 1: tarball + .sig in one multi-file request ==="
$C -o /dev/null "$U/packages/upload" \
   -F "file=@build/catalog/hello-1.0.tar.gz" \
   -F "file=@build/catalog/hello-1.0.tar.gz.sig"
$SSH '[ -f /data/hello-1.0.tar.gz ] && [ -f /data/hello-1.0.tar.gz.sig ]' \
    || { echo "FAIL 1: pair did not land on /data from one request"; down; exit 1; }
$C -o /dev/null -d "file=hello-1.0.tar.gz" "$U/packages/install"
$SSH 'zurvan-pkg list | grep -q hello' || { echo "FAIL 1: hello did not install"; down; exit 1; }
echo "PASS 1"

echo "=== 2: the whole catalog pack in one upload ==="
$C -o /dev/null "$U/packages/upload" -F "file=@$PACK"
R="$($SSH '
  echo NPKG=$(ls /data/*.tar.gz 2>/dev/null | wc -l)
  echo NSIG=$(ls /data/*.tar.gz.sig 2>/dev/null | wc -l)
  echo PACKGONE=$(ls /data/zurvan-catalog-* 2>/dev/null | wc -l)
  echo STAGEGONE=$(ls -d /data/.pack-stage-* 2>/dev/null | wc -l)
')"
echo "$R"
g() { echo "$R" | grep "^$1=" | cut -d= -f2; }
[ "$(g NPKG)" -ge 8 ]         || { echo "FAIL 2: expected >=8 staged packages, got $(g NPKG)"; down; exit 1; }
[ "$(g NSIG)" = "$(g NPKG)" ] || { echo "FAIL 2: sig count $(g NSIG) != package count $(g NPKG)"; down; exit 1; }
[ "$(g PACKGONE)" = 0 ]       || { echo "FAIL 2: pack file left on /data"; down; exit 1; }
[ "$(g STAGEGONE)" = 0 ]      || { echo "FAIL 2: staging dir left behind"; down; exit 1; }
echo "PASS 2"

echo "=== 3: a pack-staged package installs through the signature gate ==="
SYNC="$(basename "$(ls build/catalog/syncthing-*.tar.gz | head -1)")"
$C -o /dev/null -d "file=$SYNC" "$U/packages/install"
$SSH 'zurvan-pkg list | grep -q syncthing' || { echo "FAIL 3: staged syncthing did not install"; down; exit 1; }
echo "PASS 3"

down
echo "PANEL UX: PASS"
