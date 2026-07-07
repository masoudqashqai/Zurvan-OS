---
id: v1-m4
version: v1
milestone: 4
title: "Static bash — the supervised interactive shell"
status: done
completed: 2026-07-02
commits: [bdcca3f, 4c5ac94]
key_files: [userland/build-bash.sh, init/init.c]
verification: "PID 1 spawns /bin/bash -i as the console shell"
---

## Goal
A real interactive shell on the console: static bash added to the rootfs and
made PID 1's first shell candidate (`SHELL_CANDIDATES[] = { "/bin/bash",
"/bin/sh" }`). Busybox `sh` stays as fallback, so a broken bash build never
bricks the console.

## Done-when
Boot lands in bash (job control, line editing); killing it respawns it.

## Design decisions
- Bash is built from the GNU tarball with its **bundled termcap**, statically —
  no ncurses dependency to also build.
- Fallback ordering in init rather than hard requirement: the image works with
  busybox sh alone (`SHELL_CANDIDATES` probe via `access(X_OK)`).

## How it was built
`userland/build-bash.sh`: fetch, `./configure --enable-static-link` (plus the
CFLAGS below), make, copy `bash` into the staging tree. `make userland`.

## Key files
| path | role |
|---|---|
| `userland/build-bash.sh` | static bash build with the GCC-15-era fixes |

## Problems hit (commit 4c5ac94 — the "old code vs modern GCC" pattern)
- **C23 default broke the build**: GCC 15 defaults to C23, which makes K&R
  empty-parameter declarations (`int foo();` meaning unspecified args) a hard
  error, and bash's vendored code is full of them. Fix: pin `-std=gnu17`.
- **Bundled termcap calls `write()` without declaring it** — implicit function
  declarations are also errors now. Fix: `-Wno-implicit-function-declaration`.
- This pair (`-std=gnu17` + tolerance flags) became the standard recipe for
  every old-codebase static build in the project (bash, e2fsprogs, gnupg 1.4
  with `-fcommon`).

## Verification
Console shell is bash (`echo $BASH_VERSION`), interactive flag set, respawn
on exit works exactly as with busybox sh.

## Deferred / rabbit holes avoided
No readline-from-source, no /etc/profile ecosystem — a shell, not a login
experience.
