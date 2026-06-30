#!/bin/sh
# Milestone 2 /init — trivial shell init, just enough to boot to a busybox shell.
#
# This proves the rootfs unpacks and runs. It is NOT a real PID 1: a shell script
# that exec's a shell does not reap zombies, and if the shell exits the kernel
# panics. Milestone 3 replaces this with the C PID 1 (init/init).
#
# Installed as /init by scripts/build.sh when USE_C_INIT=0.

mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null

echo
echo "  Zurvan — milestone 2: busybox shell."
echo "  (this is the throwaway shell /init; the C PID 1 comes next)"
echo

# exec so the shell becomes PID 1's image. If you `exit` this shell, the kernel
# will panic — that's expected at this milestone.
exec /bin/sh
