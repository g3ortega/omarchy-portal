# Directory review notes

The original [Portal submission](https://github.com/omacom/omarchy-plugin-marketplace/issues/4308)
closed without approval on September 13, 2026. Its last maintainer review
evaluated [d15f73b](https://github.com/g3ortega/omarchy-portal/commit/d15f73b7c14db44232ae1e93efd324453d04b048).
The fixes below need a fresh submission and validation against the final
published commit. Local checks are not marketplace approval.

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
not a security certification.

## September 14 security review

The review used the pinned
[WBSO guide](https://github.com/wbso-ai/omarchy-plugin-security-skill/tree/e8e590c460c31ccebbcc5e1ca123c5c568b26f46)
and the marketplace's current policy. Independent reviews covered state and
process handling, QML and scanning, and installation and network effects.

- The listening `ss` snapshot previously accumulated before its port-count
  limit. It now runs through the byte-capped supervisor and rejects excessive
  rows, including duplicate ports. `test/scan-tcp.test.sh` checks both sides of
  the 4 MiB and 16,384-row limits and real IPv4 and IPv6 sockets.
- The proposed tooltip injection does not apply to the inspected Omarchy host.
  `PanelActionButton` delegates to `PanelToolTip`, whose `Text` uses PlainText.
- Portless's response header does not authenticate its executable. The CA
  snapshot and import checks protect file integrity, not against an unrestricted
  same-user process that can already change NSS trust directly. The guide and
  source comments now state that limitation.
- The historical guide flags mutating IPC and distributed `AGENTS.md` files.
  The inspected marketplace policy does not impose blanket prohibitions on
  either. They remain disclosed manual-review considerations, not reasons to
  silently remove the documented CLI or contributor workflow.

An offline baseline used marketplace
[4a2bc86](https://github.com/omacom/omarchy-plugin-marketplace/commit/4a2bc86c61cd267366308db19fec5e83109b3d12).
It reported `needs-fixes`, selective disposition `review-required`, and
`blocksApproval: false`. Its `curl-pipe-shell` evidence points to
`ngrok_api_request`, where curl output goes to `head -c`, and an unrelated
local jq predicate in `stop_share`. Neither executes downloaded content.
This is a false-positive assessment for a maintainer to verify, not a clean
automated result. Installer, package-manager, service-management, and privilege
capabilities still require manual review. Package and privileged commands are
displayed for the user rather than silently executed.

The baseline used tracked local files, not GitHub's exact-SHA resolver. Repeat
official validation after publishing the final commit. Live public providers,
account health, and changes to the user's browser trust were not exercised
during this review.

## Follow-up source review

Manual review of `2c44293` reproduced three additional issues. This change
addresses them with focused regressions.

| Finding | Correction | Repeatable check |
|---|---|---|
| Proxy environment variables could redirect local probes | Local HTTP requests explicitly bypass proxies. | `bash test/local-proxy.test.sh` |
| Cloudflare adoption matched remote origins by port number | Parse NUL-separated argv and accept only unambiguous HTTP(S) loopback origins. | `bash test/cloudflared-targets.test.sh` |
| Public startup could succeed after the approved listener changed | Refresh socket ownership throughout URL and DNS waits and before success. Stop the new tunnel on failed attribution. | `bash test/public-start-revalidation.test.sh` |

Startup checks bound detection time. They cannot make ownership of a TCP port
atomic with provider requests.

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

## Verification coverage

`test/test.sh` runs the following controlled cases as well as the state,
process, scanner, QML, and chart suites. Provider binaries and signals are
stubbed where a case requires an invalid identity or intentional failure.
These fixtures do not prove a provider account or external network is healthy.

| Area | Cases |
|---|---|
| Optional tools | All eight installed/missing combinations; each present executable independently rejected when writable by others; mixed configuration failures leave healthy providers available |
| Public startup | Both Cloudflare and ngrok; listener replacement, absent listener, socket query failure, DNS waits and resolution, final publication, failed cleanup, provider rejection, ready and pending DNS |
| Local naming and trust | Proxy off, wrong port or TLD, foreign proxy, missing trust tools, private NSS import/removal, interrupted setup, rollback and protected routes |
| UI actions | Missing tools hide actions; changed owners/providers invalidate confirmation; busy actions cannot submit twice; focus, Escape and backdrop cancellation |
| Metrics | HTTP/TCP isolation, six ranges through 48 hours, missing samples, stale reads, retries, bounded queues and retention, shared storage and permissions |
| Process controls | Identity checks before signals, invalid group targets, pause/resume, exact restart arguments and environment, timeouts and cancellation |

`test/e2e-live.sh` adds real listeners and checks detection, probes, metrics,
process controls, CLI and the installed plugin's IPC. The installed panel proof
also exercises range and transport switching, confirmation, settings
persistence, notices, and rendering in the actual host shell.

This is a matrix of supported states and failure boundaries, not every possible
combination of network, desktop, browser, and provider account state. External endpoint checks need a working network. ngrok also needs an account
and authtoken.

The follow-up local run passed real Cloudflare endpoint creation, retrieval of
a fixed test response, and teardown. A temporary Portless name served the same
response and was removed. ngrok was not installed on this machine, so its live
account and network path was not tested. Its unavailable UI state, configuration
failures, and startup paths were covered by controlled fixtures.
