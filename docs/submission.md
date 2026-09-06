# Directory review notes

The original [Portal submission](https://github.com/omacom/omarchy-plugin-marketplace/issues/4308)
is still open. Its last maintainer review evaluated `d15f73b`. The changes below
are present in merged commit `ad9ac95`, with documentation and action-dispatch
cleanup on top. Ask the directory to validate the final published commit.

## Previous review points

| Review point | Current implementation | Repeatable checks |
|---|---|---|
| State file path swaps and durability | `scripts/lib/statedir.py` walks verified directories, opens leaves with no-follow checks, and publishes exclusive temporary files with descriptor-relative rename and fsync. `files.sh` delegates state operations to it. | `bash test/scripts.test.sh`, `bash test/state-mode.test.sh`, `bash test/state-inspect.test.sh` |
| Certificate bytes changing between verification and import | `portless-setup.sh` snapshots the CA into `CA_PEM`, verifies the proxy certificate against those bytes, then verifies the opened import descriptor's fingerprint before passing that descriptor to certutil. Trust records support removal without deleting a replacement certificate. | `bash test/portless-trust.test.sh`, `bash test/scripts.test.sh` |
| Unbounded QML subprocess output | `Service.runScript` uses `proc.py run` with an output ceiling and deadline. The supervisor discards incomplete output and terminates the process group and reaps its child. The scanner separately caps fields and rejects more than 512 listener ports. | `bash test/scripts.test.sh`, `bash test/proc-cancel.test.sh`, `bash test/lifecycle-cap.test.sh` |
| Stale process identity during lifecycle actions | The scan carries PID and kernel start time. Lifecycle actions recheck exclusive port ownership and signal through a pidfd. Restart validates captured argv, environment, and the replacement listener's session. | `bash test/lifecycle-owner.test.sh`, `bash test/restart-boundaries.test.sh`, `bash test/restart-env.test.sh`, `bash test/restart-deadline.test.sh` |
| Installing through replaceable paths | The Cloudflared installer checks the pinned digest and ELF header through an opened download descriptor. `state create` publishes into the verified destination directory and refuses an existing target. | `bash test/provider-install.test.sh` |
| Restart argument transport and mutable CI inputs | Restart uses JSON and NUL-separated arguments. CI pins checkout and the Omarchy revision and verifies the downloaded font archive's SHA-256. | `bash test/restart-effect.test.sh`, `bash test/restart-duplicate-env.test.sh`, `.github/workflows/ci.yml` |

These references document how the earlier findings were addressed. They are
not a security certification. A fresh deep security scan was attempted during
this preparation round but did not start because its worker required a managed
filesystem permission profile. That review remains outstanding.

## Corrections to the original submission

- Portal does not run npm or another package manager. Missing Portless setup
  displays `npm install -g portless` for the user to run.
- Setup and sharing ask for confirmation in an overlay. Provider setup lives
  in Settings. Local proxies use port 1355 without sudo by default.
- The Cloudflared download is not executed to discover its version. The
  installer reports the release version pinned with its checksums.
- Runtime requirements include system Python 3 and SQLite. Browser trust also
  needs certutil and OpenSSL. See the [complete requirements](guide.md#requirements).
- Watched history uses SQLite and retains up to 48 hours. Unwatching pauses
  recording and preserves history. There is no legacy storage migration.
- The repository has multiple reviewed commits. It no longer uses the original
  single-commit submission history.

## Resubmission material

The root manifest, MIT license, README install and removal commands, preview,
and guide are present. The guide explains network requests, optional providers,
process controls, browser trust, and state storage. Screenshot project names and
public URLs use examples instead of local details.

Run the full gate from the final checkout before requesting another review:

```sh
omarchy plugin validate "$PWD"
bash test/test.sh
bash test/e2e-live.sh
```

The live suite uses temporary listeners. It checks fixture identity before
teardown. UI changes additionally require the installed proof described in
[the contributor guide](../AGENTS.md#installed-plugin-proof).
