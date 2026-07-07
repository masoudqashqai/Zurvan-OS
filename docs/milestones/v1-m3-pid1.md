---
id: v1-m3
version: v1
milestone: 3
title: "C PID 1 — ~200 readable lines replace the shell /init"
status: done
completed: 2026-07-02
commits: [bdcca3f]
key_files: [init/init.c, init/Makefile]
verification: "/proc/1/comm == init; shell respawns when exited; zombies reaped"
---

## Goal
Replace the throwaway shell `/init` with a real init: a small static C
program meant to be read top to bottom. It is the piece of the project with
the highest understanding-per-line — the two failure modes of PID 1 are
kernel panics with no useful message, so the code documents them explicitly.

## Done-when
`/proc/1/comm` is our binary; exiting the shell brings a new one; no zombie
accumulation.

## Design decisions
- **The two rules of PID 1** (stated as a comment block at the top of init.c):
  1. PID 1 must NEVER exit — the kernel panics with "Attempted to kill init!".
     Therefore the program *is* an infinite supervising loop.
  2. PID 1 must REAP zombies — orphans re-parent to PID 1; `waitpid(-1, …)`
     in the loop reaps every dead child, supervised or adopted.
- **Supervise exactly one shell.** The v1 boundary, defended in the roadmap:
  PID 1 is a babysitter, not a service manager. (v2 M2 adds exactly one more
  supervised child, `zurvan-svc`, which babysits everything else — PID 1 never
  learns about services.)
- **An rc hook, not built-in policy**: `run_rc()` runs `/etc/rc.init` once
  (forked, waited) if executable. Networking (M5), the provisioner (M6), and
  all of v2's boot logic hang off that script; init.c stays frozen.
- Structure of `init/init.c` (in order): ignore SIGINT/SIGTERM →
  `early_mounts()` (proc, sysfs, devtmpfs on /dev, devpts on /dev/pts) →
  `setup_console()` (dup /dev/console to fds 0/1/2) → banner → `run_rc()` →
  `spawn_svc()` (v2) → `spawn_shell()` → `for(;;) waitpid(-1)` respawn loop.
- Shell spawning details that matter: `setsid()` + `ioctl(TIOCSCTTY)` so the
  shell owns the controlling terminal; candidates `/bin/bash` then `/bin/sh`;
  fixed clean envp (`HOME=/root TERM=linux PATH=…`); `ECHILD` from waitpid
  (no children at all) sleeps 1s and retries a shell rather than spinning.
- devtmpfs is mounted by init even though `CONFIG_DEVTMPFS_MOUNT=y` could do
  it — keeps init self-contained/order-explicit.

## How it was built
`init/Makefile`: `gcc -static -O2` (no libc surprises since glibc static is
fine for what init uses). `make init`; `scripts/build.sh` installs it as
`/init` in the image.

## Key files
| path | role |
|---|---|
| `init/init.c` | the whole program; grew only `spawn_svc()` since (v2 M2) |
| `rootfs/etc/rc.init` | the hook; accumulated all later boot logic |

## Problems hit
- devpts mount was actually added later with dropbear (SSH needs ptys) — noted
  here because it lives in `early_mounts()`; without it `sshd` sessions get no
  terminal. Order matters: devpts after /dev exists.

## Verification
`cat /proc/1/comm` → `init`; typing `exit` in the console shell produces
"[init] shell exited; respawning." and a fresh prompt; background zombies do
not accumulate (adopted orphans reaped by the same loop).

## Deferred / rabbit holes avoided
No signal-forwarding framework, no runlevels, no config file, no shutdown
choreography. Explicit roadmap rule: PID 1 stays a small reason-about-able
loop; the service manager (v2 M2) is a separate program *under* it.
