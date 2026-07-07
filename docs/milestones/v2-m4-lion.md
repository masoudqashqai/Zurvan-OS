---
id: v2-m4
version: v2
milestone: 4
title: "The lion — snapshot daemon guarding /data"
status: done
completed: 2026-07-07
commits: [see the M4 commit]
key_files: [lion/zurvan-lion.c, lion/Makefile, rootfs/etc/svc/lion.def, packages/provisioner/zurvan-provision, packages/provisioner/example.yaml, scripts/build.sh]
verification: tests/m4-lion.sh
---

## Goal
The persistent half of the twins gets its guardian: a small supervised C
daemon that periodically packs all of `/data` (except its own snapshot
directory) into one checksummed, compressed archive, keeps the last N in a
ring buffer, and can put a chosen snapshot back. For an auth server or a
database on /data, this is the sleep-at-night feature.

## Done-when (all verified)
Deleting a file from /data, then restoring a snapshot, brings it back — and
filling the disk makes the lion eat its own oldest snapshot rather than fail.

## Design decisions
- **C daemon, policy only**: like zurvan-svc it parses NO YAML and delegates
  plumbing — busybox `tar -czf` does the archiving (via fork/execvp, no
  shell, no quoting), busybox `sha256sum` the checksums (via popen). The C
  is scheduling, atomicity, and retention policy (~450 lines, read whole).
- **Config pipeline reuse**: the provisioner digests the YAML `lion:` block
  (`every: 24h`, `keep: 7` — s/m/h/d suffixes) into flat `/run/lion.conf`;
  the daemon reads that at startup. Enabling is the standard story: `- lion`
  under `services:` + the baked `/etc/svc/lion.def` (runs as root on purpose:
  it must read every service's state dir and restore ownership).
- **Snapshot layout** in `/data/lion/`: `lion-YYYYMMDD-HHMMSS.tar.gz` +
  `.manifest` (`created=` epoch, `size=`, `sha256=`). UTC stamps make names
  sort chronologically — the ring needs no database, just readdir+sort.
- **Guardrail 1, atomicity**: write temp → fsync → rename, archive first,
  **manifest last — its appearance is the commit point**. An archive without
  a manifest is by definition debris and gets swept, as do `.new-*` temps.
  The directory fd is fsynced after the renames so they survive a power cut.
- **Guardrail 2, the guardian must never become the threat**: before writing,
  free space is checked against an estimate (newest snapshot size + 25% +
  4 MB margin); oldest snapshots are deleted until it fits — **but never the
  single newest good one** (deleting your only backup to make room for a
  hopeful new one is how backups die). A failed tar (likely ENOSPC) prunes
  one more and retries once, then gives up loudly leaving nothing behind.
- **Restore verifies before trusting**: sha256 recomputed and compared to the
  manifest BEFORE unpacking; mismatch → refused. Restore overlays /data
  (deleted files return, newer files remain); restore names are validated
  hard since they end up in paths.
- **First boot is guarded**: the daemon snapshots immediately when none
  exists rather than waiting a full interval.
- **Ring prune runs after every successful snapshot** (`keep` newest stay).

## How it was built
1. `lion/zurvan-lion.c` + Makefile (same static/-Wall/-Wextra recipe as svc);
   wired into `make init`, shipped by build.sh as `/sbin/zurvan-lion`.
2. Provisioner: 10 lines to emit /run/lion.conf; example.yaml documents the
   block; `rootfs/etc/svc/lion.def` bakes the service.
3. **Host-side smoke suite first** (tmpfs mounted as /data in WSL, GNU tar):
   snap/list/no-snowball, restore, corrupt-refusal, ring, disk pressure,
   debris sweep — all logic proven before any QEMU minute was spent.
4. QEMU acceptance test `tests/m4-lion.sh` against busybox tar and the
   sealed, supervised system.

## Key files
| path | role |
|---|---|
| `lion/zurvan-lion.c` | the whole daemon: daemon/snap/list/restore |
| `rootfs/etc/svc/lion.def` | supervised-service definition (root, restart=yes) |
| `packages/provisioner/zurvan-provision` | lion: block → /run/lion.conf |
| `tests/m4-lion.sh` | probes A–G, incl. both done-when clauses |

## Problems hit
- **`-std=c11` hides POSIX**: `popen`, `gmtime_r`, `fileno` were implicit →
  `#define _POSIX_C_SOURCE 200809L` (svc had dodged this with `_GNU_SOURCE`).
- **Same-second stamp collision race**: a manual `zurvan-lion snap` can run
  concurrently with the daemon's scheduled one; with 1-second stamp
  resolution both writers shared temp AND final names — an unlucky rename
  interleave could pair writer A's archive with writer B's manifest, making
  a *good* snapshot fail its checksum. Fix: temp names carry the pid, and a
  stamp whose final files already exist is waited out, never reused.
- **A "full disk" made of zeros isn't full**: the first smoke test filled
  /data with `/dev/zero` ballast — gzip crushed 40 MB to 40 KB and the
  pressure path never triggered (correctly!). Tests that want disk pressure
  need `/dev/urandom` ballast, or a filler parked where the snapshot won't
  pick it up. The QEMU test squeezes with a zero filler inside /data/lion
  (excluded from archives, ignored by the sweeper) + small urandom ballast.
- **The daemon can't be reconfigured in place** (conf read at startup):
  the test parks it by rewriting /run/lion.conf and killing it — zurvan-svc
  respawns it within a second and it reloads. Deliberate: a reload channel
  would be more code than the restart costs.
- `-Wformat-truncation` on PATH_LEN 256 with 255-byte d_names — buffers sized
  to fit (512) rather than warnings suppressed.

## Verification
Host smoke suite: 6/6. QEMU `tests/m4-lion.sh`: A config digested + daemon
under svc + first snapshot at boot; B schedule honored (1→3 snapshots over
25 s at every=10s); C archive holds /data, zero `lion` entries (no
snowball with busybox tar's --exclude); D delete + restore returns the file;
E corrupted archive refused; F ring holds at exactly keep=3; G with ~60 MB
free the lion logged `deleted lion-… (making room)`, spared the newest, and
landed the new snapshot (COUNT=2). MILESTONE 4 DONE-WHEN: PASS.

## Deferred / rabbit holes avoided
Grandfather-father-son retention stays post-v2 (ring buffer is predictable
by inspection). No filesystem-level snapshots (plain ext4; archives are
crash-consistent — archive-level atomicity is guaranteed, per-file
consistency of concurrently-written service files is best-effort). No
incremental/deduplicated backups, no encryption, no remote replication —
one compressed tarball you can inspect with tar is the feature.
