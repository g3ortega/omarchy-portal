# Metric history and time ranges

Portal opens the last hour by default. The six shared ranges are 30m, 1h,
3h, 6h, 1d, and 2d. Recording retains 48 hours of raw samples. Selecting a
range changes a query, not retention. Stopping Watch pauses recording.

## Why the charts could appear to lose data

The old renderer selected every Nth sample. Real MySQL history contained CPU
peaks between those selected points. The caption reported the correct peak,
but the line never reached it.

The detail page also held a fixed disk prefix followed by a mutable live ring.
As the ring evicted its oldest samples, a gap appeared after the prefix until
the page reopened. Those records could still exist on disk. With a short ring,
QML could retain the same array identity and fail to update the graph binding.

The new reader returns a fresh, bounded range snapshot. Each time bucket has
minimum, maximum, average, and non-null count for each metric. Captions use
exact range bounds. The plot draws the extrema and average. Hover describes
an interval instead of claiming that an average was an instantaneous reading.
Empty buckets break the line. Within a bucket, finer gaps are below the chart's
resolution. Raw samples remain in the database.

## Storage choice

The source review covered Omarchy's clipboard and notifications plugins and
the installed quickshell.spotify plugin.

| Plugin | Storage pattern | Lesson for Portal |
| --- | --- | --- |
| Clipboard | One JSON file, bounded to 300 entries | Whole-file JSON suits small histories. |
| Notifications | Separate bounded history files, atomic settings writes, 200 ms settings debounce | Keep settings separate and batch small writes. |
| Spotify | Normalized session JSON, 12 search terms, no-op detection and debounced atomic writes | Persist durable state separately from caches. |

The inspected files were `/usr/share/omarchy/shell/plugins/clipboard/Clipboard.qml`,
`/usr/share/omarchy/shell/plugins/notifications/Service.qml`, and
`~/.config/omarchy/plugins/quickshell.spotify/Service.qml`.

These implementations suit small histories. Metric history needs indexed
time queries and bounded chart responses. Hourly files would require a
segment index, range reader, and retention walker.

SQLite provides transactions and indexed time queries through the existing
Python helper. No database daemon or Rust build is needed. Arch's
[Quickshell package](https://archlinux.org/packages/extra/x86_64/quickshell/)
requires [Qt 6](https://archlinux.org/packages/extra/x86_64/qt6-base/), which
requires [SQLite](https://archlinux.org/packages/core/x86_64/sqlite/files/).
The SQLite package includes the CLI. This dependency chain was also verified
with the installed package database.

## Ownership and recovery

The statedir helper owns database access. It binds an owner-only directory,
checks regular file ownership, permissions and link counts, and launches the
validated SQLite executable. SQLite opens the fixed database name with
`--nofollow` from the bound working directory. Extension loading is disabled.
SQL identifiers are fixed; interpolated values are validated numbers or
restricted batch identifiers.

SQLite performs its own named database and journal I/O. This is a distinct
boundary from statedir's descriptor-relative JSON file operations. It does not
claim protection from a hostile process with the same UID racing the private
namespace. Planted database and sidecar links are refused.

DELETE journaling uses fewer sidecars than WAL and matched its measured write
performance here. FULL synchronization and the nonblocking Portal metrics lock
protect transactions. A row ID preserves samples with duplicate timestamps.
Stable batch IDs make retries idempotent after an uncertain write result.

A fresh store creates the current SQLite schema directly. Normal recording
prunes database samples older than 48 hours.

Writes are observed by the service. Failed batches remain queued for retry.
The service serializes chart reads with writes and drains queued writes before
starting a range query. During write retry backoff, reads can still show saved
history. Large scans split into batches of at most 512 samples.
A live lock-failure test exposed read/write competition
during recovery; the scheduling check now covers that case.
The queue is capped at 120 batches and 2 MiB of serialized text. If the queue
fills, the detail page reports a recording gap. This is a bounded recovery
buffer, not a promise to record indefinitely with unavailable storage.

## Measurements

Before the change, rebuilding the actual installed MySQL chart view took
13.0–14.8 ms per iteration for about 17,293 samples. The query contract now
limits QML to 400 time buckets regardless of raw history size.

Storage prototypes ran on both tmpfs and the machine's btrfs filesystem.
Only btrfs results represent durable device writes. A fresh SQLite CLI process
writing a 12-row FULL transaction took a median 26.2 ms on btrfs. DELETE and
WAL had similar timings. These prototype timings exclude Portal's surrounding
helper startup and validation.

The final full-helper test used 414,720 raw rows across twelve ports on btrfs,
representing 48 hours at five-second intervals. The database and two indexes
used 35.6 MB. Reusing the existing stable lock inside the Python command removed
redundant helper launches. Twelve-port append latency fell from 219 to 108 ms.
Range queries fell from 217–276 ms to 86–134 ms. Those measurements include
Bash, Python, SQLite, validation, and synchronization. Responses stayed between
150 and 169 KB with long fractional values across all four metrics.

Timings describe this machine and fixture, not every disk.

Shared Quickshell RSS includes every loaded plugin. It cannot be attributed
to Portal alone, so chart-processing and helper costs are reported separately.

## Installed verification

The installed plugin matched database counts and CPU peaks for all six ranges.
Rapid range changes retained the latest request, and port navigation kept the
selected range. With the panel closed, recording continued without range reads.
A deliberate lock refusal displayed the storage failure, then drained all queued
writes and cleared the error after release.

## Separate HTTP and TCP measurements

The schema stores nullable `tcpRttMs` and `tcpRttCount` fields separately
from HTTP response duration in `latMs`. Missing measurements remain null.

The scanner obtains TCP RTT from the established-socket snapshot it already
uses for connection counts. It averages the kernel RTT estimates across sockets
with values at each local port. `tcpRttCount` records the contributing socket
count. Chart buckets average those scan means, without weighting scans by
socket count. A missing estimate stays null. Estimates can persist while
connections are idle, so these samples are observations of kernel state rather
than fresh request timings.

This approach creates no connections and sends no application payloads. An
active TCP handshake can finish before the application accepts a connection.
WebSocket Ping requires an established session with the correct endpoint and
authentication. Neither is a suitable automatic application-health check.
See the [ss manual](https://man7.org/linux/man-pages/man8/ss.8.html) and
[WebSocket protocol](https://www.rfc-editor.org/rfc/rfc6455.html#section-5.5.2).

A 400-bucket response with five metrics and long fractional values
measured 233,366 bytes locally. SQLite versions format the intermediate SQL
JSON differently, and the Ubuntu CI version exceeded the original 256 KiB
limit. The SQL response limit is now 512 KiB. The fixed projection has at most
400 rows of 22 numeric members. Allowing 40 characters per number and the
longest field name keeps that projection below 512 KiB without reducing
precision. The 400-bucket limit and outer 4 MiB helper-output limit are unchanged.

A 16,384-socket fixture near the 4 MiB snapshot limit exposed repeated string
copies in the first parser. One streaming aggregation pass reduced that case
from 11.054 seconds to 0.185 seconds on this machine. Locale-independent byte
counting rejects oversized snapshots. Real IPv4 and IPv6 fixtures confirmed
passive RTT values without HTTP probes.
