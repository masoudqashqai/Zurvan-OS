---
id: v2-m6
version: v2
milestone: 6
title: "The face — a web admin panel over HTTPS"
status: done
completed: 2026-07-07
commits: [see the M6 commit]
key_files: [face/zurvan-face.c, face/zurvan-certgen.c, face/Makefile, userland/build-bearssl.sh, rootfs/etc/svc/face.def, svc/zurvan-svc.c, packages/provisioner/zurvan-provision, packages/provisioner/example.yaml, scripts/build.sh]
verification: tests/m6-face.sh
---

## Goal
The victory lap: one static binary serving one HTTPS admin panel, so routine
administration never needs an SSH session — service state, snapshots with a
restore button, snake job history + a Run box, a /data file browser/editor
(the YAML included), package install, signed A/B upgrade, and reboot. A
server's face is a browser tab; this is the screenshot that sells the project.

## Done-when (verified)
A browser can see service state, browse snapshots, read job history, and edit
the YAML — with the panel shipped like any other component (here: in the image,
ON by default).

## Design decisions
- **A thin face over the CLIs, not a reimplementation.** Every action shells
  out — via fork/execvp with an **argv array, never a shell string**, so a
  snapshot name or file path can never become a command — to zurvan-svc,
  zurvan-lion, zurvan-snake, zurvan-pkg, zurvan-upgrade. The panel adds a web
  surface, not new behavior; the tested tools stay the source of truth. (This
  milestone added two small subcommands to zurvan-svc: `state` and `restart`,
  which a fresh process reconstructs from /run/svc — useful over SSH too.)
- **ON by default, not opt-in** (user UX call, [[zurvan-ux-defaults]]): a
  flagship feature the user must hand-enable is bad UX. `face` is in the
  shipped example.yaml services list; disabling is the one-line edit. First
  boot needs zero config — the token is generated and printed to the console.
- **No desktop environment, ever.** The browser is the display server. A GUI
  stack (X11/GTK, hundreds of shared libs, GPU drivers) would break the
  no-dynamic-loader / no-modules architecture the whole OS rests on. One
  release, panel included — a machine's identity is its YAML, not its ISO.
- **HTTPS via BearSSL, static** (userland/build-bearssl.sh — freestanding C,
  one `make`, links as a static archive; no autotools). TLS 1.2 ECDHE-ECDSA
  with forward secrecy. The panel is a single self-contained static binary.
- **Per-box TLS identity, made ON the box at first boot** (zurvan-certgen):
  EC P-256 keygen from BearSSL + a self-signed cert built from ~200 bytes of
  hand-written DER (no OpenSSL in the image). Lives on /data/face, so it
  persists across reboots like the SSH host keys — no two installs share a
  private key. Self-signed on purpose: no CA on a headless box; the admin
  accepts the fingerprint once, exactly like an SSH host key.
- **Auth = one token, one cookie, constant-time compared.** Generated at first
  boot into /data/face/token, printed to the console. The login form sets it
  as a Secure/HttpOnly/SameSite cookie; every request re-checks it. No users,
  no session store — one shared admin secret, like the box has one root.
- **/data is the only browsable tree** — the root is read-only and reborn each
  boot, so a file browser scoped to /data covers everything that persists; the
  YAML editor is that editor pointed at /data/zurvan.yaml. Path traversal
  ("..") is rejected.
- **The Run box submits to the snake, not a web terminal.** A browser shell
  would be a second, weaker SSH and the biggest attack surface on the box;
  instead "run this" goes through the sandboxed executor (M5), output and
  artifacts land in job history.
- **Uploads use a minimal multipart/form-data parser** (packages, upgrade
  bundles, arbitrary files to /data) — a web panel that made you scp things in
  would defeat its purpose. read_request allocates the body by Content-Length
  (up to UPLOAD_MAX) rather than a fixed buffer, so multi-MB uploads work
  without bloating every request. Uploaded files are basename-sanitised and
  land on /data.
- **Live mode**: with no /data disk, the panel's cert+token live on tmpfs
  (ephemeral, regenerated each boot) instead of /data — so the plain ISO boots
  straight into a working panel (token printed to the console). The provisioner
  chooses the dir and writes a /run/svc/face.def with --dir accordingly.
- **Every page carries a native `<details>` "what is this?" info box** — no
  JavaScript — so the snake/lion/upgrade concepts explain themselves in place.
- **One client at a time.** A panel is not a service under load; the accept/
  serve/close loop is simpler to read and reason about than a threaded one.

## How it was built (de-risk the crypto first)
1. **TLS spike**: build-bearssl.sh + a ~120-line server loading an EC key/cert
   from DER at runtime; proved a static binary serves HTTPS reachable by
   curl -k before any panel code existed.
2. **zurvan-certgen**: EC keygen + hand-rolled self-signed X.509; validated on
   the host with `openssl x509 -text` (parses) and `openssl verify` (self-sig
   OK) and by BearSSL serving it.
3. **zurvan-face**: TLS core from the spike + HTTP/1.1 parse + token auth +
   server-rendered HTML (inline CSS, dark theme, no framework) + the views,
   each shelling to a CLI. Host smoke test with stub CLIs drove auth + views
   over curl -k before QEMU.
4. Wiring: face/Makefile (links libbearssl.a), make init/clean, build.sh ships
   both binaries, face.def, provisioner first-boot cert+token gen with the
   token logged, example.yaml enables face. QEMU acceptance test.

## Key files
| path | role |
|---|---|
| `face/zurvan-face.c` | TLS server, auth, routing, all views (read whole) |
| `face/zurvan-certgen.c` | first-boot EC key + hand-rolled self-signed cert |
| `userland/build-bearssl.sh` | static BearSSL archive |
| `svc/zurvan-svc.c` | gained `state` / `restart` subcommands for the panel |
| `packages/provisioner/zurvan-provision` | makes/prints the identity + token, enables face |
| `tests/m6-face.sh` | drives the panel over its own HTTPS |

## Problems hit
- **X.509 from scratch is exact or nothing**: a self-signed cert is TBS →
  SHA-256 → ECDSA → wrap, with DER length bytes that depend on the (variable)
  ECDSA signature length. Built bottom-up with a tiny TLV writer and validated
  against real OpenSSL (`x509 -text` + `verify`) on the host — a fast loop, not
  a QEMU one. Got it right by testing the encoder in isolation first.
- **SIGCHLD=SIG_IGN silently broke exit codes**: with it set, the kernel
  auto-reaps children and run()'s waitpid returns ECHILD — output was still
  captured (so the host smoke test passed) but exit codes were lost. Removed
  it; run() reaps its own children and no handler is needed.
- **The default GRUB entry logs to tty0, not the captured serial** — so the
  "token printed to console" claim can't be read from QEMU's -display none
  stdout. The test verifies the token over SSH and treats the console print as
  code-guaranteed (the provisioner logs it unconditionally). Same reason the
  M4/M5 tests drive over SSH, not the console.
- **Format-truncation warnings on path buffers**: sized buffers to fit
  /data + a 255-byte dirent rather than suppressing the warning.
- **Empty page in a real browser (curl was fine)** — found by the user
  testing the ISO. bprintf() used a fixed 1024-byte scratch buffer, but the
  page CSS alone is ~1.1KB, so every page's `<style>...</style>` was truncated
  mid-CSS: the `<style>` tag opened and never closed, and a browser swallowed
  the whole body as stylesheet text → blank page. curl and the grep-based
  tests still found the bytes, so they passed. Lesson: assert well-formedness
  (closed tags), not just substring presence. Fixed bprintf to measure with
  vsnprintf(NULL,0,...) and grow — no truncation anywhere.
- **Boot logs printed on top of the shell prompt**: the supervisor's async
  "started X" lines landed after PID 1 drew the prompt. PID 1 now sleeps 1s
  after spawning the supervisor, before the first interactive shell, so the
  initial service lines flush first. (Cosmetic; also user-reported.)

## Verification
Host: certgen output parses+verifies in OpenSSL and serves under BearSSL;
face smoke test (stub CLIs) passes the auth gate, login/cookie, and every
view over curl -k. QEMU `tests/m6-face.sh`: A panel enabled by default, TLS
identity + hex token made at first boot, reachable over HTTPS; B no cookie →
redirect to /login, wrong token rejected, correct token logs in; C services/
overview/snapshots/jobs render live; D editing /data/zurvan.yaml through the
panel round-trips (read back changed over SSH); E a job submitted in the Run
box actually ran in a snake sandbox (artifact in /data/snake/results); F the
cert fingerprint and token are unchanged across a reboot. MILESTONE 6
DONE-WHEN: PASS.

## Follow-up fixes (2026-07-08, from real VMware testing)
Each was found by the user booting the ISO, not by the tests — a reminder that
acceptance greps miss what a browser/human sees:
- **Blank pages in a real browser**: bprintf() truncated the ~1.1KB CSS at a
  fixed 1024-byte buffer, breaking every `<style>`. Fixed to measure+grow.
- **Boot logs over the shell prompt**: PID 1 now settles 1s before the first
  interactive shell so the supervisor's start lines flush first.
- **GRUB `?` glyphs**: em dashes in the installed menu titles → ASCII.
- **Reboot button did nothing / blank page**: hardcoded `Content-Length: 20`
  truncated the response, AND plain `reboot` signals PID 1 with SIGTERM which
  it ignores — needs `reboot -f` (forced syscall).
- **/etc/inputrc error at boot**: readline forbids inline comments on `set`
  lines (swallows them into the value; silently disables booleans). All
  comments moved to their own lines. Fixes flaky TAB completion.
- **Services page second row garbled**: strtok is not reentrant, and
  uptime_for_pid()/scan_listens() tokenize too — clobbering the outer line
  loop. Switched to strtok_r everywhere.
- **UX additions**: uploads (multipart) on Packages/System/Files; files
  rename/copy/delete; package install-state + uninstall; Services/Overview
  labeled tables with live **ports** (from /proc/net/tcp + /proc/<pid>/fd) and
  adaptive **uptime**; human-readable file sizes; `zurvan-panel` command to
  reprint the URL+token after the console scrolls; serial entries tucked into a
  GRUB "Advanced" submenu (needs `export trial standby` — submenu scope).

## Deferred / rabbit holes avoided
No web terminal (the Run box is the snake). No multi-user/RBAC (one admin
token). No multipart upload (bundles/packages come from /data). No live
websockets/auto-refresh (a reload is fine for a panel). No HTTP/2, no
keep-alive, no concurrency. TLS 1.2 only (BearSSL 0.6). The cert is
self-signed — a real CA/ACME story is out of scope for a headless box.

## Post-v2.0.0 polish (2026-07-09)

User feedback from running the released ISO:

- **Services enable/disable** (panel + CLI). `zurvan-svc disable NAME` drops a
  marker file the heartbeat honors: the service is SIGTERMed, not rescheduled,
  and refused a start while the marker exists; `enable` unlinks it and the
  1-second loop starts the service right back. Markers live in
  `/data/svc/disabled/` so a disable **survives reboot** (the YAML still says
  what the box *wants*; the marker is the admin's persistent off-switch); a
  diskless boot falls back to `/run/svc/disabled` because the sealed read-only
  root makes the /data mkdir fail with EROFS — the fallback is automatic, not
  configured. `state` now reports `stopping`/`disabled`, and the panel renders
  an Enable button for those rows — with a special confirm when disabling
  `face` itself, which stops the panel you are clicking in.
- **Files: New folder / New file.** mkdir is a tiny new POST; a *new file* is
  deliberately not — it is the existing editor pointed at a path that does not
  exist yet (`O_CREAT` on save was already there). One feature for free.
- **Editor back link.** Saving re-renders the editor (it never navigated), so
  the only way out was the top tabs. The editor now links back to the
  directory the file lives in — and the old `cancel` link, which always went
  to the /data root, goes there too.
- Test suite grew sections **G** (mkdir, editor-born file, back link) and
  **H** (disable kills ssh, survives a panel-driven reboot, enable restores it
  — asserted over HTTPS while ssh is the thing being disabled).

### Follow-ups the same day (user testing the panel)
- **Enable/disable didn't refresh the state** — clicking Disable showed
  `stopping` and stuck there until a manual reload; enable showed the old
  state too. The handler redirected the instant `zurvan-svc` returned, but the
  supervisor only acts on its 1-second heartbeat, so the redirected page was a
  correct snapshot of a state about to change. Added `svc_settle()`: after an
  enable/disable the handler briefly polls `zurvan-svc state` until the service
  reaches the settled word (or a ~2.5–3s cap for a crash-looper), so the page
  the browser lands on is already right. Test H now follows the redirect
  (`curl -L`) and asserts `disabled` appears with no reload.
- **`zurvan-pkg install` exited 1 on non-service packages** (found while
  packaging sqlite3/curl) — its last line was `[ -f …$name.def ] && log …`,
  false for anything without a service block, and that false status became the
  script's exit code, breaking `install && next` callers. Now an `if`.

### Catalog grew (2026-07-09)
Beyond nginx: **sqlite3** (amalgamation → one static shell binary; FTS5+RTree;
extensions off — no loader) and **curl** (TLS via the panel's own BearSSL, CA
bundle shipped inside the package; `curl_LDFLAGS=-all-static` because libtool
drops a plain `-static`). Both verified on a fresh install: install exit 0,
`sqlite3 select` returns, curl reports BearSSL and validates a real public
cert. busybox already covers DHCP/DNS server duty (`udhcpd`, `dnsd`, `ntpd`,
`httpd`), so dnsmasq was skipped as redundant.
