# tests/ — milestone "done when" suites

Each script proves one roadmap milestone's *done when* clause end-to-end in
QEMU: real installs from the ISO, real reboots, verdicts on the last line.
They are acceptance tests, not unit tests — expect several minutes each.

| script               | proves                                                                 |
|----------------------|------------------------------------------------------------------------|
| `m1-e2e.sh`          | M1: hostname, SSH fingerprint, and an installed app survive reboot; a byte-copied disk is an identical second server |
| `m2-supervisor.sh`   | M2: dropbear + an installed app run under `zurvan-svc`; killing either gets it restarted within seconds |
| `m3-verified-boot.sh`| M3: GRUB boots the signed image, and refuses it after 16 flipped bytes in the initrd |
| `m3-ab-upgrade.sh`   | M3: wrong-key bundle rejected before touching a slot; signed upgrade boots once + commits; corrupted trial slot falls back automatically |
| `m3-seal.sh`         | M3: `/` is EROFS while `/data` writes; package installs reseal behind themselves; hardening sysctls, `no_new_privs`, key-only SSH |
| `m4-lion.sh`         | M4: scheduled snapshots; restore brings a deleted file back; checksums gate restores; the ring holds; a full disk eats the oldest snapshot, never fails |
| `m5-snake.sh`        | M5: a filthy job finishes, its artifact comes back, and the running system shows no trace it ever ran |
| `m6-face.sh`         | M6: the panel serves HTTPS with its first-boot cert and drives services, snapshots, jobs, files, packages, and upgrades end-to-end |
| `pkg-verify.sh`      | Package signatures: signed installs pass; missing `.sig` and tampered tarballs are refused before unpacking; `--unsigned` overrides; the seal survives refusals |

## Requirements

- **root** on Linux (or WSL2): the scripts loop-mount `build/disk.img` to
  inspect grubenv, slots, and `/data` offline — that is the ground truth the
  verdicts trust, not guest output.
- `qemu-system-x86_64`, `ssh`/`ssh-keygen`, and `gpg` (only `m3-ab-upgrade.sh`,
  to forge an attacker bundle).
- Built artifacts: `make all`, then `scripts/make-iso.sh` (which also emits
  `build/zurvan-upgrade.tar`). The catalog packages (`catalog/build-*.sh`)
  must be built before the ISO so the installer can ship them to `/data`.
- TCP port 2222 free on the host (guest SSH is forwarded there;
  `pkg-verify.sh` uses 2224).

## Running

```sh
sudo tests/m3-seal.sh          # or any of the others
```

They rewrite `build/disk.img` (and `m2`: `build/data.img`; `m1`: also
`build/disk-clone.img`) — never point them at a disk image you care about.
QEMU console logs land in `/tmp/zurvan-*-logs/` (override with `LOGDIR=`);
the pass/fail verdict is printed on stdout and the exit code.
