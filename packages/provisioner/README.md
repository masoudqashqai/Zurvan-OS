# packages/provisioner — first-boot provisioner ("cloud-init-lite")

**The signature feature.** On first boot, read **one YAML file** and configure the system:
hostname, network, users, and services. This is Zurvan's identity —
*"boots and self-configures from one YAML."*

> Implemented as [`zurvan-provision`](zurvan-provision) — busybox `sh` + `awk` only, no
> other dependencies, so the static-userland story stays intact. `scripts/build.sh`
> installs it at `/usr/bin/zurvan-provision` and ships `example.yaml` as the default
> `/etc/zurvan.yaml`.

## Bounded by design

The whole point is to stay small: **parse a file, run a defined set of actions.** Not a
general config-management system. The supported keys are fixed (see
[`example.yaml`](example.yaml)). If a feature isn't one of those keys, it doesn't belong
here — it belongs in `ROADMAP.md`.

## Where the config comes from

Two intended sources (pick one to start; cmdline is simplest under QEMU):

1. **Kernel cmdline** — `zurvan.config=/path/to/zurvan.yaml`, parsed from `/proc/cmdline`.
2. **A labeled partition** — mount by label and read a well-known filename. (Pairs with
   the immutable-root stretch goal: read-only root + a small config partition.)

## How it runs

`/etc/rc.init` (run once by the C PID 1) invokes the provisioner on first boot only,
guarded by a marker file so it doesn't re-run every boot:

```sh
if [ -x /usr/bin/zurvan-provision ] && [ ! -e /var/lib/zurvan/provisioned ]; then
    /usr/bin/zurvan-provision && : > /var/lib/zurvan/provisioned
fi
```

(That block is present, commented out, in `rootfs/etc/rc.init` — enable it once this is
built.)

## Supported actions (v1 target)

| Key        | Effect |
|------------|--------|
| `hostname` | write `/etc/hostname` + `sethostname()` |
| `network`  | static IP or `dhcp` per interface (otherwise udhcpc already ran) |
| `users`    | create users, set shells, install `authorized_keys` / passwords |
| `services` | start a defined set of services — v1 knows `networking` and `ssh` (dropbear) |

## Implementation notes

- **How it works:** an `awk` pass flattens the YAML subset into `KEY=VALUE` paths
  (`network.eth0.dns.0=10.0.2.3`, `users.0.name=zurvan`), then plain `sh` looks up
  those paths and applies each section. Two phases, both readable top to bottom.
- The YAML dialect is a **subset** by design: 2-space indentation, scalars, `- item`
  lists, nested maps. No anchors, multi-line strings, inline collections, or tabs —
  full YAML is a rabbit hole.
- Every action is **idempotent** so a re-run (or a failed first run) is safe:
  existing users are kept, `authorized_keys` and `resolv.conf` are rewritten whole,
  addresses are flushed before being re-added.
