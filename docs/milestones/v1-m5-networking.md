---
id: v1-m5
version: v1
milestone: 5
title: "Networking — udhcpc DHCP + DNS via one hook script"
status: done
completed: 2026-07-02
commits: [54c41b8]
key_files: [rootfs/etc/udhcpc/default.script, rootfs/etc/rc.init]
verification: "QEMU user-net: 10.0.2.15/24 on eth0, default route, ping 10.0.2.2, DNS via 10.0.2.3"
---

## Goal
Bring the network up explicitly and visibly: busybox `udhcpc` obtains a lease
and a small readable hook script applies it (address, route, resolv.conf).
No network manager, no dhcpcd — the point is that the whole DHCP-to-working-
network path fits in one page.

## Done-when
DHCP lease applied, default route present, ping by IP and by name both work
in QEMU user-mode networking.

## Design decisions
- **udhcpc + a hook script** is the entire stack. The hook
  (`rootfs/etc/udhcpc/default.script`) handles `deconfig|bound|renew`:
  flush + `ip addr add $ip/$mask`, `ip route add default via $router`,
  rewrite `/etc/resolv.conf` from `$dns`.
- Started from `rc.init` (the PID 1 hook), not from init.c.
- QEMU user-mode net (`-netdev user`) chosen for tests: DHCP at 10.0.2.15,
  gateway 10.0.2.2, DNS 10.0.2.3, zero host setup, no root. virtio-net in
  QEMU; **e1000 also verified later** because it's the VMware default NIC.

## How it was built
1. Hook script written against busybox's own example.
2. `rc.init`: `udhcpc -i eth0 -s /etc/udhcpc/default.script` (+ retries).
3. Verified live in QEMU, then baked into the milestone check.

## Key files
| path | role |
|---|---|
| `rootfs/etc/udhcpc/default.script` | the entire DHCP-apply logic |
| `rootfs/etc/rc.init` | interface up + udhcpc invocation |

## Problems hit (commit 54c41b8)
- **The lease was obtained but never applied.** Root cause: busybox udhcpc
  looks for its hook at the *compiled-in* path
  `/usr/share/udhcpc/default.script` unless `-s` is given. Ours lived in
  `/etc/udhcpc/`. Fix: pass `-s /etc/udhcpc/default.script` explicitly.
- **Wrong variable for the netmask in the hook**: udhcpc exports both
  `$subnet` (dotted netmask) and `$mask` (CIDR prefix length); `ip addr add`
  wants the prefix, so use `$mask` — matching busybox's own example script.

## Verification
In-guest: `ip addr` shows 10.0.2.15/24 on eth0; `ip route` has the default;
`ping 10.0.2.2` and a DNS lookup through 10.0.2.3 both succeed.

## Deferred / rabbit holes avoided
No IPv6, no multiple-interface policy, no link-state monitoring. Static
addressing arrives with the provisioner (M6), not here.
