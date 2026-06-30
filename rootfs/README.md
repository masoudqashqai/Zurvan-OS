# rootfs/

The skeleton root filesystem — the static parts that are checked into git. The build
(`scripts/build.sh`) copies this tree into `build/rootfs/`, drops in the built busybox,
bash, and C init, creates device nodes / applet symlinks, and packs it into
`rootfs.cpio.gz`.

## What's here

```
init.sh                 trivial shell /init for milestone 2 (boot to a busybox shell)
etc/hostname            default hostname (provisioner can override on first boot)
etc/passwd, etc/group   minimal root user/group so the shell has an identity
etc/resolv.conf         placeholder; udhcpc rewrites this when DHCP comes up
etc/rc.init             run once by the C PID 1: brings up networking (milestone 5)
etc/udhcpc/default.script   udhcpc hook: applies the DHCP lease (IP, route, DNS)
```

## Two phases of `/init`

- **Milestone 2:** the rootfs ships `init.sh` *as* `/init` — a trivial script that mounts
  the basics and `exec`s a shell, just to prove the rootfs boots.
- **Milestone 3 onward:** the C PID 1 (`init/init`) becomes `/init`. From then on
  `init.sh` is only kept for reference; the C init runs `/etc/rc.init` for the rest.

`scripts/build.sh` decides which one to install (see the `USE_C_INIT` switch there).

## Networking (`etc/rc.init` + `etc/udhcpc/default.script`)

QEMU's user-mode network hands out a `10.0.2.0/24` lease over DHCP and forwards DNS.
`rc.init` brings up `lo` and `eth0`, then runs `udhcpc -i eth0`; busybox's `udhcpc` calls
`default.script` with the lease, which sets the IP/route and writes `/etc/resolv.conf`.
