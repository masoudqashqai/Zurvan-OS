---
id: v2-panel-upload-ux
version: v2
milestone: "post-v2 addition (panel feedback: upload friction)"
title: "Panel upload UX — multi-file uploads, whole-pack staging, banner above the prompt"
status: done
completed: 2026-07-12
commits: [337c5bd]
key_files: [face/zurvan-face.c, rootfs/etc/profile, packages/provisioner/zurvan-provision, tests/panel-ux.sh]
verification: "tests/panel-ux.sh in QEMU: URL+token box printed exactly once, after all boot chatter (live boot, serial); tarball+.sig uploaded in ONE multipart request and installed; the whole zurvan-catalog-<DATE>.tar.gz uploaded as-is -> 8 packages staged on /data with 8 sigs, pack file and staging dir gone; a pack-staged package installs through the signature gate"
---

## Goal

Three friction points, all reported from real use after the catalog grew past a
handful of packages: (1) installing one package took two uploads (tarball, then
`.sig`) because the multipart parser stopped at the first file part; (2)
installing *most of the catalog* meant untarring the release pack on your own
machine and feeding the panel 16 files one at a time; (3) the panel's URL+token
box was printed mid-boot and scrolled off behind the lines that followed it, so
the one thing a first boot exists to tell you was never on screen when the
prompt appeared.

## Done-when

One browser upload with the tarball and `.sig` selected together lands both on
`/data`; uploading `zurvan-catalog-<DATE>.tar.gz` as-is stages every package
inside with its `.sig` (pack file cleaned up after); the URL+token box is the
last thing above the first console prompt, printed exactly once.

## Design decisions

- **A signature cannot ride inside the file it signs.** The user's first idea
  was "pack the .sig into the tarball" — cryptographically circular, and a
  wrapper format (`.zpkg` = tar of tarball+sig) would teach a second format to
  the CLI, the pack builder, the docs, and the panel. Rejected. Multi-file
  upload solves the same annoyance with one HTML attribute and a parser loop.
- **The parser became an iterator, not a second parser.** `multipart_file`
  (first file part only) → `multipart_next(r, &cur, ...)` with an explicit
  cursor; all three upload endpoints (`/packages`, `/system`, `/files`) loop
  it. Same boundary handling, same in-place pointers (no copies).
- **Pack recognition by name, staging by rename.** `zurvan-catalog-*.tar.gz`
  uploaded to `/packages/upload` is untarred into a `mkdtemp` dir **on /data**
  (same filesystem → the per-package moves are `rename()`, not copies; and the
  tens-of-MB payload never sits in tmpfs RAM), then every inner `*.tar.gz` +
  `*.tar.gz.sig` moves to `/data` and the pack file is deleted. Convenience
  only — the security gate is untouched: `zurvan-pkg install` still verifies
  each package's own `.sig` before unpacking.
- **UPLOAD_MAX 32 → 128 MB.** The pack (34 MB) has to fit in one body. The
  body is malloc'd whole per request (read_request); 128 MB caps that.
- **The banner moved to where the eyes are.** The provisioner no longer prints
  the box mid-boot (it still writes `/usr/bin/zurvan-panel`, the one source of
  truth). `/etc/profile` runs `zurvan-panel` on interactive **console** shells
  only (`tty` not a pts) — right above the first prompt, after all rc.init
  output. Not over SSH: no re-shouting the admin token into every remote
  session's scrollback.

## How it was built

face/zurvan-face.c: iterator + `is_catalog_pack`/`stage_pack` helpers next to
`save_file`, three handlers looped, `multiple` on the three file inputs,
Packages-page copy rewritten, flash message reports what was staged.
rootfs/etc/profile: greeting case gains the console-only `zurvan-panel` call.
packages/provisioner/zurvan-provision: the mid-boot print removed (comment
says why). Rebuild: `make -C face && make rootfs iso`.

## Key files

| path | role |
|---|---|
| `face/zurvan-face.c` | `multipart_next` iterator, `stage_pack`, `UPLOAD_MAX`, forms/copy |
| `rootfs/etc/profile` | prints the box above the first console prompt (not SSH) |
| `packages/provisioner/zurvan-provision` | writes `zurvan-panel`; no longer prints mid-boot |
| `tests/panel-ux.sh` | the done-when, end to end in QEMU (ports 2226/8444) |

## Problems hit

- **"panel never came up" in the first e2e run** — the test's seeded
  `zurvan.yaml` *replaces* the installer default, so listing `services:` at
  all means listing `face` too (same trap `m6-face.sh` documents at its seed
  step). Not a product bug.
- **Booting the ISO with `-nographic` showed nothing** — the ISO's default
  GRUB entry logs to tty0 (VGA, the VMware-first choice); serial assertions
  must boot `-kernel bzImage -initrd rootfs.cpio.gz -append console=ttyS0`
  like every other suite.
- **`.tar.gz.sig` vs `.tar.gz` suffix test**: a sig's last 7 chars are
  `.gz.sig`, so the tarball check can't false-positive on sigs — but only
  because both suffixes are checked full-length. Keep both checks if editing.

## Deferred / rabbit holes avoided

- No streaming upload (body still malloc'd whole). Right fix if packs ever
  outgrow RAM-comfort; surgery in `read_request` not worth it at 34 MB.
- No "install all" button after staging — staging fills the existing
  per-package Install list; one more click per package is deliberate (each
  install is still an explicit, signature-gated act).
- No `.sig`-in-tarball or wrapper format (see design decisions).
