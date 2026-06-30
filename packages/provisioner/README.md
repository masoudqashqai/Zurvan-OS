# packages/provisioner — first-boot provisioner ("cloud-init-lite")

**The signature feature.** On first boot, read **one YAML file** and configure the system:
hostname, network, users, and services. This is Zurvan's identity —
*"boots and self-configures from one YAML."*

> Build this **after** the v1 spine boots (milestone 6). The directory is scaffolded now so
> the design and config shape are pinned down; there's no implementation yet.

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
| `services` | start a defined set of services (enable/start) |

## Implementation notes

- Language is open: a small **C** program keeps the static-binary story clean and is good
  PID-1-adjacent practice; a busybox-`sh` + `awk` parser is faster to prototype. Don't pull
  in a YAML library that needs dynamic linking unless you've solved static linking for it.
- Keep YAML support to the **subset** the keys above need (scalars, simple lists/maps) —
  full YAML is a rabbit hole.
- Make every action **idempotent** so a re-run (or a failed first run) is safe.
