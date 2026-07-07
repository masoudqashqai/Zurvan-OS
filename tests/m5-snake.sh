#!/bin/sh
# Milestone 5 done-when: a job that writes garbage all over its filesystem
# finishes, its output comes back, and the running system shows no trace it
# ever ran.
#
# Driven over SSH against the installed disk (sealed root, supervised snake):
#   A: daemon runs under zurvan-svc (with no_new_privs) and still sandboxes
#   B: garbage job — output + artifact back; /data, /tmp, /run untouched;
#      no leaked mounts                                  <- the done-when
#   C: exit codes propagate; timeout kills the job tree
#   D: queue: drop a file in /data/snake/queue, collect log/status/artifacts
#
# Run as root (losetup/mount); needs qemu-system-x86_64, a built kernel,
# rootfs, and ISO (make all && scripts/make-iso.sh), and port 2222 free.
# Rewrites build/disk.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGDIR="${LOGDIR:-/tmp/zurvan-m5-logs}"; mkdir -p "$LOGDIR"
BOOT=/mnt/zboot; mkdir -p "$BOOT"

KEY=/tmp/zm5_key; rm -f "$KEY" "$KEY.pub"
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
hostname: zurvan-m5
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
  - snake
EOF
umount "$BOOT"; losetup -d "$LOOP"

qemu-system-x86_64 -m 256 -drive file=build/disk.img,format=raw,if=ide \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
    -display none > "$LOGDIR/boot.log" 2>&1 &
QPID=$!
ok=0
for _ in $(seq 1 60); do sleep 2; $SSH true 2>/dev/null && { ok=1; break; }; done
[ "$ok" = 1 ] || { echo "FAIL: ssh never came up"; kill "$QPID" 2>/dev/null; exit 1; }

echo "=== A: daemon supervised, no_new_privs, queue dirs ready ==="
$SSH 'kill -0 "$(cat /run/svc/snake.pid)" &&
      grep -qi "NoNewPrivs:.*1" /proc/$(cat /run/svc/snake.pid)/status &&
      [ -d /data/snake/queue ]' \
    || { echo "FAIL A: snake daemon not healthy under svc"; exit 1; }
echo "PASS A"

echo "=== B: the done-when — garbage job, no trace ==="
$SSH 'echo precious > /data/precious
      cat > /tmp/garbage.sh <<'"'"'EOF'"'"'
echo "MARKER: cwd=$(pwd)"
echo garbage > /tmp/garbage
echo garbage > /data/garbage
rm -f /data/precious
echo garbage > /run/garbage
dd if=/dev/zero of=./flood bs=1M count=10 2>/dev/null
echo "job sees /data: [$(ls /data)]"
echo "artifact payload" > "$ARTIFACTS/report.txt"
EOF
      cp /proc/mounts /tmp/mounts.before'
BOUT="$($SSH 'zurvan-snake run /tmp/garbage.sh 2>/tmp/snake.err; echo RC=$?')"
echo "$BOUT" | sed 's/^/  /'
echo "$BOUT" | grep -q '^MARKER: cwd=/tmp/job$'      || { echo "FAIL B: no marker / wrong cwd"; exit 1; }
# The job sees exactly its own tmpfs write — and NOT the real "precious":
echo "$BOUT" | grep -q 'job sees /data: \[garbage\]'  || { echo "FAIL B: job saw the real /data"; exit 1; }
echo "$BOUT" | grep -q 'RC=0'                        || { echo "FAIL B: bad rc"; exit 1; }
$SSH '[ "$(cat /data/precious)" = precious ] &&
      [ ! -e /data/garbage ] && [ ! -e /tmp/garbage ] && [ ! -e /run/garbage ] &&
      [ ! -e /tmp/job ] &&
      cmp -s /proc/mounts /tmp/mounts.before' \
    || { echo "FAIL B: the job left a trace on the host"; exit 1; }
$SSH 'r=$(ls -d /data/snake/results/garbage.sh-* | tail -1)
      grep -q "artifact payload" "$r/artifacts/report.txt" && grep -q "^exit=0$" "$r/status"' \
    || { echo "FAIL B: results/artifacts missing"; exit 1; }
echo "PASS B"

echo "=== C: exit codes + timeout ==="
RC7="$($SSH 'printf "exit 7\n" > /tmp/rc.sh; zurvan-snake run /tmp/rc.sh >/dev/null 2>&1; echo $?')"
[ "$RC7" = 7 ] || { echo "FAIL C: exit code $RC7 (want 7)"; exit 1; }
CT="$($SSH 'printf "sleep 60 &\nsleep 60\n" > /tmp/slow.sh
      t0=$(date +%s); zurvan-snake run --timeout 3 /tmp/slow.sh >/dev/null 2>&1; rc=$?
      echo "rc=$rc dt=$(( $(date +%s) - t0 ))"')"
echo "  $CT"
echo "$CT" | grep -q 'rc=124' || { echo "FAIL C: no timeout rc"; exit 1; }
DT="$(echo "$CT" | sed 's/.*dt=//')"
[ "$DT" -le 10 ] || { echo "FAIL C: timeout took ${DT}s"; exit 1; }
$SSH 'ps | grep -v grep | grep -q "sleep 60" && exit 1 || exit 0' \
    || { echo "FAIL C: job tree survived the timeout"; exit 1; }
echo "PASS C"

echo "=== D: the queue ==="
$SSH 'printf "echo QUEUE-RAN\necho qart > \"\$ARTIFACTS/q.txt\"\nexit 3\n" > /data/snake/queue/qjob'
ok=0
for _ in $(seq 1 15); do
    sleep 2
    $SSH 'ls /data/snake/results/qjob-*/status >/dev/null 2>&1' && { ok=1; break; }
done
[ "$ok" = 1 ] || { echo "FAIL D: queue job never finished"; exit 1; }
$SSH 'r=$(ls -d /data/snake/results/qjob-* | tail -1)
      grep -q QUEUE-RAN "$r/log" && grep -q "^exit=3$" "$r/status" &&
      grep -q qart "$r/artifacts/q.txt" && [ -f "$r/job" ] &&
      [ ! -e /data/snake/queue/qjob ]' \
    || { echo "FAIL D: queue results wrong"; exit 1; }
echo "PASS D"

$SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
echo "MILESTONE 5 DONE-WHEN: PASS"
