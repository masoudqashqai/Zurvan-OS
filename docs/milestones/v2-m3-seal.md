---
id: v2-m3
version: v2
milestone: 3
title: "The seal — verified boot, A/B upgrades, read-only root, hardening"
status: done
completed: 2026-07-07
commits: [6a43764, 4abbc61, f5fe7d2, 3e2b84b, e817935]
key_files: [scripts/make-keys.sh, scripts/sign.sh, scripts/make-iso.sh, packages/upgrade/zurvan-upgrade, packages/upgrade/zurvan-grubenv, userland/build-gpgv.sh, rootfs/etc/rc.init, svc/zurvan-svc.c, kernel/config-fragment, rootfs/etc/svc/ssh.def]
verification: tests/m3-verified-boot.sh, tests/m3-ab-upgrade.sh, tests/m3-seal.sh
---

## Goal
Before this milestone every link in the boot chain (MBR → GRUB → kernel →
image) *trusted* the previous link; anyone who could write the disk owned the
next boot. The seal turns the consistency story into a security story:
signed images enforced by GRUB, upgrades gated on the same signatures with
automatic rollback, a root filesystem that is read-only for real, and a
hardening baseline. Placed *before* the lion/snake/face milestones on
purpose: real data, arbitrary jobs, and a web panel deserve a verified base.
The architecture makes it cheap — verifying one sealed image is one signature
check, not a million mutable files.

## Done-when (all verified)
Flipping one byte in initrd makes the box refuse to boot it (and fall back to
the good slot); a signed upgrade survives a mid-write power cut; an unsigned
image is rejected before touching a slot; `touch /usr/bin/x` → EROFS while
/data writes; SSH refuses password auth unless the YAML asked for it.

## Design decisions
- **GPG detached signatures + GRUB's `check_signatures=enforce`.** Build-time:
  `scripts/make-keys.sh` creates a repo-local RSA-4096 keypair (`keys/`,
  gitignored); `scripts/sign.sh` signs bzImage, initrd.img, grub.cfg, and
  **every GRUB module**. The disk's `core.img` embeds the public key, which
  flips GRUB into enforce mode for everything it subsequently loads.
- **grubenv is the one deliberately unsigned file** — it only *selects among
  already-signed slots* (active/ab_try), so tampering with it can at worst
  choose the other signed image. This is what makes A/B state mutable under
  a signature regime.
- **A/B slots** on p1: `boot/slot-a/`, `boot/slot-b/`; a fixed signed
  grub.cfg computes the trial slot from grubenv and sets `fallback=1` so a
  load failure (bad signature, missing file) falls through to the good slot
  immediately. `zurvan.slot=<x>` on the cmdline tells userspace what booted.
- **Trial-once semantics**: `zurvan-upgrade` arms `ab_try=1` (active
  unchanged). A healthy boot's rc.init commits the slot (`active=<trial>`,
  `ab_try=0`) via `zurvan-grubenv`; a failed boot never commits, and GRUB
  falls back. Rollback is automatic and free — a bad upgrade costs one reboot.
- **Verify BEFORE write, write atomically**: zurvan-upgrade unpacks the
  bundle to /tmp, checks BOTH signatures with `gpgv` against
  `/etc/zurvan-signing.pub` (a raw exported pubkey doubles as a gpgv
  keyring), and only then writes the inactive slot as `.new-*` + sync +
  rename + sync. A power cut mid-write leaves old contents or nothing —
  never a torn image the next boot would try. The bundle
  (`build/zurvan-upgrade.tar` = bzImage+initrd+.sigs) is emitted by
  make-iso.sh next to the ISO: same artifacts, same signatures, **one trust
  story for boot and upgrade**.
- **gpgv from GnuPG 1.4 on purpose**: gnupg 2.x drags five libraries even for
  a gpgv-only static build (libgpg-error, libgcrypt, libassuan, libksba,
  npth) — a static-linking rabbit hole. GnuPG 1.4.23 is one self-contained
  tarball, links `-static` cleanly, and its gpgv verifies RSA/SHA-256/512
  detached sigs made by modern gpg 2.x. Needs `-std=gnu17 -fcommon` (GCC 10+
  rejects its tentative definitions). Build: configure minimal → tolerate a
  failing full make → `make -C g10 gpgv`.
- **Read-only root, enforced at the end of rc.init**: after provisioning,
  dressing, and slot-commit have run, `mount -o remount,ro /`. The paths that
  legitimately churn get tmpfs FIRST: /run /tmp /var/run /var/log; utmp/wtmp
  recreated; `/etc/resolv.conf → /run/resolv.conf` symlink (DHCP renewals
  must keep working); diskless boxes point /etc/dropbear at /run (fresh keys,
  pre-seal behavior). Opt-out: `zurvan.rw` on the cmdline. `zurvan-pkg`
  reopens rw and **reseals via `trap seal_root EXIT INT TERM`** so no failure
  path strands the root writable; it remembers whether / was actually ro so
  a zurvan.rw boot is left alone.
- **Hardening baseline** — each item one line to review:
  - Kernel fragment: STACKPROTECTOR_STRONG, HARDENED_USERCOPY,
    FORTIFY_SOURCE, SLAB_FREELIST_HARDENED/RANDOM, KASLR
    (RANDOMIZE_BASE/MEMORY), STRICT_KERNEL_RWX, DEVMEM=n, DEVKMEM=n,
    SECURITY_DMESG_RESTRICT, LEGACY_PTYS=n, and **CONFIG_MODULES=n** — no
    loadable modules at all, so the module attack surface doesn't exist and
    a signed kernel can't be extended at runtime.
  - Runtime sysctls in rc.init: kptr_restrict=2, dmesg_restrict=1,
    unprivileged_bpf_disabled=1, bpf_jit_harden=2, yama ptrace_scope=1,
    rp_filter=1.
  - zurvan-svc: `PR_SET_NO_NEW_PRIVS` for **every** service; `user=` in a
    .def drops privileges via initgroups/setgid/setuid, **failing closed**
    (`_exit(126)`) if the user doesn't exist — a misconfigured service must
    not silently run as root. zurvan-pkg passes a manifest's `user:` through
    and chowns the /data/srv state dir.
  - SSH key-only by default: baked ssh.def runs `dropbear -F -R -s`. The
    provisioner writes a password-allowing override to `/run/svc/ssh.def`
    (which wins over /etc/svc) **only if** some YAML user has a password —
    passwords are strictly opt-in.

## How it was built
1. Roadmap first (6a43764): the milestone was *designed in writing* —
   including the rabbit-hole warnings — before any code.
2. Verified boot (4abbc61): keys → sign.sh → grub-mkimage with embedded
   pubkey → installer lays out slots + signed grub.cfg + grubenv →
   zurvan-grubenv (read/write the 1024-byte grubenv block from Linux) →
   rc.init slot-commit. Test: tests/m3-verified-boot.sh.
3. The rest (f5fe7d2): build-gpgv.sh → zurvan-upgrade → bundle emission →
   read-only root prep + seal in rc.init → hardening fragment + sysctls
   (kernel rebuilt) → svc user=/no_new_privs → key-only ssh → installer
   mount points moved under /run. Tests: m3-ab-upgrade.sh, m3-seal.sh.
4. GRUB menu timeout 3s→10s on the installed disk (menu navigable in tests).

## Key files
| path | role |
|---|---|
| `scripts/make-keys.sh`, `scripts/sign.sh` | keygen + sign-everything |
| `scripts/make-iso.sh` | signs artifacts into the ISO/install payload; emits the upgrade bundle |
| `packages/upgrade/zurvan-upgrade` | verify-then-write A/B upgrade (93 lines, commented as the spec) |
| `packages/upgrade/zurvan-grubenv` | grubenv get/set from Linux |
| `userland/build-gpgv.sh` | static gpgv from GnuPG 1.4 |
| `rootfs/etc/rc.init` | tmpfs prep, sysctls, slot-commit, the seal itself |

## Problems hit
- **THE bug of the milestone — "no module name found" at boot**: the
  signature-verifying core.img is ~85 KB, but the installer used the legacy
  partition start at sector 63, leaving a 31 KB MBR gap — core.img was
  **silently truncated** by dd. Fix: p1 starts at sector 2048 (modern
  convention exists for this exact reason), and p2 got an explicit start so
  busybox fdisk doesn't reuse the freed gap. Root-caused by bisecting
  core.img contents (scratchpad core-bisect.sh).
- **`logf` name clash**: with `_GNU_SOURCE` (needed for initgroups), glibc's
  math.h `logf(3)` collided with the supervisor's log function → renamed
  `svc_log`.
- **Installer broke under the seal it helped create**: its mount points lived
  under /mnt — on the now-frozen root. Moved to /run (tmpfs).
- **gpgv 2.x static build rabbit hole** — avoided by design (see decisions);
  GnuPG 1.4 needed only `-fcommon` for GCC 10+ common-symbol strictness.
- Empty-looking QEMU display logs during testing: with `-display none` the
  verdicts only exist on the test script's stdout — capture it (this is why
  the tests were committed and why LOGDIR defaults matter).

## Verification
- `tests/m3-verified-boot.sh`: signed boot reaches userspace; 16 flipped
  bytes in slot-a initrd → GRUB "bad signature", boot refused. PASS.
- `tests/m3-ab-upgrade.sh`: T1 wrong-key bundle (freshly generated attacker
  key) rejected with slot b untouched; T2 signed bundle → ab_try armed →
  boots slot b → commits active=b, ab_try=0; T3 upgrade then corrupt trial
  slot → falls back to good slot, active unchanged. ALL PASS. (T3 is also
  the power-cut proof: a torn trial image fails its signature and falls
  back; ground truth read offline via losetup, not trusted from the guest.)
- `tests/m3-seal.sh`: RO=EROFS, DATA=WRITABLE, /proc/mounts shows `/ … ro`,
  pkg install through the seal OK + resealed after, dmesg_restrict=1,
  kptr_restrict=2, dropbear NoNewPrivs=1, baked ssh.def has -s, no /run
  override present. PASS.

## Deferred / rabbit holes avoided
**UEFI + enroll-your-own-key Secure Boot** split out to the post-v2 list:
on BIOS/MBR, core.img itself is the unverified root of trust — documented
honestly as the residual risk; closing it needs firmware help and a
hard-to-automate key-enrollment test story. Also avoided: Microsoft-signed
shim (distribution problem), TPM sealing/attestation, LUKS /data (stretch;
headless key management is the real problem). No signature format of our
own — GRUB's GPG support defines it.
