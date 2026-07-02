# kernel/

Build the Linux kernel from source for the QEMU / initramfs boot path.

> ⚠️ **This is one of the two parts to reason about yourself** (the other is the C PID 1).
> A subtly wrong config doesn't give a friendly error — it panics, or hangs with a blank
> serial console, and you're left guessing. Drive `menuconfig` by hand; don't blindly
> trust a generated config.

## Approach

Start from `make defconfig` (a sane x86_64 baseline), then make sure the handful of
options the initramfs + QEMU path needs are enabled, and only later iterate toward a
smaller config.

## Required config for the QEMU / initramfs path

See [`config-fragment`](config-fragment) for the exact symbols. The essentials:

- **`CONFIG_BLK_DEV_INITRD`** — lets the kernel unpack our `rootfs.cpio.gz` into RAM and
  run `/init`. Without this, there's no rootfs.
- **8250 serial console** (`CONFIG_SERIAL_8250` + `_CONSOLE`) — so `-nographic` works and
  you actually see boot output. Boot with `console=ttyS0` on the cmdline.
- **`CONFIG_DEVTMPFS`** (+ `_MOUNT`) — kernel-populated `/dev` so init has device nodes.
- **virtio** — `CONFIG_VIRTIO_PCI`, `CONFIG_VIRTIO_NET` for networking under QEMU.

Navigate these with `make menuconfig`.

## Usage

```sh
kernel/build.sh            # uses a pinned default version
KVER=6.6.143 kernel/build.sh  # or pick your own
```

Useful env vars (see `build.sh`): `ZURVAN_SRC_BASE` moves the source/build tree off
the repo (essential under WSL — build on ext4, not /mnt/*), `KMIRROR` switches the
download base when cdn.kernel.org is unreachable
(e.g. `https://mirrors.tuna.tsinghua.edu.cn/kernel`).

Output: `kernel/build/bzImage`.

## Milestone 1 check

A kernel that **boots to a panic** in QEMU with no init is success at this stage — it
proves the config and serial console work:

```sh
qemu-system-x86_64 -kernel kernel/build/bzImage -nographic -append "console=ttyS0"
# expect: "Kernel panic - not syncing: No working init found." over serial
```
