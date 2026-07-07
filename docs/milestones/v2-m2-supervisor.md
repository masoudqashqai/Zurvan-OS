---
id: v2-m2
version: v2
milestone: 2
title: "The babysitter — zurvan-svc, a declarative service supervisor"
status: done
completed: 2026-07-06
commits: [214b149, 669c5ee]
key_files: [svc/zurvan-svc.c, init/init.c, rootfs/etc/svc/ssh.def, packages/pkgtool/zurvan-pkg, packages/provisioner/zurvan-provision, catalog/build-tick.sh]
verification: tests/m2-supervisor.sh
---

## Goal
A server needs several programs running and restarted when they die — but the
v1 boundary (PID 1 supervises exactly one shell) must hold. Solution: a small
C supervisor (`zurvan-svc`) that is *itself* just another supervised child of
PID 1. PID 1 babysits two; zurvan-svc babysits everything else.

## Done-when
dropbear and an installed package run under supervision; `kill -9` on either
gets it restarted within seconds.

## Design decisions
- **The supervisor parses no YAML.** The shell layer digests everything into
  flat files first; the C program reads only:
  - `/run/svc/enabled` — one service name per line (written by the provisioner
    from the YAML's `services:` list);
  - `<name>.def` files — `exec=`, `after=` (space-separated deps), `restart=`
    (yes/no), later `user=` (M3). Looked up in `/run/svc/` first (package
    exports — regenerated every boot), then `/etc/svc/` (image built-ins like ssh).
  This keeps the C readable whole and pushes all string-mangling to sh/awk
  where it's cheap.
- **A 1-second-heartbeat poll loop**, not an event architecture: each tick,
  reap dead children (`waitpid(WNOHANG)`), restart what's due, start what's
  startable (all `after=` deps up). Dependency order falls out for free.
- **Restart backoff**: 1s doubling to 30s max; reset to 1s after a service
  stays up 60s (`STABLE_SECS`). A permanently-crashing service throttles
  itself; a flaky one recovers fast.
- **Services must not daemonize** (`dropbear -F`): the supervisor's child IS
  the service; double-forking would orphan it. Each service gets its own
  session (`setsid`) so a dying service can't take siblings down. Pid files
  at `/run/svc/<name>.pid` (used by the tests).
- **PID 1 grew only `spawn_svc()`** — respawned like the shell, with a 1s
  breather so a crash-looping binary can't spin PID 1.
- **Enable story = install + one YAML line**: `zurvan-pkg` exports a
  manifest's `service:` block to `/run/svc/<name>.def` at install time and on
  every boot's dress pass; the user adds the name to `services:`. The
  provisioner *stopped starting daemons itself* — it only writes the enabled
  list (networking stays a direct action; ssh keeps its /data key setup).

## How it was built
1. `svc/zurvan-svc.c` (~300 lines, static; `svc/Makefile`): load enabled →
   load defs → poll loop {reap, restart-due, start-ready}.
2. init.c: `spawn_svc()` + second respawn slot in the wait loop.
3. Provisioner rewired to write `/run/svc/enabled`; baked
   `rootfs/etc/svc/ssh.def` runs dropbear foreground.
4. `zurvan-pkg` export_service(); new catalog package **tick** — a heartbeat
   daemon logging to /data/srv/tick, the "installed supervised app" for the
   done-when (its persistent log shows restarts mid-stream).

## Key files
| path | role |
|---|---|
| `svc/zurvan-svc.c` | the whole supervisor; meant to be read top to bottom |
| `rootfs/etc/svc/ssh.def` | the image-built-in service definition pattern |
| `/run/svc/*` (runtime) | enabled list, package defs, pid files — all tmpfs, rebuilt per boot |

## Problems hit
- A service enabled in the YAML but not yet installed must not wedge the
  supervisor: it logs `WARNING: no definition for 'tick' — skipping` and
  idles; the def appears after install + next dress. (Verified explicitly in
  the test's boot 1.)
- (Later, M3) `logf` as a function name collides with glibc's `logf(3)` from
  math.h under `_GNU_SOURCE` — renamed `svc_log`. Recorded here because it's
  a C-naming landmine in exactly this kind of small tool.

## Verification
`tests/m2-supervisor.sh`: fresh data disk with ssh+tick enabled; boot 1
installs tick (warning observed while undefined); boot 2: `kill -9` tick →
new pid within 8s (159→168 in the original run), `kill -9` the dropbear
listener → reconnect works within 6s (158→175), tick's /data log shows the
pid change mid-stream. PASS.

## Deferred / rabbit holes avoided
Roadmap said it outright: **no socket activation, no cgroups, no
parallel-start optimizer.** Dependency order + restart-on-crash is the whole
feature. Also no service *stop* command, no reload signals, no readiness
notification — a service is "up" when its process lives.
