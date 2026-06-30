# Roadmap

Things deliberately kept **out of v1** to keep scope bounded. Each is a genuinely good
learning project on its own — and a rabbit hole if pulled into the first build. They live
here so they don't quietly creep into the v1 spine.

The rule: v1 is *boots → shell → networking → self-configures from one YAML*. Anything
below waits until that works end-to-end.

---

## Right after the headline feature

### Stretch: immutable read-only root + tmpfs overlay
- Root filesystem mounted read-only, with a tmpfs overlay (overlayfs) on top.
- Reboot returns the system to a clean state.
- Pairs naturally with the first-boot provisioner: **clean root + YAML config =
  reproducible boxes.**
- This is the first thing to attempt once the provisioner works.

---

## Deferred — own infrastructure (great learning, real rabbit holes)

### Declarative service / init manager
- Dependency-ordered supervision of services (think a tiny systemd-shaped thing).
- Big learning payoff in process supervision, dependency graphs, and socket activation.
- Out of v1: the C PID 1 only needs to mount, set up console, supervise a shell, and reap
  zombies. Don't grow it into a service manager yet.

### Simple package manager
- Tarballs + a manifest + install hooks.
- Teaches dependency resolution, install/remove transactions, and rollback.
- Out of v1: userland is assembled by build scripts, not "installed."

---

## Deferred — distribution shape

### Image / container duality
- One rootfs that produces both a bootable image **and** an OCI container.
- Demonstrates that the rootfs is the single source of truth.

### Graduate to a real distro (off-initramfs)
The v1 path boots entirely from an initramfs in RAM. To run on real hardware / a VM with
persistence:

- Write the rootfs to an **ext4** image.
- Add **GRUB** (`grub-mkrescue` for a bootable ISO).
- Boots on real hardware or a VM, with a persistent disk.
- `scripts/make-iso.sh` is scaffolded for this step but is **not** part of v1.

---

## Explicitly *not* changing in v1

- No bootloader, no disk image, no GRUB — initramfs in QEMU only.
- No dynamic loader / shared libs to ship — static busybox + bash.
- PID 1 stays a small, reason-about-able supervising loop.
