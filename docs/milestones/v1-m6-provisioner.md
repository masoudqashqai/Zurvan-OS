---
id: v1-m6
version: v1
milestone: 6
title: "First-boot YAML provisioner — the signature feature"
status: done
completed: 2026-07-02
commits: [bc4809b]
key_files: [packages/provisioner/zurvan-provision, packages/provisioner/example.yaml, rootfs/etc/rc.init]
verification: "example.yaml applied in QEMU: hostname, static net + DNS, user with bash + authorized_keys, all idempotent"
---

## Goal
cloud-init-lite: on every boot (every boot IS a first boot — the OS runs from
RAM), one YAML file configures the whole machine: hostname, network, users,
services. This is the feature that turns a from-scratch toy into "a server
described by one file", and later (v2) the file simply moves to the
persistent disk.

## Done-when
Boot with `example.yaml` produces the hostname, a static 10.0.2.50/24 with
route + DNS, user `zurvan` with bash and authorized_keys — and re-running is
a no-op (idempotent).

## Design decisions
- **busybox sh + awk, zero other dependencies.** The provisioner must run in
  the bare image; adding a YAML library would mean adding a language runtime.
- **Two-phase design**: an awk pass *flattens* a bounded YAML subset (2-space
  indent, scalars, lists, maps) into dotted `KEY=VALUE` paths
  (`users.0.name=zurvan`, `network.eth0.dhcp=false`); the sh apply phase reads
  those with simple helpers (`get`, `children`, `indices`). Parsing and
  applying never mix.
- **A YAML *subset*, deliberately bounded** — fixed keys, fixed shapes. The
  README design principle: "The provisioner parses a YAML subset" — anything
  fancier is a rabbit hole. No anchors, no multi-line strings, no nesting
  beyond what the schema needs.
- **Idempotency as a rule**: authorized_keys rewritten whole from config (not
  appended), `chpasswd -e` with pre-hashed passwords applied verbatim,
  hostname set unconditionally. Enables "run every boot" semantics.
- **Config source precedence**: `zurvan.config=<path>` on the kernel cmdline,
  else `/etc/zurvan.yaml` baked into the image. (v2 M1 added: prefer
  `/data/zurvan.yaml` when the persistent disk is present — the mechanism was
  already there.)
- **Bounded `services:` set** — v1 knew `networking` and later `ssh`; each is
  a named action in the script, not a generic unit system. (v2 M2 changed
  this: names now go to `/run/svc/enabled` for the supervisor.)

## How it was built
1. The awk flattener, tested standalone against example.yaml.
2. Apply phase: hostname → per-interface network (dhcp or static + dns) →
   users (create, shell, password hash, authorized_keys, home ownership) →
   services.
3. Wired in: `scripts/build.sh` installs the script + example.yaml as
   `/etc/zurvan.yaml` and pre-creates `/home` (adduser needs it);
   `rc.init` runs the provisioner (originally marker-guarded).

## Key files
| path | role |
|---|---|
| `packages/provisioner/zurvan-provision` | flattener + apply phases, one file |
| `packages/provisioner/example.yaml` | the documented schema by example; ships as the default config |

## Problems hit
- `adduser` fails if `/home` doesn't exist in the image — created at build.
- The v1 static-IP default (10.0.2.50, QEMU-specific) later silently broke
  VMware NAT networking; example.yaml switched to DHCP default in v2
  (commit 11bd8f8). Lesson: example configs are product defaults.

## Verification
QEMU boot against example.yaml: hostname applied, static 10.0.2.50/24 +
route + DNS applied, user zurvan with bash + authorized_keys exists, ping and
name resolution green, second run changes nothing.

## Deferred / rabbit holes avoided
No full YAML parser, no plugin/module system, no network-fetched config
(cloud-init's metadata-service world), no per-boot vs first-boot distinction
beyond the marker — RAM boot makes "first boot" the only kind.
