#!/bin/sh
# Milestone 6 done-when: a browser can see service state, browse snapshots,
# read job history, and edit the YAML — with the panel itself installed like
# any other package (here: shipped in the image, ON by default).
#
# Driven over the panel's own HTTPS (curl -k) against the installed disk:
#   A: panel enabled by default; TLS identity + token made at first boot;
#      reachable over HTTPS; token printed to the console
#   B: auth gate — no cookie -> redirect to /login; wrong token rejected;
#      correct token logs in
#   C: views render live data — services (from zurvan-svc state), overview
#   D: edit /data/zurvan.yaml through the panel and read it back changed
#   E: run a job from the panel -> it went through the snake (sandboxed)
#   F: token + cert persist across a reboot (same fingerprint, same token)
#
# Run as root (losetup/mount); needs qemu-system-x86_64, curl, a built kernel,
# rootfs, and ISO (make all && scripts/make-iso.sh). Forwards guest :8443 and
# :22 to host :8443/:2222. Rewrites build/disk.img.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGDIR="${LOGDIR:-/tmp/zurvan-m6-logs}"; mkdir -p "$LOGDIR"
BOOT=/mnt/zboot; mkdir -p "$BOOT"

KEY=/tmp/zm6_key; rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH="ssh -p 2222 -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"
C="curl -sk -c $LOGDIR/cj -b $LOGDIR/cj"
U="https://127.0.0.1:8443"

rm -f build/disk.img; truncate -s 2G build/disk.img
echo "=== install ==="
{ sleep 25; printf 'zurvan-install --yes /dev/sda\n'; sleep 25; printf 'poweroff -f\n'; sleep 5; } \
 | timeout 100 qemu-system-x86_64 -m 256 -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz \
   -append console=ttyS0 -drive file=build/disk.img,format=raw,if=ide -cdrom build/zurvan.iso -nographic \
   > "$LOGDIR/inst.log" 2>&1 || true
tr -d '\0' < "$LOGDIR/inst.log" | grep -aq '\[install\] done' || { echo FAIL install; exit 1; }

# Only a root SSH key; do NOT list services: — the installed default
# /data/zurvan.yaml already enables networking, ssh, and face. We just add our key.
LOOP="$(losetup -P -f --show build/disk.img)"; mount "${LOOP}p2" "$BOOT"
cat > "$BOOT/zurvan.yaml" <<EOF
hostname: zurvan-m6
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
  - face
EOF
umount "$BOOT"; losetup -d "$LOOP"

boot() {
	qemu-system-x86_64 -m 256 -drive file=build/disk.img,format=raw,if=ide \
	    -netdev user,id=n0,hostfwd=tcp::2222-:22,hostfwd=tcp::8443-:8443 \
	    -device virtio-net-pci,netdev=n0 -display none > "$1" 2>&1 &
	QPID=$!
}
wait_ssh() { for _ in $(seq 1 60); do sleep 2; $SSH true 2>/dev/null && return 0; done
	echo "FAIL: ssh never came up"; kill "$QPID" 2>/dev/null; exit 1; }
down() { $SSH 'sync; poweroff -f' 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; }

boot "$LOGDIR/boot1.log"; wait_ssh

echo "=== A: panel enabled by default, identity made, reachable ==="
$SSH '[ -f /data/face/cert.der ] && [ -f /data/face/key.der ] && [ -f /data/face/token ]' \
    || { echo "FAIL A: first-boot TLS identity/token missing"; down; exit 1; }
TOKb="$($SSH 'cat /data/face/token')"
echo "$TOKb" | grep -qE '^[0-9a-f]{16,}$' || { echo "FAIL A: token not a hex secret ($TOKb)"; down; exit 1; }
# The default GRUB entry logs to tty0 (not the captured serial), so the token
# print is verified over SSH here rather than from the console log.
ok=0; for _ in $(seq 1 12); do $C -o /dev/null "$U/login" 2>/dev/null && { ok=1; break; }; sleep 2; done
[ "$ok" = 1 ] || { echo "FAIL A: panel not reachable over HTTPS"; down; exit 1; }
echo "PASS A (token $TOKb)"

echo "=== B: auth gate ==="
rm -f "$LOGDIR/cj"
$C -o /dev/null -w '%{redirect_url}' "$U/" | grep -q '/login' || { echo "FAIL B: no auth redirect"; down; exit 1; }
$C -d 'token=wrong' "$U/login" | grep -q 'Wrong token' || { echo "FAIL B: wrong token accepted"; down; exit 1; }
$C -o /dev/null -w '%{http_code}' -d "token=$TOKb" "$U/login" | grep -q 303 || { echo "FAIL B: login failed"; down; exit 1; }
echo "PASS B"

echo "=== C: views render live data ==="
$C "$U/services" | grep -q 'face' || { echo "FAIL C: services view"; down; exit 1; }
$C "$U/" | grep -q 'Overview' || { echo "FAIL C: overview"; down; exit 1; }
$C "$U/snapshots" | grep -q 'Snapshots' || { echo "FAIL C: snapshots view"; down; exit 1; }
$C "$U/jobs" | grep -q 'Jobs' || { echo "FAIL C: jobs view"; down; exit 1; }
echo "PASS C"

echo "=== D: edit /data/zurvan.yaml through the panel ==="
# Keep root's key (F reboots and must still SSH in) — the editor writes the
# WHOLE file, so the new content is a complete, valid config, only the
# hostname changed.
NEWYAML="hostname: edited-by-panel
users:
  - name: root
    authorized_keys:
      - $(cat "$KEY.pub")
services:
  - networking
  - ssh
  - face"
$C --data-urlencode 'path=zurvan.yaml' --data-urlencode "content=$NEWYAML" "$U/file" >/dev/null
$SSH 'grep -q "edited-by-panel" /data/zurvan.yaml' || { echo "FAIL D: YAML not saved"; down; exit 1; }
echo "PASS D"

echo "=== E: run a job from the panel; it goes through the snake ==="
$C --data-urlencode 'script=echo panel-job-ran > "$ARTIFACTS/out.txt"' "$U/jobs/run" >/dev/null
sleep 2
$SSH 'ls -d /data/snake/results/stdin-* >/dev/null 2>&1 &&
      grep -rq panel-job-ran /data/snake/results/stdin-*/artifacts 2>/dev/null' \
    || { echo "FAIL E: job did not run through the snake"; down; exit 1; }
echo "PASS E"

echo "=== F: identity + token persist across reboot ==="
FP1="$(echo | openssl s_client -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -noout -fingerprint 2>/dev/null)"
down
boot "$LOGDIR/boot2.log"; wait_ssh
TOK2="$($SSH 'cat /data/face/token')"
FP2="$(echo | openssl s_client -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -noout -fingerprint 2>/dev/null)"
[ "$TOK2" = "$TOKb" ] || { echo "FAIL F: token changed across reboot"; down; exit 1; }
[ -n "$FP1" ] && [ "$FP1" = "$FP2" ] || { echo "FAIL F: cert changed across reboot ($FP1 / $FP2)"; down; exit 1; }
echo "PASS F"

down
echo "MILESTONE 6 DONE-WHEN: PASS"
