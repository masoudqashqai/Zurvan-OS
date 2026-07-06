# Roadmap — the road to v2

v1 is done: *boots → shell → networking → self-configures from one YAML*. A 23 MB
image, everything from source, everything ephemeral, the disk never touched.

v2 keeps that promise and adds its missing half. Zurvan is named for the father of
twins — and v2 makes the system literally two opposed things at once:

- **The snake — what sheds its skin.** The OS itself. It still boots from the image
  into RAM, read-only in spirit, reborn identical on every boot. It never persists,
  never drifts, never accumulates cruft. This is v1, unchanged.
- **The lion — what endures.** One persistent ext4 partition, `/data`, holding the
  YAML, installed apps, and service state. Everything you would cry about losing
  lives there; everything else is disposable.

The OS is never installed — only the data is. A two-year-old Zurvan server is
provably identical to the day it was set up: the whole machine is described by
three things — the image version, one YAML file, and the contents of `/data`.
Upgrading is replacing one image file; rollback is keeping the old one.

**The rule stays the same as v1:** each milestone is bounded, readable whole, and
leaves the system in a working state. Nothing below starts until the milestone
before it works end-to-end.

---

## Milestone 1 — the memory box: persistent `/data` + installable apps ✅

**Done (2026-07-06).** Boot-verified end to end in QEMU: install to a blank disk from
the CD, reboot with hostname + SSH fingerprint + installed app intact, and a byte-copied
disk boots as a provably identical second server.

Give the system one notebook that survives reboot, and an official answer to
"how do I install Apache on this?"

**Persistence layer**
- Kernel fragment grows SATA/AHCI (+ virtio-blk for VMs) and ext4.
- One ext4 partition, mounted at `/data` early in the rc hook. The root filesystem
  stays RAM-backed and ephemeral — persistence is *opt-in per path*, never global.
- The provisioner reads `zurvan.yaml` from `/data` when present (the
  `zurvan.config=<path>` cmdline mechanism already exists — this is a default, not
  a new feature).
- Dropbear host keys move to `/data` so SSH fingerprints stop changing across boots.
- A small `zurvan-install` tool: partitions a disk, writes the image + GRUB, creates
  `/data`. This is the only program allowed to touch a raw disk.

**Package system (the v1 "simple package manager" item, wearing a specific hat)**
- A package is a tarball of **static binaries** plus a small manifest — built by a
  `build-<name>.sh` script in the same style as `userland/build-busybox.sh`.
  No dynamic loader ships, so packages carry their libraries inside them: one file,
  zero shared-library dependencies, no version conflicts possible.
- Installing unpacks into `/data/apps/<name>/`. Service state lives in
  `/data/srv/<name>/`. Runtime junk (pid files, sockets, tmp) stays in RAM and
  correctly evaporates.
- **The set-dresser trick:** programs expect `/usr/bin`, `/etc`, `/var/lib` — and
  the RAM root is freely writable, so at every boot the provisioner recreates
  symlinks from the standard paths into `/data` (e.g.
  `/usr/bin/slapd → /data/apps/slapd/bin/slapd`,
  `/var/lib/slapd → /data/srv/slapd`). Programs live where they expect to live and
  never know the difference. The links are rebuilt from the manifest every boot,
  so they can never rot or drift. The installer creates the same links immediately,
  so a fresh install works without a reboot.
- **Dependencies, deliberately shallow:** static linking already deleted the hard
  problem. What remains is program-needs-program (`needs: [openssl]` — one manifest
  line, resolved by a ten-line loop, typically empty) and start order (not the
  installer's job — the supervisor's, milestone 2). No dependency graphs, no
  version solving. **Rabbit-hole warning:** the moment the resolver wants to be
  clever, stop.
- Packages come from Zurvan's own **curated catalog** (own repo or `packages/`).
  The promise is not "runs any Linux software" — it is "everything in the catalog
  works perfectly and cannot break each other." The catalog grows one
  `build-<name>.sh` at a time; that is also the contribution model.

*Done when:* a box reboots and comes back with hostname, keys, and an installed
app intact — and a second identical server can be produced by copying the image,
the YAML, and `/data`.

---

## Milestone 2 — the babysitter: a declarative service supervisor

The C PID 1 supervises exactly one shell — that was the v1 boundary, and it holds.
A server needs several programs running and restarted when they die.

- A small C program (`zurvan-svc`, a few hundred lines, readable whole): reads the
  `services:` list from the YAML, starts services in dependency order, restarts
  crashed ones with backoff, reaps them, logs what it did.
- PID 1 does not grow. It supervises `zurvan-svc` the way it supervises the shell
  today; the supervisor is just another child.
- Service definitions live with the package manifest (`exec`, `after: [networking]`,
  `restart: yes`), so installing a package and adding one line to `services:` is
  the entire enable story.
- **Rabbit-hole warning:** no socket activation, no cgroups, no parallel-start
  optimizer. Dependency order + restart-on-crash is the whole feature.

*Done when:* dropbear and one installed app (e.g. slapd) run under supervision,
and killing either gets it restarted within seconds.

---

## Milestone 3 — the seal: a boot chain you can trust

M1 made the machine *three artifacts*: image + YAML + `/data`. Right now every
link in the boot chain — MBR → GRUB → kernel → image — **trusts** the previous
link; nothing **verifies** anything. Anyone who can write the disk (physical
access, the hypervisor, or root on the box) can swap the image and own the next
boot. The consistency story is already strong; this milestone makes it a
*security* story. It sits **before** the lion, the snake, and the face on
purpose: real data, arbitrary jobs, and a network-facing panel all deserve a
verified base — and the hardening switches land in the supervisor M2 just built.

The architecture makes this unusually cheap: verifying one sealed image file is
one signature check, not a million mutable files.

**Verified boot (the seal itself)**
- The build signs `bzImage`, `initrd.img`, and `grub.cfg` (GPG, detached
  signatures). `core.img` embeds the public key and sets
  `check_signatures=enforce` — GRUB refuses to load anything tampered.
- Honest residual risk, documented: on BIOS/MBR, `core.img` itself is the
  unverified root of trust. Fixing that needs firmware help:
- **UEFI boot** for the ISO and installer (ESP partition + `x86_64-efi` GRUB) —
  needed on modern hardware anyway — with **Secure Boot via user-enrolled keys**
  (VMware custom key db / physical firmware enrollment). Then the firmware
  verifies GRUB, GRUB verifies the image, and the chain is rooted in hardware.
- **Rabbit-hole warning:** no Microsoft-signed shim, no TPM sealing, no
  attestation. Enroll-your-own-key is the whole v2 story; the MS-shim path is
  a distribution problem, not an architecture problem.

**A/B image slots + `zurvan-upgrade`** (promoted from the deferred list — an
unverified upgrade path would undo the seal)
- Two image slots on the boot partition. `zurvan-upgrade <file>`: verify the
  signature *first*, write to the inactive slot (temp name + rename — a power
  cut never leaves a torn image), flip one GRUB env variable, reboot.
- A boot-success counter in grubenv: a slot that fails to boot cleanly gets
  one retry, then GRUB falls back to the good slot. Rollback is automatic.
- Upgrading is still "replacing one file" — now with a signature gate and an
  undo button.

**Enforced immutability** (promoted from the deferred list)
- The RAM root goes read-only for real: root mounted `ro` with a tmpfs overlay
  for the paths that legitimately churn. Writing anywhere permanent except
  `/data` returns `EROFS` instead of relying on good manners.

**Hardening baseline (today's table stakes, each one line to review)**
- Kernel fragment: `STACKPROTECTOR_STRONG`, `HARDENED_USERCOPY`,
  `SLAB_FREELIST_HARDENED`, no `/dev/mem`, `dmesg_restrict`, `kptr_restrict`,
  unprivileged BPF off. No modules ship at all — everything is built in, so
  the module-loading attack surface simply does not exist.
- Services run as **dedicated non-root users** with `no_new_privs` — a
  `user:` line in the service definition, applied by `zurvan-svc`.
- dropbear defaults to **key-only auth**; password login must be asked for
  explicitly in the YAML.
- *(stretch)* LUKS-encrypted `/data`, opt-in via the YAML. **Rabbit-hole
  warning:** key management on a headless box is the actual hard problem —
  passphrase-at-console only; TPM unsealing is post-v2. A hypervisor's own
  disk encryption is a legitimate answer today.

*Done when:* flipping one byte in `initrd.img` makes the box refuse to boot it
(and fall back to the good slot); a signed upgrade applied over SSH survives a
mid-write power cut; an unsigned image is rejected before touching a slot;
`touch /usr/bin/x` fails with `EROFS` while `/data` still writes; and SSH
refuses password auth unless the YAML asked for it.

---

## Milestone 4 — the lion: guardian of `/data`

A small C daemon whose only job is protecting the memory box. It runs as an
ordinary supervised service.

- Periodically snapshots `/data` — everything except its own snapshot directory
  (no snowballing) — as one compressed archive plus a manifest: timestamp, size,
  checksum. The checksum is verified before any restore is trusted.
- Configured from the YAML like everything else:

  ```yaml
  lion:
    every: 24h
    keep: 7
  ```

- Default retention is a **ring buffer**: one snapshot a day, keep the last 7,
  delete the oldest when an 8th arrives. Predictable by inspection.
  (Grandfather-father-son retention — dailies + weeklies + monthlies — is a
  post-v2 option, not a v2 feature.)
- Two non-negotiable guardrails:
  1. **Disk-space cap** — if `/data` runs low, the lion deletes its own oldest
     snapshots first. The guardian must never become the threat.
  2. **Atomicity** — snapshots are written to a temp name and renamed into place;
     a power cut mid-snapshot leaves the previous good snapshot untouched, never
     a corrupt new one. Live service data is snapshotted in a way that never
     captures a half-written file.
- `lion restore <snapshot>` puts a chosen snapshot back. For an auth server or a
  database, this is the feature that lets you sleep.

*Done when:* deleting a file from `/data`, then restoring yesterday's snapshot,
brings it back — and filling the disk makes the lion eat its own oldest snapshot
rather than fail.

---

## Milestone 5 — the snake: work that leaves no trace

The mirror twin: where the lion makes things permanent, the snake makes work
perfectly disposable.

- A small C job runner: give it a task (a script, a build, a cron-shaped job) and
  it executes in a **fresh tmpfs sandbox in its own mount namespace**, returns the
  result, and the sandbox evaporates. The host filesystem is never touched.
- Jobs arrive over SSH or from a queue directory in `/data`; results (exit status,
  captured output, declared artifacts) are the only thing that crosses back into
  the permanent world.
- This is only *safe* because of Zurvan's architecture — the OS is already
  disposable, so a messy or misbehaving job costs nothing. It is a minimal
  CI-runner / scratch-executor primitive.
- **Rabbit-hole warning:** this is not a container runtime. Mount namespace +
  tmpfs + timeout is the whole isolation story in v2; no images, no networking
  namespaces, no OCI.
- Milestones 4 and 5 are independent — build them in either order, or in parallel.

*Done when:* a job that writes garbage all over its filesystem finishes, its
output comes back, and the running system shows no trace it ever ran.

---

## Milestone 6 — the face: a web admin panel (the victory lap)

**Not necessary — and that's the point of putting it last.** Everything the panel
does is already possible over SSH with `vi` and one YAML file, so v2 can ship
after milestone 5 with nothing missing. Build this because a server's face is a
browser tab, and one screenshot of it sells the project better than any paragraph.

- One static binary serving one page over HTTPS (the seal's signing key story
  gives it a certificate story too) on `/data`-configured settings:
  services and their supervisor state, the lion's snapshots (restore button), the
  snake's job history, and an editor for `zurvan.yaml` with an "apply on reboot"
  story.
- Runs as an ordinary supervised service; can be absent from `services:` and the
  OS loses nothing.
- Make it gorgeous. By this point it has something worth showing: the lion and
  the snake, live.

*Done when:* a browser can see service state, browse snapshots, read job history,
and edit the YAML — with the panel itself installed like any other package.

---

## Sequencing

```
M1 memory box ✅ →  M2 supervisor  →  M3 seal  →  M4 lion  ─┐
                                                 M5 snake ─┴→  M6 face (optional)
```

M1–M3 are load-bearing and ordered: the seal's service hardening lands in the
supervisor, and everything after the seal — data worth stealing, arbitrary jobs,
a network-facing panel — runs on the verified base. M4 and M5 swap freely.
M6 is a victory lap.

---

## Still deferred beyond v2

- **Image / container duality** — one rootfs producing both a bootable image and
  an OCI container.
- **Grandfather-father-son snapshot retention** for the lion.
- **Microsoft-signed shim** — Secure Boot on machines where you can't enroll
  your own keys. A distribution/signing-ceremony problem, not a code problem.
- **TPM-sealed keys** — unlock an encrypted `/data` without a console
  passphrase; measured boot / attestation live here too.

(Immutable read-only root and A/B image slots used to live on this list — the
seal milestone absorbed them, since enforcement and safe upgrades are security
features once the chain is verified.)

## Explicitly *not* changing in v2

- PID 1 stays a small, reason-about-able supervising loop — the service manager
  is a separate program under it, not a graft onto it.
- No dynamic loader, no shared libs — packages are static or they are not packages.
- The OS is never installed to disk; only `/data` and the boot image live there.
  Root stays RAM-backed and ephemeral. Every boot is still a first boot.
