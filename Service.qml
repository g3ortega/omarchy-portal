import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "lib/Detect.js" as Detect

// Portal's single source of truth.
//
// A service, not per-widget state: bar widgets are instantiated once per
// monitor, so polling here runs one scan per interval no matter how many
// screens are attached.
Item {
  id: root

  // Injected by the shell host when the service is mounted.
  property var manifest: null

  // __sourceDir is stamped onto the manifest by PluginRegistry. Normalise it:
  // depending on how the plugin was discovered it can arrive as a plain path
  // or a file:// URL.
  readonly property string pluginDir: {
    var dir = manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
    if (dir.indexOf("file://") === 0) dir = dir.substring(7)
    return dir.replace(/\/$/, "")
  }

  // ---- state ----------------------------------------------------------------
  property var ports: []            // decorated entries, see lib/Detect.js
  property var providers: []        // exposure providers and their readiness
  property var tunnels: ({})        // "provider:port" -> { url, reach }
  property bool everScanned: false
  property string lastError: ""
  property string busyAction: ""    // "provider:port" while a start/stop is in flight
  property int refreshSeconds: 5
  onRefreshSecondsChanged: refreshSeconds = Util.clamp(refreshSeconds, 2, 120)   // shell.json is hand-editable
  property string namingMode: "Project"
  property string portlessTld: "localhost"

  // Set false in onDestruction so in-flight Process callbacks stop touching a
  // half-torn-down object. A plugin reload destroys this while `ss` may still
  // be running.
  property bool alive: true

  // Identity vs. stats. `ports` carries what a row IS (port, process, project,
  // stack) and only changes when that changes — so open panels never rebuild
  // their delegates for a CPU tick. `stats` carries what a row is DOING
  // (connections, cpu, rss, uptime, paused) and is replaced every scan.
  property string _lastScanKey: ""
  property var stats: ({})
  property var _cpuPrev: ({})
  property var _prevDevPorts: null

  // Per-port sample rings for the analytics view: ~1h of 5s samples in
  // memory for every port, free of charge. Ports the user Watches also get
  // each sample appended to disk (metrics.sh, XDG_STATE, ~24h retention).
  property var history: ({})
  property int historyRevision: 0
  property var watchedPorts: []
  readonly property int maxSamples: 720

  readonly property int devCount: {
    var n = 0
    for (var i = 0; i < ports.length; i++) if (ports[i].category === "dev") n++
    return n
  }
  // Counted once here; the header pill, bar glyph, and tooltip all read
  // these instead of walking the map themselves.
  readonly property var tunnelCounts: {
    var pub = 0, named = 0
    for (var k in tunnels) {
      if (tunnels[k].reach === "public") pub++; else named++
    }
    return { pub: pub, named: named }
  }
  readonly property int tunnelCount: tunnelCounts.pub + tunnelCounts.named
  readonly property bool hasPublicTunnel: tunnelCounts.pub > 0

  signal actionFailed(string message)
  signal actionHint(string message)

  // A port can hold both a local name (portless) and a public tunnel at the
  // same time; they are different facts and the UI treats them differently.
  function routeFor(port) { return tunnels["portless:" + port] || null }

  function publicTunnelFor(port) {
    for (var k in tunnels) {
      if (tunnels[k].port === port && tunnels[k].reach === "public") return tunnels[k]
    }
    return null
  }

  // The address a port answers on, in one place. A local name beats the bare
  // host:port; a public tunnel is the last resort rather than the first,
  // because the name is what the user chose to call this thing.
  function urlFor(port, entryUrl) {
    var r = routeFor(port)
    if (r && r.url) return r.url
    if (entryUrl) return entryUrl
    var t = publicTunnelFor(port)
    return t && t.url && t.dns !== "pending" ? t.url : ""
  }

  function providerFor(id) {
    for (var i = 0; i < providers.length; i++) if (providers[i].id === id) return providers[i]
    return null
  }

  // Derived once here so the panel and the row cursor cannot index two
  // separately-built arrays that drift in order.
  readonly property var publicProviders: {
    var out = []
    for (var i = 0; i < providers.length; i++) if (providers[i].reach === "public") out.push(providers[i])
    return out
  }

  function parseJson(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }

  // Start `scripts/<script>` on `proc` unless it is already running. The
  // command is assigned here rather than as a binding: pluginDir is set by the
  // host after the Process objects exist, and an early binding would run
  // /scripts/... from the filesystem root.
  // Every helper runs under a hard deadline (timeout signals the whole process
  // group, so a stuck curl or portless call cannot outlive it) and every
  // helper's output is bounded by construction: capped fields, capped reads,
  // one JSON document. The seconds are per process, sized to the slowest
  // legitimate run of what it carries.
  readonly property var deadlines: ({ scan: 20, poll: 20, action: 330, quick: 15 })
  function runScript(proc, script, args, kind) {
    if (!alive || !pluginDir || proc.running) return false
    proc.command = ["/usr/bin/timeout", "-k", "5", String(deadlines[kind || "quick"]),
                    "/usr/bin/bash", pluginDir + "/scripts/" + script].concat(args || [])
    proc.running = true
    return true
  }

  // ---- scanning -------------------------------------------------------------
  // Probe HTTP latency only where it means something and was asked for: the
  // port whose charts are open, then watched ports, then dev servers with a
  // URL. The cap keeps a pathological port list from turning the scanner into
  // a load generator; ordering decides who gets starved by it.
  property int focusPort: 0
  function probeList() {
    var out = [], seen = ({}), live = ({})
    for (var i = 0; i < ports.length; i++) live[ports[i].port] = true
    function add(p) { if (p && live[p] && !seen[p]) { seen[p] = true; out.push(p) } }
    add(focusPort)
    watchedPorts.forEach(add)   // a watched port that is not listening must not spend the cap
    for (var j = 0; j < ports.length; j++) {
      if (ports[j].category === "dev" && ports[j].web) add(ports[j].port)
    }
    return out.slice(0, 8)
  }

  function refresh() {
    var probes = probeList()
    runScript(scanProcess, "scan-ports.sh", probes.length ? ["--probe", probes.join(" ")] : [], "scan")
  }
  // Every tunnels.sh call carries the configured TLD: status rungs judge
  // against it and start composes names with it, so the two must never
  // disagree about which suffix is in force.
  function runTunnels(proc, args, kind) {
    return runScript(proc, "tunnels.sh", ["--tld", portlessTld].concat(args), kind)
  }
  // A refresh that lands while the previous one is still running is dropped by
  // runScript. That is fine for a poll, but not for the refresh a settings
  // change depends on — the strip would keep advertising a fix for the TLD the
  // user just moved off. Try again shortly.
  function refreshProviders() {
    if (!runTunnels(providersProcess, ["providers"], "poll")) retryTimer.restart()
  }
  function refreshTunnels() { runTunnels(tunnelStatusProcess, ["status"], "poll") }

  Timer {
    id: retryTimer
    interval: 250
    onTriggered: root.refreshProviders()
  }
  onPortlessTldChanged: { refreshProviders(); refreshTunnels() }
  function refreshAll() { refresh(); refreshTunnels(); refreshProviders() }

  function applyScan(text) {
    var parsed = parseJson(text)
    if (!parsed || !Array.isArray(parsed.ports)) {
      lastError = "could not parse scan output"
      return
    }
    everScanned = true
    lastError = parsed.error ? String(parsed.error) : ""

    var now = Date.now()
    var nextStats = ({})
    var nextCpu = ({})
    var identity = []
    var devPorts = []
    var watchedBatch = ({})
    var seenPorts = ({})
    for (var i = 0; i < parsed.ports.length; i++) {
      var e = parsed.ports[i]
      var prev = e.pid != null ? _cpuPrev[e.pid] : undefined
      var cpuPct = null
      if (prev && e.cpuTicks != null && now > prev.t) {
        // ticks are USER_HZ (100/s); delta over wall time gives percent.
        cpuPct = Math.max(0, Math.round((e.cpuTicks - prev.ticks) / (now - prev.t) * 1000))
      }
      if (e.pid != null && e.cpuTicks != null) nextCpu[e.pid] = { ticks: e.cpuTicks, t: now }
      var st = {
        t: Math.round(now / 1000),
        conns: e.conns,
        cpuPct: cpuPct,
        rssKb: e.rssKb,
        upSec: e.upSec,
        latMs: e.latMs,
        httpCode: e.httpCode,
        paused: e.procState === "T"
      }
      nextStats[e.port] = st
      var sample = { t: st.t, conns: st.conns, cpuPct: st.cpuPct,
                     rssKb: st.rssKb, latMs: st.latMs, httpCode: st.httpCode }
      var ring = history[e.port] || []
      ring.push(sample)
      if (ring.length > maxSamples) ring.splice(0, ring.length - maxSamples)
      history[e.port] = ring
      if (watchedPorts.indexOf(e.port) !== -1) watchedBatch[e.port] = sample
      seenPorts[e.port] = true
      identity.push([e.port, e.addresses, e.pid, e.comm, e.cmdline, e.cwd,
                     e.projectRoot, e.projectName, e.markers, e.deps])
    }
    _cpuPrev = nextCpu
    stats = nextStats
    historyRevision++

    // One append call per scan covers every watched port; a lost batch is
    // just a lost batch (metrics.sh re-validates before disk).
    if (pluginDir && Object.keys(watchedBatch).length > 0) {
      Quickshell.execDetached(["/usr/bin/timeout", "-k", "5", "15", "/usr/bin/bash", pluginDir + "/scripts/metrics.sh",
                               "append-batch", JSON.stringify(watchedBatch)])
    }

    // Rings for ports that vanished stop occupying memory.
    for (var hk in history) {
      if (!seenPorts[hk]) delete history[hk]
    }

    var key = JSON.stringify(identity)
    if (key === _lastScanKey) return
    _lastScanKey = key

    var out = []
    for (var j = 0; j < parsed.ports.length; j++) {
      var d = Detect.decorate(parsed.ports[j])
      out.push(d)
      if (d.category === "dev") devPorts.push({ port: d.port, label: d.label })
    }

    _notifyVanishedDev(devPorts)
    _prevDevPorts = devPorts

    ports = out
  }

  // Public tunnels whose target is no longer listening. tunnels.sh keeps one
  // open for a while (a dev server restart should not lose the URL you handed
  // out) and then stops it; meanwhile it must stay visible and stoppable.
  readonly property var orphanShares: {
    var live = ({})
    for (var i = 0; i < ports.length; i++) live[ports[i].port] = true
    var out = []
    for (var k in tunnels) {
      var t = tunnels[k]
      if (t.reach === "public" && !live[t.port]) out.push({
        port: t.port, pid: null, comm: "", cmdline: "", cwd: "", projectRoot: "", scope: "local",
        addresses: [], kind: "orphan", label: "shared while nothing listens", icon: "broadcast",
        color: "", category: "dev", web: false, name: "port " + t.port, url: "", argv: [],
        argvTruncated: false
      })
    }
    return out
  }

  // A dev server that vanished between scans is a crash until proven
  // otherwise, unless Portal itself just stopped or restarted it. Text is
  // built only from the port number and the rule's own label, never from
  // process-controlled strings.
  property var _expectedGone: ({})
  readonly property int expectedGoneMs: 20000
  function _expectGone(port) { _expectedGone[port] = Date.now() }

  function _notifyVanishedDev(devPorts) {
    if (_prevDevPorts === null) return
    for (var k = 0; k < _prevDevPorts.length; k++) {
      var was = _prevDevPorts[k]
      var still = devPorts.some(function (d) { return d.port === was.port })
      if (still) continue
      if (Date.now() - (_expectedGone[was.port] || 0) < expectedGoneMs) { delete _expectedGone[was.port]; continue }
      var shared = publicTunnelFor(was.port) ? "; its public tunnel is still open" : ""
      notify("Port " + was.port + " went quiet", was.label + " is no longer listening" + shared)
    }
    for (var g in _expectedGone) if (Date.now() - _expectedGone[g] > expectedGoneMs) delete _expectedGone[g]
  }

  function notify(summary, body) {
    Quickshell.execDetached(["notify-send", "-a", "Portal", "-i", "network-server", "--", summary, body])
  }

  function applyProviders(text) {
    var parsed = parseJson(text)
    if (parsed && Array.isArray(parsed.providers)) providers = parsed.providers
  }

  property string _lastTunnelsKey: ""

  function applyTunnels(text) {
    var parsed = parseJson(text)
    if (!parsed || !Array.isArray(parsed.tunnels)) return
    var key = JSON.stringify(parsed.tunnels)
    if (key === _lastTunnelsKey) return
    var first = _lastTunnelsKey === ""
    _lastTunnelsKey = key
    var next = ({})
    for (var i = 0; i < parsed.tunnels.length; i++) {
      var t = parsed.tunnels[i]
      next[t.provider + ":" + t.port] = {
        provider: t.provider, port: t.port, url: t.url, reach: t.reach,
        dns: t.dns,
        // The display identity, derived once for every consumer.
        host: String(t.url).replace(/^[a-z]+:\/\//, "").replace(/:\d+$/, "")
      }
    }
    // A public URL that disappears without Portal stopping it is a lost share
    // the user may have handed out; one that appears is announced too, whether
    // the panel or IPC asked for it. Not on the first status after a reload:
    // those are not news.
    for (var k in tunnels) {
      if (tunnels[k].reach === "public" && !next[k] && _stoppingShare !== k)
        notify("Port " + tunnels[k].port + " is no longer shared", tunnels[k].host + " went away")
    }
    if (!first) {
      for (var n in next) {
        if (next[n].reach === "public" && !tunnels[n])
          notify("Port " + next[n].port + " is public", "reachable from the internet at " + next[n].host)
      }
    }
    _stoppingShare = ""
    tunnels = next
  }
  property string _stoppingShare: ""

  // ---- actions --------------------------------------------------------------
  // expose/unexpose/setup share one Process: they are UI-serialised through
  // busyAction anyway, and one exit handler means a failure can never be
  // silently swallowed by a copy that forgot the ok-check.
  property string _actionFallback: ""

  function _runAction(busyKey, args, fallbackMessage) {
    if (!runTunnels(actionProcess, args, "action")) { actionHint("still working on " + busyAction + " — try again in a moment"); return }
    busyAction = busyKey
    _actionFallback = fallbackMessage
  }

  // Both doors (panel and IPC) land here; the shape is checked once, and
  // tunnels.sh refuses anything not on its roster.
  function shareTarget(port, provider) {
    var n = /^[0-9]{1,5}$/.test(String(port)) ? parseInt(port, 10) : 0
    if (!/^[a-z]{1,32}$/.test(String(provider)) || n <= 0 || n >= 65536) return false
    return providers.length === 0 || providerFor(String(provider)) !== null   // roster known: it decides
  }

  function expose(port, provider, name) {
    if (!shareTarget(port, provider)) return false
    var args = ["start", String(provider), String(port)]
    if (name) args.push(String(name))
    _runAction(provider + ":" + port, args, "could not expose that port")
    return true
  }

  function unexpose(port, provider) {
    if (!shareTarget(port, provider)) return false
    _stoppingShare = provider + ":" + port
    _runAction(provider + ":" + port, ["stop", String(provider), String(port)],
               "could not stop sharing")
    return true
  }

  // action: pause | resume | stop
  function signalProcess(entry, action) {
    if (!entry || !entry.pid) return
    if (action === "stop") _expectGone(entry.port)
    _runLifecycle(entry, [action, String(entry.pid), String(entry.port)], "could not " + action)
  }

  // A truncated command line must never be re-run: half a flag is a different
  // command. The row does not offer restart in that case; this is the backstop.
  function canRestart(entry) {
    return !!(entry && entry.pid && entry.cwd && entry.argv.length > 0 && !entry.argvTruncated)
  }

  function restartProcess(entry) {
    if (!canRestart(entry)) return
    _expectGone(entry.port)
    _runLifecycle(entry, ["restart", String(entry.pid), String(entry.port),
                          String(entry.cwd), JSON.stringify(entry.argv)],
                  "could not restart")
  }

  function _runLifecycle(entry, args, fallbackMessage) {
    if (!runScript(actionProcess, "lifecycle.sh", args, "quick")) { actionHint("still working on " + busyAction + " — try again in a moment"); return }
    _actionFallback = fallbackMessage
    restartDelay.restart()
  }

  function setupProvider(provider) {
    _runAction(provider + ":setup", ["setup", String(provider)], "setup failed")
  }

  function toggleWatched(port) {
    runScript(watchProcess, "metrics.sh", [isWatched(port) ? "unwatch" : "watch", String(port)])
  }

  function isWatched(port) { return watchedPorts.indexOf(port) !== -1 }

  // Disk-backed samples for one port, delivered via diskHistoryLoaded. The
  // detail view merges them with the in-memory ring.
  signal diskHistoryLoaded(int port, var samples)
  property int _diskPort: 0
  property int _diskQueued: 0   // j/k faster than the read: remember the last ask

  function loadDiskHistory(port) {
    if (diskReadProcess.running) { _diskQueued = port; return }
    _diskPort = port
    runScript(diskReadProcess, "metrics.sh", ["read", String(port)])
  }

  function copyText(value) {
    if (!value) return
    Quickshell.execDetached(["wl-copy", "--", String(value)])
    actionHint("copied " + String(value))
  }

  function openUrl(url) {
    if (!url) return
    Quickshell.execDetached(["xdg-open", String(url)])
  }

  function suggestedName(entry) {
    if (!entry) return ""
    if (namingMode === "Port" || !entry.projectName) return "port-" + entry.port
    return String(entry.projectName)
  }

  // ---- processes ------------------------------------------------------------
  Process {
    id: scanProcess
    stdout: StdioCollector { id: scanOut; waitForEnd: true }
    stderr: StdioCollector { id: scanErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (!root.alive) return
      if (exitCode === 0) root.applyScan(scanOut.text)
      else root.lastError = String(scanErr.text || "scan failed").slice(0, 4096).trim()   // its own diagnostics, never data
    }
  }

  Process {
    id: providersProcess
    stdout: StdioCollector { id: provOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (!root.alive) return
      if (exitCode === 0) root.applyProviders(provOut.text)
    }
  }

  Process {
    id: tunnelStatusProcess
    stdout: StdioCollector { id: tunOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (!root.alive) return
      if (exitCode === 0) root.applyTunnels(tunOut.text)
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    onExited: function () {
      if (!root.alive) return
      root.busyAction = ""
      var parsed = root.parseJson(actionOut.text)
      if (!parsed || parsed.ok !== true) {
        root.actionFailed(parsed && parsed.error ? String(parsed.error) : root._actionFallback)
      } else if (parsed.hint) {
        // The action worked but needs one more step (e.g. a hosts entry for a
        // non-localhost TLD). Same channel as errors: it must be seen.
        root.actionHint(String(parsed.hint))
      }
      root.refreshTunnels()
      root.refreshProviders()
    }
  }

  Process {
    id: watchProcess
    stdout: StdioCollector { id: watchOut; waitForEnd: true }
    onExited: function () {
      if (!root.alive) return
      var parsed = root.parseJson(watchOut.text)
      if (parsed && Array.isArray(parsed.ports)) root.watchedPorts = parsed.ports
    }
  }

  Process {
    id: diskReadProcess
    stdout: StdioCollector { id: diskOut; waitForEnd: true }
    onExited: function () {
      if (!root.alive) return
      var parsed = root.parseJson(diskOut.text)
      if (parsed && Array.isArray(parsed.samples)) {
        root.diskHistoryLoaded(root._diskPort, parsed.samples)
        if (root._diskQueued && root._diskQueued !== root._diskPort) {
          var q = root._diskQueued; root._diskQueued = 0
          root.loadDiskHistory(q)
        } else root._diskQueued = 0
      }
    }
  }

  // ---- timers ---------------------------------------------------------------
  Timer {
    interval: root.refreshSeconds * 1000
    running: root.alive
    repeat: true
    triggeredOnStart: true
    onTriggered: { root.refresh(); root.refreshTunnels() }
  }

  // Providers change rarely (a tool gets installed, a proxy starts). Poll them
  // far less often than ports.
  Timer {
    interval: 30000
    running: root.alive
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshProviders()
  }

  // After killing a process, rescan sooner than the next poll so the row
  // disappears immediately.
  Timer {
    id: restartDelay
    interval: 600
    repeat: false
    onTriggered: if (root.alive) root.refresh()
  }

  // The watched set survives shell restarts; load it as soon as the host has
  // injected the manifest. Component.onCompleted alone is too early — the
  // same injection ordering that forces call-time Process commands.
  function _loadWatched() { runScript(watchProcess, "metrics.sh", ["watched"]) }
  onPluginDirChanged: _loadWatched()
  Component.onCompleted: _loadWatched()

  Component.onDestruction: {
    alive = false
    // Do not leave subprocesses attached to a destroyed object.
    var procs = [scanProcess, providersProcess, tunnelStatusProcess, actionProcess, watchProcess, diskReadProcess]
    procs.forEach(function (p) { p.running = false })
  }

  // The IPC surface. `omarchy-shell g3ortega.portal refresh` from a script or
  // a keybind, without opening the panel.
  // Bar widgets instantiate once per monitor; a keybind summon must open one
  // panel, not one per screen. Widgets register here and the first live one
  // answers — so unplugging the monitor that happened to claim the role does
  // not leave the keybind a silent no-op.
  property var summonWidgets: []
  signal summonRequested()

  function registerWidget(w) {
    if (!w || summonWidgets.indexOf(w) !== -1) return
    var next = summonWidgets.slice()
    next.push(w)
    summonWidgets = next
  }

  function unregisterWidget(w) {
    var at = summonWidgets.indexOf(w)
    if (at === -1) return
    var next = summonWidgets.slice()
    next.splice(at, 1)
    summonWidgets = next
  }

  function summonWidget() { return summonWidgets.length > 0 ? summonWidgets[0] : null }

  IpcHandler {
    target: "g3ortega.portal"
    function refresh(): string { root.refreshAll(); return "ok" }
    function toggle(): string { root.summonRequested(); return "ok" }
    function ports(): string { return JSON.stringify(root.ports) }
    function tunnels(): string { return JSON.stringify(root.tunnels) }
    function expose(provider: string, port: string): string {
      return root.expose(port, provider, "") ? "ok" : "error: bad provider or port"
    }
    function unexpose(provider: string, port: string): string {
      return root.unexpose(port, provider) ? "ok" : "error: bad provider or port"
    }
  }
}
