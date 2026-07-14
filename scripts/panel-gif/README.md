# panel-gif — regenerating the README hero GIF

`docs/panel.gif` is an animated tour of the web admin panel: Overview,
Services, Snapshots, Jobs, Files, Packages, System, and the sign-in page
as a closing frame. 1120x680, ~160 KB, 2.8 s on the opening frame and
2.1 s per page after that.

## Quick path: re-render from the committed frames

`frames/` holds the self-contained HTML of each page (inline CSS — they
render standalone), captured from a real seeded box. If the panel's look
hasn't changed, regenerating the gif is two commands on Windows:

```powershell
cd scripts\panel-gif
npm install          # once; pulls gifenc + pngjs
& .\render.ps1       # screenshots frames\*.html, writes docs\panel.gif
```

`render.ps1` screenshots each page with headless Microsoft Edge at the
gif's **native 1120x680** and `assemble.js` composites the shots onto a
`#0f1115` canvas, quantizes per frame, and writes `docs/panel.gif`.

Hard-won details baked into the scripts — keep them if you rewrite:

- **Native scale, no downscale pass.** Screenshotting larger and scaling
  down (tried at 1640 → 820) makes the text tiny and the extra
  re-quantize speckles the flat dark background.
- Edge needs its **own `--user-data-dir`** or the running Edge singleton
  silently swallows the headless call; launch via `Start-Process`, not
  `&`, so Edge's stderr doesn't trip PowerShell's NativeCommandError.
- Frames sort by filename; the login page is `9-login.html` so it plays
  **last** (the tour ends where a new user would begin).
- The README embeds the gif with **no `width` attribute** — GitHub caps
  it at the content column; a hardcoded width only shrinks it.

## Full path: recapture the frames from a live box

When the panel's pages change, refresh `frames/` from a real system so
the data is honest (real uptimes, PIDs, snapshot sizes):

1. **Boot a seeded box.** Install the current ISO to a disk in QEMU
   (see `tests/` for the pattern), provision a `zurvan.yaml` with an ssh
   key and services `networking ssh face lion snake`, boot with
   `hostfwd tcp::2222-:22,tcp::8443-:8443`.
2. **Seed data over ssh** so every page has something to show:
   `zurvan-pkg install/enable nginx` (+ a few more packages, or upload a
   whole `zurvan-catalog-*.tar.gz` on the Packages page — one curl
   `-F file=@...` fills the list), a few `zurvan-lion snap`, some files
   under `/data`, and a job via `POST /jobs/run` (field is `script=`,
   use `--data-urlencode`). Grab the token from `/data/face/token`.
3. **Save each page's HTML**: log in with curl (`-sk -b cookiejar`),
   then fetch `/ /services /snapshots /jobs /files /packages /system`
   into `frames/` using the `1-overview.html` … `7-system.html` names
   (login is served at `/login` when unauthenticated).
4. Run the quick path above.
