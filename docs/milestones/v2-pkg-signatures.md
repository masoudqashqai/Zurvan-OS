---
id: v2-pkg-signatures
version: v2
milestone: "post-v2 addition (first item off the deferred list)"
title: "Signature-verified package installs"
status: done
completed: 2026-07-11
commits: [e07ad8a]
key_files: [packages/pkgtool/zurvan-pkg, face/zurvan-face.c, scripts/make-iso.sh, scripts/make-catalog-pack.sh, packages/installer/zurvan-install, Makefile, tests/pkg-verify.sh]
verification: "tests/pkg-verify.sh in QEMU: signed catalog package installs; missing .sig refused with a 'no signature' message; tampered tarball (flipped byte, real sig) refused; --unsigned overrides; root stays EROFS through refusals and installs"
---

## Goal

Close the catalog's documented "honest gap": the pack was signed, but
`zurvan-pkg install` unpacked whatever it was handed and the panel installed
whatever you uploaded. Verification was a step the human chose to take; now
the box takes it, every time, before anything is unpacked. Done before growing
the catalog further, because every new package is another tarball people scp
around.

## Done-when

A catalog package (its `.sig` beside it) installs; the same tarball with the
signature missing or one byte flipped is refused before unpacking; an
explicitly-unsigned install still works for self-built packages; a refused
install leaves the root sealed.

## Design decisions

- **Same verifier, same anchor as image upgrades.** `gpgv --keyring
  /etc/zurvan-signing.pub <pkg>.sig <pkg>` — the exact check `zurvan-upgrade`
  runs before touching a slot. No new machinery entered the image; the gate
  was assembled from parts the seal milestone already shipped.
- **Verify before `open_root`.** The signature check happens while the root is
  still sealed; only a verified package earns the rw toggle.
- **Fail closed, escape loudly.** Missing `gpgv`, missing anchor, missing
  `.sig`, bad signature — all refuse. The override is a flag you must type
  (`zurvan-pkg install --unsigned`) or a button you must confirm (the panel's
  "Install unsigned", shown only for tarballs with no `.sig` on `/data`).
  Flagship security defaults ON; disabling is the explicit act.
- **The `.sig` travels with the tarball everywhere it goes.** `make catalog`
  signs `build/catalog/*`; `make-iso.sh` re-signs the on-ISO tier and ships
  the sigs; `zurvan-install` copies them to `/data`; the catalog pack carries
  one per package (INDEX.txt says to keep them together); the panel's delete
  removes the orphaned `.sig` with its tarball.
- **Still not a repository.** The rabbit-hole warning held: no
  `zurvan-pkg install <url>`, the install path stays offline. This is one
  signature check, not package management.

## How it was built

The gate in `cmd_install` (verify → `open_root` → unpack), a `--unsigned`
branch in the dispatcher, sig plumbing through the four places a package
travels (Makefile, ISO, installer, pack), and the panel's three touches
(upload hint accepts `.sig`, per-tarball signed/unsigned buttons, delete takes
the `.sig` along). `tests/pkg-verify.sh` is the acceptance suite; the m1/m2
suites grew a one-line `sign.sh` call where they hand-seed tarballs onto
`/data`.

## Key files

| path | role |
|---|---|
| `packages/pkgtool/zurvan-pkg` | the gate: gpgv before unpack, `--unsigned` override |
| `face/zurvan-face.c` | panel: `.sig` upload, Install vs confirmed Install-unsigned, sig-aware delete |
| `scripts/make-iso.sh` | signs + ships the on-ISO tier's `.sig`s |
| `packages/installer/zurvan-install` | copies `.sig`s to `/data` beside the tarballs |
| `scripts/make-catalog-pack.sh` | one `.sig` per package inside the pack |
| `Makefile` | `make catalog` signs everything it built |
| `tests/pkg-verify.sh` | the done-when, end to end in QEMU |

## Gotchas for future sessions

- The installer's sig copy is an `if ls ...; then cp ...; fi` on purpose — a
  bare `ls && cp` under `set -eu` aborts the whole install on a sig-less ISO
  (the exact class of bug fixed in c441791).
- `sign.sh` replaces stale `.sig`s, so re-signing at ISO/pack time is always
  safe — a stale signature is worse than none, because the gate turns it into
  a refused install.
- Tests that hand-seed a tarball onto `/data` (m1, m2, any future smoke test)
  must seed the `.sig` too, or use `--unsigned` deliberately.
