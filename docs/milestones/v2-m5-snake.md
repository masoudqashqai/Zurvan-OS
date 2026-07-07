---
id: v2-m5
version: v2
milestone: 5
title: "The snake — disposable job runner in evaporating sandboxes"
status: done
completed: 2026-07-07
commits: [see the M5 commit]
key_files: [snake/zurvan-snake.c, snake/Makefile, rootfs/etc/svc/snake.def, packages/provisioner/example.yaml, scripts/build.sh]
verification: tests/m5-snake.sh
---

## Goal
The lion's mirror twin: where the lion makes things permanent, the snake makes
work perfectly disposable. Give it a job — a script, a build, a cron-shaped
task — and it executes in a fresh tmpfs sandbox in its own mount namespace,
returns the result, and the sandbox evaporates. A minimal CI-runner /
scratch-executor primitive, safe *because* of Zurvan's architecture: the OS
is already disposable and the root is sealed read-only, so a misbehaving job
costs nothing.

## Done-when (verified)
A job that writes garbage all over its filesystem finishes, its output comes
back, and the running system shows no trace it ever ran.

## Design decisions
- **The sandbox is subtraction, not construction** (the key idea):
  `unshare(CLONE_NEWNS)` + `MS_REC|MS_PRIVATE`, bind-remount `/` read-only
  (no-op under the seal, a guarantee under `zurvan.rw`), then fresh private
  tmpfs over every writable surface — `/tmp` (64 MB job workspace) and,
  crucially, **`/data`, /run, /var/run, /var/log**. The permanent world is
  not *protected from* the job; it simply **is not there** — the lion's den,
  the YAML, service state: an empty tmpfs. No pivot_root, no images, no
  chroot needed because the RAM root is already minimal and now read-only.
- **Explicitly not a container runtime** (roadmap rabbit-hole warning obeyed):
  no PID/network/user namespaces, no cgroups, no OCI. Mount namespace +
  tmpfs + timeout is the whole isolation story. Jobs run as root with
  `no_new_privs`; the network is deliberately available (CI jobs fetch).
- **What crosses back is enumerable**: exit status, captured output, and
  files the job left in `$ARTIFACTS` (top-level regular files only — an
  artifact *tree* is a job that should make a tarball). Artifacts escape the
  doomed namespace through **directory fds opened before the tmpfs hid
  /data** — an fd keeps referencing the real filesystem across the
  overmount, so the runner (inside the ns) copies through it with openat.
- **Two arrival paths, one engine**: `zurvan-snake run [--timeout N]
  <script|->` (SSH/console, live output, exit code = job's) and a supervised
  queue daemon watching `/data/snake/queue/`. Results land in
  `/data/snake/results/<name>-<stamp>/ = { job, log, status, artifacts/ }`;
  `status` is written **last** and is the only honest completion signal.
- **Queue semantics: at-most-once.** The queue file is consumed (unlinked) at
  pickup; a crash mid-job must not re-run a possibly-destructive job, and
  the results dir keeps the job copy for the record.
- **Timeout = one negative kill**: the runner child `setsid()`s, so
  `kill(-pgid, SIGKILL)` from the host-namespace parent reaps the runner,
  the job, and everything the job spawned; the namespace — and every byte
  the job wrote — evaporates with the last process in it. rc 124.
- **Job exec**: direct `execve` first (static-binary jobs work), `/bin/sh`
  fallback on ENOEXEC (plain scripts without shebangs). Env: HOME=/tmp/job,
  TMPDIR=/tmp, ARTIFACTS=/tmp/job/artifacts. Stdin jobs (`run -`) spool to
  an unlinked host tmp file, materialized inside via the fd.

## How it was built
1. `snake/zurvan-snake.c` (~470 lines, static, warning-free) + Makefile;
   wired into `make init`; build.sh ships `/sbin/zurvan-snake`; baked
   `rootfs/etc/svc/snake.def` (root: mount namespaces need CAP_SYS_ADMIN;
   this kernel has no user namespaces by design). Enable: `- snake`.
2. Host smoke suite in WSL (real mount namespaces): isolation, exit codes,
   timeout tree-kill, stdin jobs, queue round-trip — all before QEMU.
3. QEMU acceptance test `tests/m5-snake.sh` on the sealed, supervised system.

## Key files
| path | role |
|---|---|
| `snake/zurvan-snake.c` | sandbox construction, runner, queue daemon — read whole |
| `rootfs/etc/svc/snake.def` | supervised queue daemon definition |
| `tests/m5-snake.sh` | probes A–D incl. the no-trace done-when |

## Problems hit
- **Fs-view assertions must account for the job's own writes**: the
  acceptance test first asserted the job sees an *empty* /data — but the job
  had just written its own garbage file into the sandbox tmpfs, so it saw
  `[garbage]`. Correct assertion: the job sees exactly what it wrote and
  NOT the host's file. (The sandbox was right; the test was wrong.)
- **"Result dir exists + queue file gone" ≠ job finished** (smoke-test race):
  both are true at *pickup*; killing the daemon then loses `status`. That is
  why `status` is written last — tests (and the future web panel) must wait
  for it, nothing else.
- **Over-long queue filenames would truncate into a path that never
  unlinks**, wedging the daemon in a pick-run-fail loop on the same entry —
  caught as a `-Wformat-truncation` warning and fixed with a hard length
  check that skips (loudly) instead of truncating.
- Integration risk that motivated probe A: the daemon runs under zurvan-svc
  **with no_new_privs already set** — NNP restricts privilege *gains*, not
  CAP_SYS_ADMIN it already has, so unshare still works. Verified, not
  assumed.

## Verification
Host smoke suite: 5/5 (garbage isolation with zero mount-count change, rc
propagation, 3 s timeout kill incl. a backgrounded child, stdin job, queue
round-trip). QEMU `tests/m5-snake.sh`: A snake healthy under svc with
NoNewPrivs=1; B the done-when — output + artifact returned, real /data
intact including the file the job "deleted", no garbage in /tmp//run, no
/tmp/job left, `/proc/mounts` byte-identical before/after; C rc=7
propagated, `--timeout 3` returned 124 in dt=3s with no surviving job tree;
D queue file → results dir with log, status (exit=3), artifact, job copy,
queue emptied. MILESTONE 5 DONE-WHEN: PASS.

## Deferred / rabbit holes avoided
No PID/net/user namespaces, no cgroups/rlimits (the tmpfs size caps are the
memory story), no job scheduling/cron (drop files in the queue from cron or
SSH), no per-job timeout declaration in queue mode (one default; the run
mode flag exists), no results retention policy (admin's or the panel's
concern). Results dirs are ordinary /data content — the lion snapshots them.
