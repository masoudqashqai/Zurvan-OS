# init/

The custom **PID 1**, written in C. This is the program the kernel runs as `/init` after
unpacking the initramfs.

> ⚠️ **The other part to reason about yourself** (alongside the kernel config). A bad init
> just panics with no useful message. Keep it small enough to hold in your head.

## The two rules of PID 1

1. **It must never exit.** If PID 1 returns or `_exit()`s, the kernel panics with
   *"Attempted to kill init!"*. `init.c` is an infinite supervising loop — not a script
   that runs to completion.
2. **It must reap zombies.** Orphaned processes get re-parented to PID 1. If it never
   `wait()`s for them, they accumulate as zombies forever. The supervise loop reaps every
   dead child with `waitpid(-1, …)`.

## What it does (v1 / milestone 3)

1. Mount `/proc`, `/sys`, and `devtmpfs` on `/dev`.
2. Set up the console (`stdin`/`stdout`/`stderr` → `/dev/console`).
3. Run `/etc/rc.init` if present — the hook where **networking** (milestone 5) and later
   the **provisioner** (milestone 6) run, so they don't bloat this file.
4. Supervise a shell: spawn it (`bash` if present, else `sh`), respawn it if it dies, and
   reap everything in between.

## Build

```sh
make -C init       # -> init/init  (static)
```

The top-level `make rootfs` copies `init/init` to `/init` in the rootfs.

## Why a C program and not a shell script for `/init`?

Milestone 2 *does* use a trivial shell `/init` (see `rootfs/init.sh`) just to prove the
rootfs boots. Milestone 3 replaces it with this C program because a real PID 1 needs to
reap zombies and never exit — things a fall-off-the-end shell script doesn't do.
