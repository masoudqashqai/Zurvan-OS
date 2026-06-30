# Zurvan

> A minimal Linux distribution built **from scratch in a git repo** — kernel, userland,
> a hand-written PID 1, and networking, assembled one layer at a time.

Zurvan is a learning project, not a rebranded distro. The point is to assemble each
layer myself: configure and build the kernel, ship a static userland, write an init
process in C, and bring up networking — then add one signature feature that gives the
system its identity.

The whole thing boots as an **initramfs in QEMU** — no bootloader, no disk image, no
GRUB to start with. The kernel unpacks the root filesystem into RAM and runs `/init`.
Feedback loop is measured in seconds.

```
qemu-system-x86_64 -kernel kernel/build/bzImage -initrd build/rootfs.cpio.gz -nographic
```

---

## The name

**Zurvan** is the Zoroastrian deity of infinite, boundless time. In the Zurvanite myth,
the twins **Ohrmazd** (good) and **Ahriman** (evil) are both born of Zurvan — time as the
neutral source from which the dual principles emerge.

That maps onto how the system is built:

- **Infinite time** → the immutable source image: the thing in this repo, reproducible.
- **Allotted time** → the ephemeral running instance: what actually boots, configures
  itself, and eventually reboots back to a clean state.

Any lion/dragon branding that shows up later is a *representation* of the Ohrmazd/Ahriman
twins born of Zurvan — a visual nod to the myth, not a literal retelling of it.

> **Namespace note:** the name (GitHub org, package name, web collisions) has **not** been
> checked for conflicts yet. Verify before publishing anywhere public.

---

## Scope

Deliberately bounded. v1 is a system that:

1. Boots a kernel built from source.
2. Drops into a real shell (busybox **and** bash).
3. Does basic networking (DHCP + DNS in QEMU's user-mode network).
4. Self-configures on first boot from a single YAML file — the signature feature.

Target effort is a weekend to a few weekends, not an open-ended mega-project. Anything
that smells like a rabbit hole (own service manager, own package manager, container
duality) is **explicitly deferred** to [`ROADMAP.md`](ROADMAP.md).

---

## The v1 spine

| Layer | What | Notes |
|-------|------|-------|
| **Kernel** | Built from source, `make defconfig` to start | Needs initramfs, 8250 serial console, devtmpfs, virtio net/pci. See [`kernel/`](kernel/). |
| **Userland** | busybox, **statically linked**, + bash on top | One binary gives `sh`, `ls`, `mount`, `ip`, `udhcpc`, `vi`, … See [`userland/`](userland/). |
| **Init / PID 1** | Custom, written in C | Mounts `/proc` `/sys` `/dev`, sets up console, supervises a shell, **reaps zombies, never exits**. See [`init/`](init/). |
| **Networking** | QEMU user-mode net + `udhcpc` | 10.0.2.0/24 with DHCP + DNS forwarding. See [`rootfs/etc/udhcpc/`](rootfs/etc/udhcpc/). |
| **Packaging** | `cpio.gz` the rootfs, boot in QEMU | See [`scripts/`](scripts/). |

### Signature feature — first-boot provisioner ("cloud-init-lite")

On boot, read **one YAML file** (from the kernel cmdline or a labeled partition) and
configure hostname, network, users, and services. Bounded: parse a file, run a defined
set of actions. This is the distro's identity — *"boots and self-configures from one
YAML."* Scaffold lives in [`packages/provisioner/`](packages/provisioner/).

### Stretch — immutable root + tmpfs overlay

Read-only root with a tmpfs overlay via overlayfs, so reboot = clean state. Pairs
naturally with the provisioner: clean root + YAML = reproducible boxes. Deferred until the
headline feature works; tracked in [`ROADMAP.md`](ROADMAP.md).

---

## Repo layout

```
kernel/      kernel config fragment + build script
userland/    busybox config + build scripts (busybox, bash)
init/        PID 1 source (C) + build
rootfs/      skeleton /etc, /dev rules, udhcpc default.script
scripts/     build.sh, run-qemu.sh, make-iso.sh
packages/    signature-feature code (first-boot provisioner)
Makefile     top-level orchestration
ROADMAP.md   explicitly deferred features
```

---

## Build & run

> ⚠️ Nothing has been booted or tested yet — these are the intended entry points wired up
> during project init. Treat the build scripts as starting points to read and adapt, not
> a turnkey pipeline. **Kernel config and PID 1 logic are the parts to reason about
> yourself** — a subtly wrong config or a bad init just panics with no useful message.

```sh
make help          # list targets
make kernel        # fetch + configure + build the kernel  (kernel/build.sh)
make userland      # build static busybox, then bash       (userland/*.sh)
make init          # compile the C PID 1                    (init/)
make rootfs        # assemble rootfs/ + pack rootfs.cpio.gz (scripts/build.sh)
make run           # boot the result in QEMU -nographic     (scripts/run-qemu.sh)
```

To leave a `-nographic` QEMU session: `Ctrl-A` then `X`.

---

## Milestones (suggested order of work)

The boot chain is built bottom-up, confirming each layer before adding the next:

1. **Kernel boots to a panic** in QEMU (no init yet) — confirms config + serial console.
2. **Static busybox rootfs** with a trivial `/init` shell script → boot to a busybox shell.
3. **C PID 1** replaces `/init` — mounts, console, reaping, exec shell.
4. **bash** added to the rootfs.
5. **Networking** — `udhcpc` + `default.script`, confirm DHCP + DNS in QEMU.
6. **First-boot YAML provisioner** — the signature feature.
7. *(Stretch)* immutable root + overlay.

The current state of the repo is **step 0**: project skeleton, scripts, and docs in
place. No layer has been built or booted yet.

---

## Who this is for

Built by someone with 10+ years of hands-on Linux infrastructure work (≈ LPIC-1 level),
comfortable in bash, filesystems, and networking — and deliberately learning the parts
that are new: kernel config internals, toolchain bootstrapping, and writing a PID 1.
Explanations in this repo lean toward those new areas.

## License

TBD before publishing.
