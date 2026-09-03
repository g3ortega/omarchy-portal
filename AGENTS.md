# AGENTS.md — omarchy-portal contributor notes

Portal: an Omarchy bar plugin showing every listening TCP port, what runs on
it, with local naming (Portless), public sharing (cloudflared/ngrok), charts,
and pause/resume/restart/stop. QML UI + bash/python helpers.

## Layout

- `Service.qml` — single source of truth: polling, IPC target, all actions.
- `BarWidget.qml` — thin per-monitor widget, lazy panel loader.
- `PortalPanel.qml`, `PortRow.qml`, `PortDetail.qml`, `SparkCard.qml`,
  `LinkText.qml`, `TickerText.qml` — UI. `lib/*.js` — pure classify/format.
- `scripts/portal` — CLI. `scripts/tunnels.sh` — providers + tunnel lifecycle.
  `scripts/scan-ports.sh` — evidence gatherer. `scripts/lifecycle.sh`,
  `scripts/metrics.sh`, `scripts/portless-setup.sh`,
  `scripts/provider-install.sh`, `scripts/uninstall.sh`.
- `scripts/lib/files.sh` — shell wrappers. `scripts/lib/statedir.py` —
  descriptor-relative state (all reads/writes/launches go through it).
  `scripts/lib/proc.py` — capped runs, pidfd-bound signals.
- `test/test.sh` (full gate), `test/scripts.test.sh` (shell suite),
  `test/detect.test.mjs`, `test/e2e-live.sh` (live farm).

## Test commands

```sh
bash test/test.sh          # full gate: syntax, manifest, 60 detect, 157+ shell,
                           # scan/setup/provider JSON, qmllint, glyphs
bash test/scripts.test.sh  # shell suite alone
bash test/e2e-live.sh      # 21 real servers; farm in tmp/ (gitignored)
dev/portal.sh status|sync|reload [--hard]|restart-shell
                           # local-install lifecycle: health, push/pull + parity
                           # proof, settings-preserving reloads, fresh engine
```

- `e2e-live.sh` runs an **unprivileged copy** of node (`cp` drops file
  capabilities). The mise node carries `cap_net_bind_service`, which makes its
  processes non-dumpable so `ss -tlnp` cannot attribute sockets — do NOT
  "fix" this with setcap; the copy is the fix.
- Live suites spawn real processes and signal only PIDs they harvested by
  port through the same attribution the product uses. Teardown is pid-file
  exact — never pattern-kill.

## Safety rules (learned from a real outage)

- A test once wrote mock pidfiles containing pid `1` while `stop_line`
  signalled process groups (`kill -SIG -- -$pid`). `-1` broadcasts to **every
  process of the user** — Hyprland, systemd --user and the whole session died,
  three times. Rules:
- NEVER use pid 0/1 (or anything ≤1) in fixtures or code paths reaching
  `kill`. Dead-test PIDs look like `999999 1` (comm+start still refuse them).
- `stop_line`/`group_alive` require `^[1-9][0-9]*$`, a numeric start time, a
  passing `alive_line` (comm + kernel start), and `pid > 1` before any
  `kill -- -pid`. Keep every one of those guards.
- Prove dangerous paths with **stubbed signals first**: shadow `kill`/`proc`
  as logging shell functions (no real signal can fire), cover crash inputs
  (`1 1`, `0 0`, `-1 1`, empty, huge, non-numeric start), and assert the kill
  log never contains a `-1`/`-0` group target. Only then run the live suite.
- After any test that launches sleepers, verify no strays with
  `pgrep -f "sleep [3]00"` (bracket form avoids matching grep itself —
  a bare `pgrep -f "sleep 300"` matches its own command line).
- `state launch` children must keep only fds 0,1,2 + the executable: an
  inherited lock descriptor stays open for the tunnel's whole life (proven
  via `/proc/<pid>/fd` + a cross-process `flock -n -x` attempt), silently
  holding lifecycle locks and hanging uninstall forever.

## Shell / QML iteration gotchas (all observed live)

- The running shell serves `~/.config/omarchy/plugins/g3ortega.portal`
  (a separate clone), NOT this workdir. Sync via commit → push → pull there,
  then prove parity:
  `diff -r Work/omarchy-portal <install> --exclude=.git --exclude=tmp --exclude=__pycache__ --exclude=dev`
- File-watcher reloads are **unreliable for panel code**: same-URL components
  get reused and an already-created panel object is never rebuilt — a forced
  on-disk change with confirmed reload lines still rendered stale content.
  Trustworthy refresh, in escalating order:
  1. `touch` the file, confirm `reloading: g3ortega.portal` in
     `journalctl --user` (sometimes silently doesn't fire — re-touch).
  2. `omarchy plugin disable/enable <id>` (destroys widgets; **resets that
     widget's shell.json settings — back up shell.json first, restore after**).
  3. `omarchy-restart-shell` (supported; fresh engine; bar blips; refuses
     while the session is locked).
- Never rewrite a watched QML file in place (the watcher loads torn files):
  write temp + atomic `mv`.
- Do not rename a widget entry-point file casually: renames produced
  persistent `File name case mismatch` load failures (mechanism not fully
  pinned down — treat renames as suspect until proven).
- At-rest visual identity is a trap: TickerText renders exactly like the Text
  it replaces, so screenshots cannot distinguish old vs new code. Fingerprint
  versions with temporary forced content (long text / forced hover) reverted
  afterwards — never ship probes (installed dir must end `git status` clean).

## Headless UI e2e toolkit (no mouse control exists)

- `grim` screenshots (view them with Read); `grim -g "x,y wxh"` for regions.
- `hyprctl cursorpos` is READ-ONLY. No movecursor/click automation
  (`wtype` types only). Real hover cannot be simulated — drive `hovered`
  bindings with forced values for motion proofs, and use the standard
  `HoverHandler.hovered` idiom (same mechanism all existing hovers use).
- `omarchy-shell g3ortega.portal toggle` opens/closes the panel (state
  flips — bracket with screenshots, toggles race reloads).
- `journalctl --user` shows QML load errors; absence of errors after a
  reload + render is the load proof. `qmllint` via `test/test.sh` is required.
- Standalone `qmlscene` cannot load `qs.Commons` (Quickshell core plugin .so
  is not on its path). Workaround: stub singletons (`Style`, `Color` with
  only the used keys + a `qmldir`) in a scratch dir — real Qt runtime proof
  of animation/layout logic, then delete the scratch dir.
- Throwaway in-shell test plugins work (`BarWidget` root + `moduleName`,
  validate, enable) but need rescan (`omarchy-shell shell rescanPlugins`)
  when newly created, pollute the bar while present, and MUST be fully torn
  down afterwards (disable, remove, `rm -rf` the dir incl. `.bak` dirs,
  verify shell.json clean + bar screenshot). Prefer qmlscene+stubs.

## Code conventions

- Bash: no `local` outside function bodies (tests *source* these files —
  a top-level `local` breaks sourcing). `die()` prints `{ok:false,…}` and
  exits 0; callers check `.ok`. Trace concurrent paths with the lock helpers
  in `files.sh` (`flock -n`, fail fast, never block).
- State: everything through `statedir.py` (descriptor-relative, caps,
  atomic writes). Never follow symlinks, never trust PATH (`resolve_bin` +
  ancestor checks, execute by descriptor).
- QML: `Text.PlainText` for anything data-derived; `HoverHandler { id: … }`
  for hover; toasts are moments (`toastTimer`, 5s) except hints (setup
  guidance persists until Esc/replace/reopen).
- Comments explain *why*, in the file's terse voice. No NOTE-comments about
  the mechanism — restructure instead (nested bash functions leak to global
  scope and see empty positionals; keep helpers top-level with explicit args).
- Commit messages are long one-line summaries of the behavior change.
  PR review replies: `Done in <sha>: …` + 👍 reaction on the finding.

## Environment facts

- Portless: binary + CA + Chrome NSS trust are the steady state; the proxy
  itself is regularly just *off* (`proxy: off`, stale `proxy.port`).
  Privileged 443 needs the sudo command; the panel setup path uses
  unprivileged 1355. `~/.portless/routes.json` outlives proxy restarts.
- `PORTAL_STATE_DIR` (runtime, pid/url/reach/dns/idle/log) vs
  `PORTAL_METRICS_DIR` (watched.json, metrics, trusted-stores,
  installed-cloudflared). Overrides pointing at shared dirs only ever lose
  Portal's own filenames (see uninstall tests).
- This machine's node/redis/mysql come from mise; `ss`, `jq`, `flock`,
  `certutil` are assumed present with graceful degradation where noted.

## Workflow (hard rule: e2e before push)

- Never commit or push UI/behavior changes before proving them on the local
  install. Order: implement → sync the install → shell restart (only
  trustworthy rebuild) → drive the real path headlessly (temporary IPC verbs
  in the installed copy only, reverted afterwards) → screenshot and read the
  pixels → revert probes → restart again → verify parity → then commit/push.
- Temporary probes live in the installed clone only, never in a commit.
  Installed dir must end every session `git status` clean.
