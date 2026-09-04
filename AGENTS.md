# omarchy-portal contributor rules

Portal is an Omarchy bar plugin for listening TCP ports. It provides Portless
names, Cloudflared and ngrok sharing, charts, and process lifecycle actions.
The UI is QML. Helpers are Bash and Python.

## Code map

- `Service.qml` owns polling, IPC, and actions.
- `BarWidget.qml` is the per-monitor widget and lazy panel loader.
- `PortalPanel.qml`, `PortRow.qml`, `PortDetail.qml`, `SparkCard.qml`,
  `LinkText.qml`, and `TickerText.qml` make up the UI.
- `lib/*.js` contains pure classification and formatting code.
- `scripts/portal` is the CLI. `scripts/tunnels.sh`, `scripts/lifecycle.sh`,
  `scripts/metrics.sh`, and the setup and uninstall scripts own effects.
- `scripts/lib/files.sh` wraps shell state access. `scripts/lib/statedir.py`
  owns descriptor-relative state and launches. `scripts/lib/proc.py` owns
  capped runs, process identity checks, and pidfd leader signals.

## Commands

```sh
bash test/test.sh          # syntax, manifest, Node and shell suites, JSON contracts, qmllint, glyphs
bash test/scripts.test.sh  # shell suite
bash test/e2e-live.sh      # 19 listeners, plus Ruby and Deno when available
dev/portal.sh status|parity|stage|sync|reload [--hard]|restart-shell
```

The live farm copies Node to `tmp/bin`. The copy has no file capabilities that
could hide socket ownership from `ss`. The farm records each PID with its
kernel start time and checks both before teardown. Never pattern-kill it.

## Signal safety

A past test put PID `1` in a mock pidfile. `kill -SIG -- -1` then signaled every
process owned by the user and killed the desktop session.

- Never use PID 0, PID 1, or any PID below 2 in a fixture or path that can call
  `kill`. Use `999999 1` for a dead test identity. The command and start checks
  still reject it.
- Keep every `stop_line` and `group_alive` guard. Require a PID that matches
  `^[1-9][0-9]*$`, a numeric start time, a passing `alive_line` command and
  kernel-start check, and `pid > 1` before `kill -- -pid`.
- Stub signals before every dangerous live test. Shadow `kill` and `proc` with
  logging shell functions. Cover `1 1`, `0 0`, `-1 1`, empty values, huge
  values, and a non-numeric start time. Assert that the log has no `-1` or `-0`
  process-group target. Run the live suite only after these checks pass.
- After a sleeper test, run `pgrep -f "sleep [3]00"`. The brackets stop `pgrep`
  from matching its own command line.
- A `state launch` child keeps only file descriptors 0, 1, 2, and its
  executable. Prove this through `/proc/<pid>/fd` and a separate
  `flock -n -x` attempt. An inherited lock descriptor holds the lifecycle lock
  for the tunnel lifetime and can hang uninstall.

## Installed plugin proof

The shell loads `~/.config/omarchy/plugins/g3ortega.portal`, not this worktree.
Use the staged index as the only source for the installed proof.

1. Finish one change and run its focused checks.
2. Run `git add -A`, `dev/portal.sh stage`, and `dev/portal.sh parity`.
   `stage` copies the index without pushing and stages the installed clone.
3. Run `dev/portal.sh restart-shell`. A panel needs a fresh QML engine.
4. Drive the real path through the installed plugin. Put temporary IPC verbs
   only in the installed clone. Capture screenshots with `grim` and inspect the
   pixels. Check journal entries written after the restart cursor.
5. Revert every probe. Restore tracked probe edits from the installed index,
   remove probe files, run `stage` again, and restart the shell.
6. Run `parity`, the final smoke path, and `git status` in both checkouts.
7. Commit only after the proof passes. Run `dev/portal.sh sync` to push, fetch,
   merge with `--ff-only`, and prove parity again.

Do not push a UI or behavior change before this proof. The installed clone must
end clean. It must contain no probe file.

`parity` excludes `.git`, `dev`, `tmp`, and `__pycache__`. `sync` requires
parity before push and after merge. It refuses installed-only unstaged files.

## QML iteration

- File-watcher reloads can reuse an existing panel object. A confirmed reload
  can still show stale panel code. Trust a shell restart for panel proof.
- `dev/portal.sh reload` captures a journal cursor before `touch`. It accepts
  only a later `reloading: g3ortega.portal` line.
- `reload --hard` disables and enables the plugin. That operation resets widget
  settings in `shell.json`. Keep its backup in a private `mktemp -d` directory.
  Restore it on success, command failure, or signal. Compare the restored bytes
  with `cmp` before deleting the backup.
- Never rewrite watched QML in place. Write beside the destination and use an
  atomic `mv`. `stage` uses rsync's temporary-file rename behavior.
- Treat widget entry-point renames as unsafe until proved. They have caused
  persistent `File name case mismatch` failures.
- A resting `TickerText` can look exactly like `Text`. For motion proof, force
  long content or hover only in the installed clone. Remove the probe afterward.

## Headless UI tools

- Use `grim` for full screenshots and `grim -g "x,y wxh"` for a region.
- `hyprctl cursorpos` is read-only. There is no mouse movement or click tool.
  `wtype` types only. Force a `hovered` binding for motion checks, then restore
  the standard `HoverHandler { id: ... }` binding.
- `omarchy-shell g3ortega.portal toggle` opens or closes the panel. A toggle can
  race a reload, so bracket it with screenshots.
- Check `journalctl --user` for QML load errors after reload and render. Run
  `qmllint` through `test/test.sh`.
- Standalone `qmlscene` cannot load `qs.Commons`. For a focused runtime test,
  create scratch `Style` and `Color` singletons with a `qmldir`, then delete the
  scratch directory.
- A throwaway shell plugin needs a `BarWidget` root, `moduleName`, validation,
  enablement, and `omarchy-shell shell rescanPlugins`. It changes the bar. Tear
  it down fully by disabling it, removing its directory and backup directories,
  checking `shell.json`, and taking a clean bar screenshot. Prefer `qmlscene`
  with stubs.

## Code rules

- Do not use `local` outside a Bash function. Tests source these files.
- `die()` prints `{ok:false,...}` and exits zero. Callers inspect `.ok`.
- Lifecycle locks use `files.sh`, `flock -n`, and fail-fast behavior. Never wait
  forever for a lock.
- Route state reads, writes, and launches through `statedir.py`. Do not follow
  symlinks. Resolve a binary, check its owner and ancestors, and execute the
  resolved path instead of trusting `PATH`.
- Render data-derived QML strings with `Text.PlainText`. Use
  `HoverHandler { id: ... }` for hover. Moments last five seconds. Setup guidance
  stays until Escape, replacement, or panel reopen.
- Comments explain a non-obvious reason. Keep helpers at top level with explicit
  arguments. Nested Bash functions leak globally and can see empty positionals.
- Use a long, one-line commit summary that names the behavior change. Reply to a
  review with `Done in <sha>: ...` and a thumbs-up reaction.

## Environment facts

- Portless can have a valid binary, CA, and Chrome NSS trust while its proxy is
  off. Its stale `proxy.port` does not prove a live proxy. Port 443 needs the
  displayed sudo command. Portal starts an unprivileged proxy on port 1355.
  `~/.portless/routes.json` survives proxy restarts.
- `PORTAL_STATE_DIR` holds runtime share files. `PORTAL_METRICS_DIR` holds watch,
  metric, trust, and install records. Uninstall removes only Portal filenames
  from an overridden shared directory.
- Node, Redis, and MySQL come from mise on this machine. `ss`, `jq`, `flock`,
  `certutil`, and `openssl` are expected. Optional checks degrade as documented.
- The Cloudflared installer verifies the pinned SHA-256 digest and ELF header.
  It reports the pinned release version but does not execute the download to
  discover that version.
