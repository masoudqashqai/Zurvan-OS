---
id: v1-ssh
version: v1
milestone: "post-7 addition (part of v1.0.0)"
title: "SSH — static dropbear with provisioned keys"
status: done
completed: 2026-07-02
commits: [3bd300d]
key_files: [userland/build-dropbear.sh, init/init.c, rootfs/etc/shells, packages/provisioner/zurvan-provision]
verification: "pubkey auth as the YAML-provisioned user; interactive pty session on /dev/pts/0 visible in who"
---

## Goal
Remote access, completing the "usable server" story: SSH into the box as the
user whose key the YAML provisioned. Added after milestone 7, before the
v1.0.0 release. Not in the original 7-milestone list — it earned its place
when the provisioner made key distribution trivial.

## Done-when
`ssh user@box` with the provisioned key gives both command mode and an
interactive pty session.

## Design decisions
- **dropbear over OpenSSH**: one small static `dropbearmulti` binary provides
  `dropbear` (server), `dropbearkey`, `dbclient`/`ssh`, `scp`.
  `--disable-zlib` removes the last external library.
- **Host keys generated on first connection (`dropbear -R`)** — no key
  ceremony fits a RAM boot where keys can't persist anyway. (v2 M1 moved the
  key dir to /data for a stable fingerprint; v2 M3 made auth key-only by
  default.)
- **`ssh` became a bounded provisioner service** — enabled from the YAML like
  everything else.

## How it was built
`userland/build-dropbear.sh` (static multi-binary), then the integration
fixes below, then provisioner + example.yaml wiring.

## Key files
| path | role |
|---|---|
| `userland/build-dropbear.sh` | static dropbearmulti build |
| `rootfs/etc/shells` | dropbear's shell allowlist (see problems) |
| `init/init.c` `early_mounts()` | the devpts mount SSH needs |

## Problems hit (each one is an obscure integration fact worth keeping)
- **No pty without devpts**: SSH sessions failed until init mounted `devpts`
  on `/dev/pts`. The mount must come after /dev exists.
- **bash logins rejected**: dropbear consults `/etc/shells` (via glibc); when
  the file is absent, glibc's built-in fallback list is only `sh`/`csh`, so
  `/bin/bash` users couldn't log in. Fix: ship `/etc/shells` listing bash.
- **`getpwnam` works statically** because modern glibc compiles the *files*
  NSS backend into libc — no `libnss_files.so` needed. This single fact is
  why a fully static system can still do user lookups.
- **utmp/wtmp must exist**: glibc `login()`/`logout()` want `/var/run/utmp`
  and `/var/log/wtmp`; creating them also makes busybox `who` show SSH
  sessions. (v2 M3 recreates them on tmpfs at each boot.)

## Verification
QEMU over e1000: pubkey auth as the YAML user, command mode
(`ssh box 'uname -a'`), interactive mode with `tty` = `/dev/pts/0`, session
visible in `who`. This SSH path later became the *driver* for all v2
acceptance tests (tests/ suites operate the box over `ssh -p 2222`).

## Deferred / rabbit holes avoided
No OpenSSH, no sftp server, no PAM (glibc crypt + /etc/shadow via busybox
is the whole auth stack), password auth left possible in v1 (locked down to
key-only in v2 M3).
