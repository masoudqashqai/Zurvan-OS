#!/bin/sh
# Assemble the root filesystem and pack it into build/rootfs.cpio.gz.
#
# Pulls together:
#   - the skeleton tree in rootfs/        (etc, scripts, ...)
#   - the static busybox + bash           (userland/build/)
#   - the C PID 1                          (init/init)        [USE_C_INIT=1]
#     ...or the throwaway shell /init      (rootfs/init.sh)   [USE_C_INIT=0]
#
# Output: build/rootfs.cpio.gz  (the initrd you pass to QEMU)
#
# USE_C_INIT controls the milestone:
#   USE_C_INIT=0  -> milestone 2: boot to a busybox shell via rootfs/init.sh
#   USE_C_INIT=1  -> milestone 3+: boot the C PID 1 (default)
set -eu

USE_C_INIT="${USE_C_INIT:-1}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-$HERE/build}"
ROOTFS_OUT="${ROOTFS_OUT:-$BUILD/rootfs}"
INITRD="${INITRD:-$BUILD/rootfs.cpio.gz}"

BUSYBOX="$HERE/userland/build/busybox"
BASH_BIN="$HERE/userland/build/bash"
INIT_BIN="$HERE/init/init"

echo ">> assembling rootfs in $ROOTFS_OUT"
rm -rf "$ROOTFS_OUT"
mkdir -p "$ROOTFS_OUT"

# --- directory skeleton -----------------------------------------------------
for d in bin sbin etc home proc sys dev tmp root run var/lib var/log var/run usr/bin usr/sbin; do
	mkdir -p "$ROOTFS_OUT/$d"
done
chmod 1777 "$ROOTFS_OUT/tmp"

# Login accounting: dropbear (and `who`) expect these to exist; glibc's
# login()/logout() error out — killing the SSH session child — without them.
: > "$ROOTFS_OUT/var/run/utmp"
: > "$ROOTFS_OUT/var/log/wtmp"

# --- skeleton /etc and friends ----------------------------------------------
cp -a "$HERE/rootfs/etc" "$ROOTFS_OUT/"
chmod +x "$ROOTFS_OUT/etc/rc.init" "$ROOTFS_OUT/etc/udhcpc/default.script"

# --- busybox + applet symlinks ----------------------------------------------
if [ ! -x "$BUSYBOX" ]; then
	echo "!! missing $BUSYBOX — run userland/build-busybox.sh first" >&2
	exit 1
fi
cp "$BUSYBOX" "$ROOTFS_OUT/bin/busybox"
# Let busybox tell us its applet list and symlink each one to itself.
"$BUSYBOX" --list-full 2>/dev/null | while read -r applet; do
	[ -n "$applet" ] || continue
	mkdir -p "$ROOTFS_OUT/$(dirname "$applet")"
	ln -sf /bin/busybox "$ROOTFS_OUT/$applet"
done
# Guarantee /bin/sh exists even if --list-full was unavailable.
[ -e "$ROOTFS_OUT/bin/sh" ] || ln -sf /bin/busybox "$ROOTFS_OUT/bin/sh"

# --- bash -------------------------------------------------------------------
if [ -x "$BASH_BIN" ]; then
	cp "$BASH_BIN" "$ROOTFS_OUT/bin/bash"
else
	echo "!! no bash at $BASH_BIN — shell will fall back to busybox sh" >&2
fi

# --- dropbear (SSH server + client) -------------------------------------------
# Multi-call binary, same pattern as busybox. Host keys are generated at first
# connection (dropbear -R) into /etc/dropbear.
DROPBEAR="$HERE/userland/build/dropbearmulti"
if [ -x "$DROPBEAR" ]; then
	cp "$DROPBEAR" "$ROOTFS_OUT/bin/dropbearmulti"
	for applet in dropbear dropbearkey scp; do
		ln -sf /bin/dropbearmulti "$ROOTFS_OUT/bin/$applet"
	done
	ln -sf /bin/dropbearmulti "$ROOTFS_OUT/bin/ssh"   # dbclient answers to "ssh"
	mkdir -p "$ROOTFS_OUT/etc/dropbear"
else
	echo "!! no dropbearmulti at $DROPBEAR — image ships without SSH" >&2
fi

# --- e2fsprogs: real ext4 mkfs/fsck for the persistent /data disk ------------
# Overwrites the busybox applet links at the same paths (busybox mke2fs is
# ext2-only). Best-effort: a RAM-only image still boots without them.
for tool in mke2fs e2fsck; do
	if [ -x "$HERE/userland/build/$tool" ]; then
		rm -f "$ROOTFS_OUT/sbin/$tool"
		cp "$HERE/userland/build/$tool" "$ROOTFS_OUT/sbin/$tool"
	else
		echo "!! no $tool at userland/build/$tool — image ships busybox's ext2-only one" >&2
	fi
done
ln -sf mke2fs "$ROOTFS_OUT/sbin/mkfs.ext4"
ln -sf e2fsck "$ROOTFS_OUT/sbin/fsck.ext4"
[ -f "$HERE/userland/build/mke2fs.conf" ] && cp "$HERE/userland/build/mke2fs.conf" "$ROOTFS_OUT/etc/mke2fs.conf"

# --- first-boot provisioner (the signature feature) --------------------------
cp "$HERE/packages/provisioner/zurvan-provision" "$ROOTFS_OUT/usr/bin/zurvan-provision"
chmod +x "$ROOTFS_OUT/usr/bin/zurvan-provision"
# Ship the example config as the default /etc/zurvan.yaml; a different file can
# be pointed at via zurvan.config=<path> on the kernel cmdline.
cp "$HERE/packages/provisioner/example.yaml" "$ROOTFS_OUT/etc/zurvan.yaml"

# --- zurvan-install: disk installer (v2 milestone 1) --------------------------
cp "$HERE/packages/installer/zurvan-install" "$ROOTFS_OUT/sbin/zurvan-install"
chmod +x "$ROOTFS_OUT/sbin/zurvan-install"

# --- zurvan-pkg: package tool + boot-time set-dresser (v2 milestone 1) --------
cp "$HERE/packages/pkgtool/zurvan-pkg" "$ROOTFS_OUT/sbin/zurvan-pkg"
chmod +x "$ROOTFS_OUT/sbin/zurvan-pkg"

# --- the seal: upgrade tooling + signing public key (v2 milestone 3) -----------
for tool in zurvan-grubenv zurvan-upgrade; do
	cp "$HERE/packages/upgrade/$tool" "$ROOTFS_OUT/sbin/$tool"
	chmod +x "$ROOTFS_OUT/sbin/$tool"
done
# Static gpgv: zurvan-upgrade verifies bundles with the SAME signatures GRUB
# checks at boot, so an unsigned image is rejected before touching a slot.
if [ -x "$HERE/userland/build/gpgv" ]; then
	cp "$HERE/userland/build/gpgv" "$ROOTFS_OUT/usr/bin/gpgv"
else
	echo "!! no static gpgv (userland/build-gpgv.sh) — upgrades can't be verified on-box" >&2
fi
# The PUBLIC key rides in the image so the box can verify upgrade bundles.
if [ -f "$HERE/keys/zurvan-signing.pub" ]; then
	cp "$HERE/keys/zurvan-signing.pub" "$ROOTFS_OUT/etc/zurvan-signing.pub"
else
	echo "!! no keys/zurvan-signing.pub — image can't verify upgrades (run scripts/make-keys.sh)" >&2
fi

# --- zurvan-svc: the service supervisor (v2 milestone 2) -----------------------
SVC_BIN="$HERE/svc/zurvan-svc"
if [ ! -x "$SVC_BIN" ]; then
	echo "!! missing $SVC_BIN — run 'make init' first" >&2
	exit 1
fi
cp "$SVC_BIN" "$ROOTFS_OUT/sbin/zurvan-svc"

# --- zurvan-lion: the /data snapshot daemon (v2 milestone 4) --------------------
LION_BIN="$HERE/lion/zurvan-lion"
if [ -x "$LION_BIN" ]; then
	cp "$LION_BIN" "$ROOTFS_OUT/sbin/zurvan-lion"
else
	echo "!! no zurvan-lion at $LION_BIN — image ships without the snapshot daemon" >&2
fi

# --- zurvan-snake: the disposable job runner (v2 milestone 5) -------------------
SNAKE_BIN="$HERE/snake/zurvan-snake"
if [ -x "$SNAKE_BIN" ]; then
	cp "$SNAKE_BIN" "$ROOTFS_OUT/sbin/zurvan-snake"
else
	echo "!! no zurvan-snake at $SNAKE_BIN — image ships without the job runner" >&2
fi

# --- /init ------------------------------------------------------------------
if [ "$USE_C_INIT" = "1" ]; then
	if [ ! -x "$INIT_BIN" ]; then
		echo "!! missing $INIT_BIN — run 'make -C init' first" >&2
		exit 1
	fi
	cp "$INIT_BIN" "$ROOTFS_OUT/init"
	echo ">> /init = C PID 1"
else
	cp "$HERE/rootfs/init.sh" "$ROOTFS_OUT/init"
	echo ">> /init = throwaway shell (milestone 2)"
fi
chmod +x "$ROOTFS_OUT/init"

# --- a couple of device nodes (devtmpfs fills the rest at boot) -------------
# Created best-effort; needs root/fakeroot. Not fatal if it fails — the kernel's
# devtmpfs provides /dev/console and /dev/null once it mounts.
mknod -m 600 "$ROOTFS_OUT/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "$ROOTFS_OUT/dev/null"    c 1 3 2>/dev/null || true

# --- pack -------------------------------------------------------------------
# Pack from a native-filesystem staging copy: when build/ lives on a Windows
# mount (WSL drvfs) every file is uid 1000 with mode 777, and that leaks into
# the archive — dropbear then rejects authorized_keys under a home the user
# doesn't own. Root-owned, go-w files are what an OS image should be anyway.
mkdir -p "$BUILD"
echo ">> packing $INITRD"
PACK="$(mktemp -d)"
cp -a "$ROOTFS_OUT/." "$PACK/"
if [ "$(id -u)" = 0 ]; then
	chown -R 0:0 "$PACK"
else
	echo "!! not root — archive keeps uid $(id -u); SSH into baked-in users may fail" >&2
fi
chmod -R go-w "$PACK"
chmod 1777 "$PACK/tmp"
chmod 700  "$PACK/root"
( cd "$PACK" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$INITRD"
rm -rf "$PACK"

echo ">> done: $INITRD"
ls -lh "$INITRD"
