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

In order:

1. **Kernel cmdline** — `zurvan.config=/path/to/zurvan.yaml`, parsed from `/proc/cmdline`.
2. **The persistent disk** — `/data/zurvan.yaml`, when `rc.init` mounted a `ZURVAN-DATA`
   partition (v2). `zurvan-install` seeds this copy; after that, *this file is the box*.
3. **Baked into the image** — `/etc/zurvan.yaml` (ships as [`example.yaml`](example.yaml)).

## How it runs

`/etc/rc.init` (run by the C PID 1) invokes the provisioner once per boot, guarded by a
marker file. The marker lives on the RAM root **on purpose**: the root is reborn on every
boot, so the YAML is reapplied fresh each time — a Zurvan box's configuration is always
`image + one YAML`, never accumulated state. Idempotency makes reapplication safe.

With a persistent `/data`, the `ssh` service also moves dropbear's host keys there
(via an `/etc/dropbear` symlink), so the box keeps one SSH fingerprint for life while
the OS stays disposable.

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
