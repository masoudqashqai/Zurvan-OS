# Zurvan

> A minimal Linux distribution assembled from scratch — kernel, static userland, a
> custom PID 1, SSH, and a first-boot YAML provisioner — that boots entirely from RAM
> and self-configures from a single file.

<p align="center">
  <a href="https://github.com/masoudqashqai/Zurvan-OS/releases/latest/download/zurvan.iso">
    <img src="https://img.shields.io/badge/%E2%AC%87%EF%B8%8F%20DOWNLOAD-zurvan.iso%20(23%20MB)-2ea44f?style=for-the-badge&logo=linux&logoColor=white" alt="Download zurvan.iso">
  </a>
  &nbsp;
  <a href="https://github.com/masoudqashqai/Zurvan-OS/releases/latest">
    <img src="https://img.shields.io/github/v/release/masoudqashqai/Zurvan-OS?style=for-the-badge&label=RELEASE" alt="Latest release">
  </a>
</p>


Zurvan is a from-source Linux system, not a rebranded distribution. Every layer is
assembled directly in this repository: the kernel is configured and built from source,
the userland is statically linked (no dynamic loader ships at all), the init process is
~200 lines of C you can read top to bottom, and networking is brought up explicitly.

Named for the Zoroastrian principle of boundless time — the father of twin opposites —
the design follows the metaphor: the **source is timeless**, a reproducible image defined
entirely by this repository, while each **running instance is ephemeral**, booting from
RAM, configuring itself from one YAML file, and vanishing without a trace on shutdown.
The disk is never touched.

v2 (planned in [`ROADMAP.md`](ROADMAP.md)) gives Zurvan its twins. The **snake** is the
OS itself, shedding its skin on every boot — reborn identical, never drifting, exactly as
above. The **lion** is what endures: one persistent `/data` partition holding the YAML,
installed apps, and service state, guarded by a snapshot daemon. The OS is never
installed — only the data is — so a two-year-old Zurvan server stays provably identical
to the day it was set up.

---

## Download & run

**[⬇️ zurvan.iso — direct download](https://github.com/masoudqashqai/Zurvan-OS/releases/latest/download/zurvan.iso)**
(≈23 MB; the [release page](https://github.com/masoudqashqai/Zurvan-OS/releases/latest) has the SHA-256 checksum).

**VMware Workstation**
1. *Create a New Virtual Machine* → *I will install the operating system later*
2. Guest OS: **Linux → Other Linux 6.x kernel 64-bit**
3. Attach `zurvan.iso` to the CD/DVD drive → power on

**QEMU**
```sh
qemu-system-x86_64 -cdrom zurvan.iso -m 256               # VGA window
qemu-system-x86_64 -cdrom zurvan.iso -m 256 -nographic    # serial; pick the 2nd menu entry
```

GRUB boots hands-off after 3 seconds. You land at a root `bash` prompt with the
hostname, network, users, and services already applied from the built-in
`/etc/zurvan.yaml`. Reboot and it happens again, identically — clean state every time.

---

## What's inside

| Layer | Implementation |
|-------|----------------|
| **Kernel** | Linux 6.6 LTS, built from source; `defconfig` + a [readable fragment](kernel/config-fragment) of the symbols the boot path needs |
| **Userland** | [busybox](userland/build-busybox.sh) (static — `sh`, `ls`, `ip`, `udhcpc`, `vi`, …), [bash](userland/build-bash.sh) (static), [dropbear](userland/build-dropbear.sh) (static — `sshd`, `ssh`, `scp`) |
| **Init (PID 1)** | [~200 lines of C](init/init.c): mounts, console, an rc hook, shell supervision, zombie reaping — and it never exits |
| **Networking** | `udhcpc` DHCP + DNS via a [small hook script](rootfs/etc/udhcpc/default.script) |
| **Provisioner** | [`zurvan-provision`](packages/provisioner/) — the signature feature, see below |
| **Packaging** | initramfs (`cpio.gz`) for QEMU direct-boot; GRUB ISO for VMs and BIOS machines |

### The signature feature: first-boot provisioning from one YAML

On every boot (every boot is a first boot), PID 1's rc hook runs the provisioner, which
reads **one YAML file** and configures the system:

```yaml
hostname: zurvan-box

network:
  eth0:
    dhcp: false
    address: 10.0.2.50/24
    gateway: 10.0.2.2
    dns:
      - 10.0.2.3

users:
  - name: zurvan
    shell: /bin/bash
    authorized_keys:
      - "ssh-ed25519 AAAA... your-key"

services:
  - networking
  - ssh
```

The config comes from `/etc/zurvan.yaml` inside the image, or any path given as
`zurvan.config=<path>` on the kernel cmdline. The implementation is deliberately
bounded — busybox `sh` + `awk`, a fixed set of keys, a tiny YAML subset, every action
idempotent. Details in [`packages/provisioner/`](packages/provisioner/).

To SSH into the box, put your public key in
[`packages/provisioner/example.yaml`](packages/provisioner/example.yaml) and rebuild the
image (`make rootfs iso`) — dropbear generates host keys on first connection, so there
is no key ceremony.

---

## Building from source

Everything builds on any reasonably current Linux with a C toolchain. Debian/Ubuntu
prerequisites:

```sh
apt install build-essential flex bison libssl-dev libelf-dev bc cpio curl xz-utils \
            qemu-system-x86 grub-pc-bin xorriso mtools
```

Then, from the repo root:

```sh
make help          # list targets
make kernel        # fetch + configure + build the kernel   (~30 min first time)
make userland      # static busybox, bash, dropbear
make init          # compile the C PID 1
make rootfs        # assemble and pack rootfs.cpio.gz
make run           # boot it in QEMU -nographic  (exit: Ctrl-A X)
make iso           # produce build/zurvan.iso
```

Useful environment variables:

| Variable | Purpose |
|----------|---------|
| `ZURVAN_SRC_BASE` | where kernel/userland source trees live — **on WSL, point this at the Linux filesystem** (e.g. `/root/zurvan-src`); building on `/mnt/*` is ~10× slower |
| `KMIRROR` | alternate kernel download base if `cdn.kernel.org` is unreachable, e.g. `https://mirrors.tuna.tsinghua.edu.cn/kernel` |
| `KVER`, `BBVER`, `BASHVER`, `DBVER` | pin different component versions |
| `USE_C_INIT=0` | build the rootfs with the throwaway shell `/init` instead of the C PID 1 (milestone 2 mode) |

**Windows:** build under WSL2 (Ubuntu). Clone anywhere, but set `ZURVAN_SRC_BASE` as
above. The repo enforces LF line endings via `.gitattributes` — a CRLF shell script
inside the image would break the boot chain.

---

## Repository layout

```
kernel/      config fragment + build script
userland/    busybox, bash, dropbear build scripts (all static)
init/        PID 1 source (C) + Makefile
rootfs/      skeleton /etc, rc.init, udhcpc hook
packages/    the first-boot provisioner (signature feature)
scripts/     rootfs assembly, QEMU runner, ISO builder
Makefile     top-level orchestration: kernel → userland → init → rootfs → run/iso
ROADMAP.md   deliberately deferred features
```

## Design principles

- **Bounded scope.** Each piece does one thing and is small enough to read whole. The
  provisioner parses a YAML *subset*; the init supervises *one* shell; features that
  don't fit are in [`ROADMAP.md`](ROADMAP.md), not half-implemented here.
- **Verified, not assumed.** Every layer was brought up bottom-up with an observable
  check: the kernel's no-init panic, the busybox prompt, `/proc/1/comm`, a DHCP lease,
  a DNS lookup, an SSH session on `/dev/pts/0`.
- **The parts worth understanding are the parts you must touch.** Kernel config and
  PID 1 behavior fail without friendly errors — both are kept small and documented so
  they can be reasoned about rather than trusted.

## Roadmap

The road to v2 is sequenced in [`ROADMAP.md`](ROADMAP.md) as five bounded milestones:
a persistent `/data` partition with installable static packages (the memory box), a
tiny declarative service supervisor, **lion** (a snapshot daemon guarding `/data`),
**snake** (a job runner in evaporating tmpfs sandboxes), and an optional web admin
panel. Beyond v2: overlayfs-enforced immutable root, image/container duality, and A/B
image slots.

## License

[MIT](LICENSE). The components Zurvan builds from source (Linux, busybox, bash,
dropbear) keep their own upstream licenses.
