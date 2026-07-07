#!/bin/sh
# Milestone 2 done-when: dropbear and an installed app (tick) run under
# supervision, and killing either gets it restarted within seconds.
#
# Run as root (loop mount); needs qemu-system-x86_64, a built kernel and
# rootfs (make all), and port 2222 free. Rewrites build/data.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs loop mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOGDIR="${LOGDIR:-/tmp/zurvan-m2-logs}"
mkdir -p "$LOGDIR"

KEY=/tmp/zm2_key
rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH="ssh -p 2222 -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"

# fresh data disk: YAML enables ssh + tick; tick tarball rides along
catalog/build-tick.sh >/dev/null 2>&1
rm -f build/data.img
truncate -s 256M build/data.img
mkfs.ext4 -q -F -L ZURVAN-DATA build/data.img
mkdir -p /mnt/zdata
mount -o loop build/data.img /mnt/zdata
cat > /mnt/zdata/zurvan.yaml <<EOF
hostname: zurvan-m2
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
  - tick
EOF
cp build/catalog/tick-1.0.tar.gz /mnt/zdata/
umount /mnt/zdata

boot() {
    qemu-system-x86_64 -m 256 \
        -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
        -append "console=ttyS0" \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0 \
        -drive file=build/data.img,format=raw,if=virtio \
        -nographic </dev/null >"$1" 2>&1 &
    QPID=$!
}
wait_ssh() {
    for i in $(seq 1 45); do sleep 2; $SSH true 2>/dev/null && return 0; done
    echo "FAIL: ssh never came up"; exit 1
}
down() { $SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; }

echo "=== boot 1: install tick (enabled in YAML, defined after install) ==="
boot "$LOGDIR/zm2a.log"; wait_ssh
$SSH 'zurvan-pkg install /data/tick-1.0.tar.gz'
down
grep -aq "WARNING: no definition for 'tick'" "$LOGDIR/zm2a.log" \
    && echo "ok: svc warned about tick before it was installed"

echo "=== boot 2: both under supervision ==="
boot "$LOGDIR/zm2b.log"; wait_ssh
sleep 6
TICK_PID1="$($SSH 'cat /run/svc/tick.pid')"
SSH_PID1="$($SSH 'cat /run/svc/ssh.pid')"
[ -n "$TICK_PID1" ] || { echo "FAIL: tick not running"; exit 1; }
echo "tick pid $TICK_PID1, ssh pid $SSH_PID1"

echo "--- kill tick; it must come back within seconds ---"
$SSH "kill -9 $TICK_PID1"
sleep 8
TICK_PID2="$($SSH 'cat /run/svc/tick.pid')"
if [ -z "$TICK_PID2" ] || [ "$TICK_PID1" = "$TICK_PID2" ] \
   || ! $SSH "kill -0 $TICK_PID2" 2>/dev/null; then
    echo "FAIL: tick did not come back (pid file: '$TICK_PID2')"
    echo "--- guest process list ---";  $SSH 'ps' || true
    echo "--- console [svc] lines ---"; tr -d '\0' < "$LOGDIR/zm2b.log" | grep -a '\[svc\]' || true
    exit 1
fi
echo "tick restarted: pid $TICK_PID1 -> $TICK_PID2"

echo "--- kill the dropbear listener; reconnect must work within seconds ---"
$SSH "kill -9 $SSH_PID1" || true    # our own session may drop with it
sleep 6
SSH_PID2="$($SSH 'cat /run/svc/ssh.pid')" || { echo "FAIL: cannot reconnect"; exit 1; }
[ -n "$SSH_PID2" ] && [ "$SSH_PID2" != "$SSH_PID1" ] \
    && echo "ssh restarted: pid $SSH_PID1 -> $SSH_PID2" \
    || { echo "FAIL: ssh pid unchanged"; exit 1; }

echo "--- tick's log survives on /data and kept ticking across the restart ---"
$SSH 'tail -3 /var/lib/tick/log; grep -c tick /var/lib/tick/log'
down

echo "MILESTONE 2 DONE-WHEN: PASS"
