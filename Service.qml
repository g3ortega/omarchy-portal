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
  property string scanError: ""
  property string tunnelError: ""
  property string providerError: ""
  readonly property string lastError: [scanError, tunnelError, providerError].filter(function (v) { return v !== "" }).join(" · ")
  property var activeAction: null
  readonly property string busyAction: activeAction ? activeAction.key : ""
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

  // Live rings are bounded separately from the 48-hour watched history.
  property var history: ({})
  property int historyRevision: 0
  property int metricsRevision: 0
  property string metricsError: ""
  property int metricRequestSequence: 0
  property var _metricBatches: []
  property int _metricQueuedBytes: 0
  property int _metricDropped: 0
  property int _metricBatchSequence: 0
  readonly property string _metricSession: Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)
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
  signal actionMoment(string message)
  signal actionHint(string message)
  signal actionCopy(string message, string command)

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

  function actionProviderFor(id) {
    var provider = providerFor(id)
    return provider && provider.available === true ? provider : null
  }

  function validProcessIdentity(process) {
    if (!process) return false
    var pid = String(process.pid)
    return /^[1-9][0-9]*$/.test(pid) && parseInt(pid, 10) > 1
      && /^[1-9][0-9]*$/.test(String(process.start))
  }

  function sameProcess(a, b) {
    return validProcessIdentity(a) && validProcessIdentity(b)
      && String(a.pid) === String(b.pid) && String(a.start) === String(b.start)
  }

  function processKey(process) {
    return validProcessIdentity(process) ? String(process.pid) + ":" + String(process.start) : ""
  }

  // Derived once here so the panel and the row cursor cannot index two
  // separately-built arrays that drift in order.
  readonly property var publicProviders: {
    var out = []
    for (var i = 0; i < providers.length; i++) if (providers[i].reach === "public" && providers[i].available === true) out.push(providers[i])
    return out
  }

  function parseJson(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }

  // Assign commands after the host injects pluginDir, or they resolve under /scripts.
  // proc.py ends the whole group at either limit and discards truncated output.
  readonly property var deadlines: ({ scan: 20, poll: 20, action: 330, lifecycle: 20, quick: 15 })
  readonly property var outputCaps: ({ scan: 67108864, poll: 16777216, action: 1048576, lifecycle: 1048576, quick: 4194304 })
  function runScript(proc, script, args, kind) {
    if (!alive || !pluginDir || proc.running) return false
    var k = kind || "quick"
    proc.command = ["/usr/bin/python3", "-I", "-S", pluginDir + "/scripts/lib/proc.py", "run",
                    String(outputCaps[k]), String(deadlines[k]), "--",
                    "/usr/bin/bash", pluginDir + "/scripts/" + script].concat(args || [])
    proc.running = true
    return true
  }

  // ---- scanning -------------------------------------------------------------
  property int focusPort: 0
  function probeList() {
    var out = [], seen = ({}), live = ({})
    for (var i = 0; i < ports.length; i++) live[ports[i].port] = ports[i].httpProbe
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
  function refreshTunnels() {
    if (!activeAction) runTunnels(tunnelStatusProcess, ["status"], "poll")
  }

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
      scanError = "could not parse scan output"
      return
    }
    everScanned = true
    // A scan that reports an error (the scanner refused to describe a host
    // with more ports than it caps) keeps the previous snapshot: an empty
    // list would read as every server having vanished.
    if (parsed.error) { scanError = String(parsed.error); return }
    scanError = ""

    var now = Date.now()
    var nextStats = ({})
    var nextCpu = ({})
    var identity = []
    var devPorts = []
    var watchedBatch = ({})
    var seenPorts = ({})
    for (var i = 0; i < parsed.ports.length; i++) {
      var e = parsed.ports[i]
      var cpuKey = e.pid != null && e.start != null ? String(e.pid) + ":" + String(e.start) : ""
      var prev = cpuKey ? _cpuPrev[cpuKey] : undefined
      var cpuPct = null
      if (prev && e.cpuTicks != null && now > prev.t) {
        // ticks are USER_HZ (100/s); delta over wall time gives percent.
        cpuPct = Math.max(0, Math.round((e.cpuTicks - prev.ticks) / (now - prev.t) * 1000))
      }
      if (cpuKey && e.cpuTicks != null) nextCpu[cpuKey] = { ticks: e.cpuTicks, t: now }
      var st = {
        t: Math.round(now / 1000),
        conns: e.conns,
        cpuPct: cpuPct,
        rssKb: e.rssKb,
        upSec: e.upSec,
        latMs: e.latMs,
        httpCode: e.httpCode,
        tcpRttMs: e.tcpRttMs,
        tcpRttCount: e.tcpRttCount,
        paused: e.procState === "T"
      }
      nextStats[e.port] = st
      var sample = { t: st.t, conns: st.conns, cpuPct: st.cpuPct,
                     rssKb: st.rssKb, latMs: st.latMs, httpCode: st.httpCode,
                     tcpRttMs: st.tcpRttMs, tcpRttCount: st.tcpRttCount }
      var ring = history[e.port] || []
      ring.push(sample)
      if (ring.length > maxSamples) ring.splice(0, ring.length - maxSamples)
      history[e.port] = ring
      if (watchedPorts.indexOf(e.port) !== -1) watchedBatch[e.port] = sample
      seenPorts[e.port] = true
      identity.push([e.port, e.addresses, e.pid, e.start, e.comm, e.cmdline, e.argv,
                     e.argvTruncated, e.cwd, e.projectRoot, e.projectName, e.markers, e.deps,
                     e.exclusiveOwner])
    }
    _cpuPrev = nextCpu
    stats = nextStats
    historyRevision++

    if (pluginDir && Object.keys(watchedBatch).length > 0) saveMetricBatch(watchedBatch)

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
      if (d.category === "dev") devPorts.push({ port: d.port, process: d.process, label: d.label })
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
        port: t.port, pid: null, start: null, process: null,
        comm: "", cmdline: "", cwd: "", projectRoot: "", scope: "local",
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
  property var _expectedGoneAt: ({})
  readonly property int expectedGoneMs: 600000
  function _expectGone(process) {
    var key = processKey(process)
    if (key) _expectedGoneAt[key] = Date.now()
  }

  function _forgetGone(process) {
    var key = processKey(process)
    if (key) delete _expectedGoneAt[key]
  }

  function _notifyVanishedDev(devPorts) {
    if (_prevDevPorts === null) return
    var liveProcesses = ({})
    var consumedExpected = ({})
    for (var i = 0; i < devPorts.length; i++) {
      var liveKey = processKey(devPorts[i].process)
      if (liveKey) liveProcesses[liveKey] = true
    }
    for (var k = 0; k < _prevDevPorts.length; k++) {
      var was = _prevDevPorts[k]
      var wasKey = processKey(was.process)
      var samePort = devPorts.some(function (d) { return d.port === was.port })
      var sameProcessPort = wasKey && devPorts.some(function (d) {
        return d.port === was.port && processKey(d.process) === wasKey
      })
      if (sameProcessPort || (!wasKey && samePort)) continue
      if (wasKey && _expectedGoneAt[wasKey] && Date.now() - _expectedGoneAt[wasKey] <= expectedGoneMs) {
        consumedExpected[wasKey] = true
        continue
      }
      if (samePort) continue
      var shared = publicTunnelFor(was.port) ? "; its public tunnel is still open" : ""
      notify("Port " + was.port + " went quiet", was.label + " is no longer listening" + shared)
    }
    for (var consumed in consumedExpected) delete _expectedGoneAt[consumed]
    // Drop a marker once its exact process is gone or it has lingered far past
    // any real shutdown.
    var nowT = Date.now()
    for (var g in _expectedGoneAt) {
      if (!liveProcesses[g] || nowT - _expectedGoneAt[g] > expectedGoneMs) delete _expectedGoneAt[g]
    }
  }

  function notify(summary, body) {
    Quickshell.execDetached(["notify-send", "-a", "Portal", "-i", "network-server", "--", summary, body])
  }

  function applyProviders(text) {
    var parsed = parseJson(text)
    if (!parsed || !Array.isArray(parsed.providers)) {
      providerError = parsed && parsed.error ? String(parsed.error).slice(0, 4096) : "could not parse provider status output"
      return
    }
    providerError = ""
    providers = parsed.providers
  }

  property string _lastTunnelsKey: ""
  property var _startedShareUrls: ({})

  function applyTunnels(text) {
    var parsed = parseJson(text)
    // A status that could not read its state says so; the last good snapshot stays.
    if (parsed && parsed.error) { tunnelError = String(parsed.error).slice(0, 4096); return }
    if (!parsed || !Array.isArray(parsed.tunnels)) {
      tunnelError = "could not parse tunnel status output"
      return
    }
    tunnelError = ""
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
        aliasName: String(t.aliasName || ""),
        managed: t.managed === true ? true : (t.managed === false ? false : null),
        targetHealthy: t.targetHealthy === true ? true : (t.targetHealthy === false ? false : null),
        // The display identity, derived once for every consumer.
        host: String(t.url).replace(/^[a-z]+:\/\//, "").replace(/:\d+$/, "")
      }
    }
    // A public URL that disappears without Portal stopping it is a lost share
    // the user may have handed out; one that appears is announced too, whether
    // the panel or IPC asked for it. A hostname that changes under the same
    // provider and port is both. Initial status stays quiet except for
    // shares the user started before that first poll completed.
    for (var k in tunnels) {
      var stopping = _stoppingShare === k
        || (activeAction && activeAction.shareStopKey === k)
      if (tunnels[k].reach === "public" && !stopping && (!next[k] || next[k].url !== tunnels[k].url))
        notify("Port " + tunnels[k].port + " is no longer shared", tunnels[k].host + " went away")
    }
    for (var n in next) {
      if (next[n].reach === "public" && (!first || _startedShareUrls[n] === next[n].url)
          && (!tunnels[n] || tunnels[n].url !== next[n].url))
        notify("Port " + next[n].port + " is public", "reachable from the internet at " + next[n].host)
    }
    _startedShareUrls = ({})
    if (_stoppingShare && tunnels[_stoppingShare]
        && (!next[_stoppingShare] || next[_stoppingShare].url !== tunnels[_stoppingShare].url))
      _stoppingShare = ""
    tunnels = next
  }
  property string _stoppingShare: ""

  // ---- actions --------------------------------------------------------------
  // expose/unexpose/setup share one Process: they are UI-serialised through
  // busyAction anyway, and one exit handler means a failure can never be
  // silently swallowed by a copy that forgot the ok-check.
  property var queuedAction: null
  property bool cancellingTunnelPoll: false

  Timer {
    id: actionLaunchTimer
    interval: 50
    onTriggered: {
      if (tunnelStatusProcess.running) {
        root.cancellingTunnelPoll = true
        tunnelStatusProcess.running = false
        restart()
        return
      }
      var queued = root.queuedAction
      if (!queued) return
      root.queuedAction = null
      var started = queued.script === "tunnels"
        ? root.runTunnels(actionProcess, queued.args, "action")
        : root.runScript(actionProcess, queued.script, queued.args,
                         queued.script === "lifecycle.sh" ? "lifecycle" : "quick")
      if (!started) {
        root.activeAction = null
        root.actionMoment("still working — try again in a moment")
        return
      }
      if (root.activeAction && root.activeAction.expectsGone) root._expectGone(root.activeAction.target)
    }
  }

  function _queueAction(spec, args, fallbackMessage, script) {
    if (actionProcess.running || activeAction || queuedAction) {
      actionMoment("still working on " + busyAction + " — try again in a moment")
      return false
    }
    activeAction = Object.assign({ fallback: fallbackMessage }, spec)
    queuedAction = { script: script, args: args }
    actionLaunchTimer.restart()
    return true
  }

  function _runAction(spec, args, fallbackMessage) {
    return _queueAction(spec, args, fallbackMessage, "tunnels")
  }

  // New starts require the loaded provider roster. A listed exposure can still
  // be stopped or renamed while that independent startup poll is unfinished.
  function exposureKey(port, provider) {
    var s = String(port)
    if (!/^[1-9][0-9]{0,4}$/.test(s)) return ""
    var n = parseInt(s, 10)
    if (n < 1 || n > 65535) return ""
    if (!/^[a-z]{1,32}$/.test(String(provider))) return ""
    return String(provider) + ":" + n
  }

  function shareTarget(port, provider) {
    return exposureKey(port, provider) !== "" && actionProviderFor(String(provider)) !== null
  }

  function stopTarget(port, provider) {
    var key = exposureKey(port, provider)
    return key !== "" && (providerFor(String(provider)) !== null || tunnels[key] !== undefined)
  }

  // Both return whether the action was actually launched, so a caller (the
  // IPC surface) never reports success for a request the busy channel dropped.
  // target, when the caller saw a process behind the port, makes a public
  // start refuse a port that another process has taken since.
  function expose(port, provider, name, target) {
    var key = exposureKey(port, provider)
    if (!key) return false
    var n = parseInt(port, 10)
    var p = actionProviderFor(String(provider))
    if (!p || p.status !== "ready") return false
    if (p.reach === "public" && !validProcessIdentity(target)) return false
    var args = ["start", String(provider), String(n)]
    if (name) args.push(String(name))
    if (p.reach === "public") args.push("--target", String(target.pid), String(target.start))
    return _runAction({ key: key, shareStartPort: p.reach === "public" ? n : 0 }, args, "could not expose that port")
  }

  function unexpose(port, provider) {
    if (String(provider) === "portless" && !actionProviderFor("portless")) return false
    if (!stopTarget(port, provider)) return false
    var n = parseInt(port, 10)
    var key = exposureKey(port, provider)
    return _runAction({ key: key, shareStopKey: key }, ["stop", String(provider), String(n)],
                      "could not stop sharing")
  }

  // action: pause | resume | stop
  function signalProcess(entry, action) {
    if (!entry || !validProcessIdentity(entry.process)) return false
    return _runLifecycle(entry, action,
                         [action, String(entry.process.pid), String(entry.process.start), String(entry.port)],
                         "could not " + action)
  }

  // A truncated command line must never be re-run: half a flag is a different
  // command. The row does not offer restart in that case; this is the backstop.
  function canRestart(entry) {
    return !!(entry && validProcessIdentity(entry.process) && entry.cwd
              && entry.argv.length > 0 && !entry.argvTruncated)
  }

  function restartProcess(entry) {
    if (!canRestart(entry)) return false
    return _runLifecycle(entry, "restart",
                         ["restart", String(entry.process.pid), String(entry.process.start), String(entry.port),
                          String(entry.cwd), JSON.stringify(entry.argv)], "could not restart")
  }

  function _runLifecycle(entry, action, args, fallbackMessage) {
    var expectsGone = action === "stop" || action === "restart"
    return _queueAction({ key: action + ":" + entry.port, lifecycle: true,
                          target: entry.process, expectsGone: expectsGone }, args,
                        fallbackMessage, "lifecycle.sh")
  }

  function setupProvider(provider) {
    _runAction({ key: provider + ":setup" }, ["setup", String(provider)], "setup failed")
  }

  function toggleWatched(port) {
    if (!runScript(watchProcess, "metrics.sh", [isWatched(port) ? "unwatch" : "watch", String(port)]))
      actionMoment("still updating watched ports — try again in a moment")
  }

  function isWatched(port) { return watchedPorts.indexOf(port) !== -1 }

  signal metricRangeLoaded(int port, int seconds, int requestId, var view, string error)
  property var _metricRead: null
  property var _metricReadQueue: []

  function loadMetricRange(port, seconds, end, requestId, requester) {
    var request = { port: port, seconds: seconds, end: end, id: requestId, requester: requester }
    var index = _metricReadQueue.findIndex(function (pending) { return pending.requester === requester })
    if (index !== -1) _metricReadQueue[index] = request
    else if (_metricReadQueue.length < 32) _metricReadQueue.push(request)
    else {
      metricRangeLoaded(port, seconds, requestId, null, "History reader busy; try again")
      return
    }
    dispatchMetricRead()
  }

  function cancelMetricRanges(requester) {
    _metricReadQueue = _metricReadQueue.filter(function (request) { return request.requester !== requester })
  }

  function dispatchMetricRead() {
    while (_metricReadQueue.length > 0 && !diskReadProcess.running && !metricsAppendProcess.running
           && (_metricBatches.length === 0 || metricsRetry.running)) {
      var request = _metricReadQueue.shift()
      _metricRead = request
      if (runScript(diskReadProcess, "metrics.sh",
                    ["query", String(request.port), String(request.seconds), String(request.end), "400"])) return
      _metricRead = null
      metricRangeLoaded(request.port, request.seconds, request.id, null, "could not load saved history")
    }
  }

  function saveMetricBatch(batch) {
    var ports = Object.keys(batch)
    for (var i = 0; i < ports.length; i += 512) {
      var part = ({})
      for (var j = i; j < Math.min(i + 512, ports.length); j++) part[ports[j]] = batch[ports[j]]
      var text = JSON.stringify(part)
      if (_metricBatches.length >= 120 || _metricQueuedBytes + text.length > 2097152) {
        _metricDropped++
        metricsError = "Recording gap: " + _metricDropped + " batches could not be queued"
        continue
      }
      _metricBatches.push({ id: _metricSession + "-" + (++_metricBatchSequence), text: text })
      _metricQueuedBytes += text.length
    }
    if (!metricsRetry.running) flushMetricBatch()
  }

  function flushMetricBatch() {
    if (metricsRetry.running || metricsAppendProcess.running || diskReadProcess.running || _metricBatches.length === 0) return
    var batch = _metricBatches[0]
    if (!runScript(metricsAppendProcess, "metrics.sh", ["append-batch", batch.text, batch.id])) {
      metricsError = "History not saved; retrying"
      metricsRetry.restart()
    }
  }

  function copyText(value, quiet) {
    if (!value) return
    Quickshell.execDetached(["wl-copy", "--", String(value)])
    // Quiet copies answer with the button's own animation instead: the step
    // row pops its icon, so no "copied <command>" line is ever shown.
    if (!quiet) actionMoment("copied " + String(value))
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
      else root.scanError = String(scanErr.text || "scan failed").slice(0, 4096).trim()   // its own diagnostics, never data
    }
  }

  Process {
    id: providersProcess
    stdout: StdioCollector { id: provOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (!root.alive) return
      if (exitCode === 0) root.applyProviders(provOut.text)
      else root.providerError = "provider status failed; showing the last known state"
    }
  }

  Process {
    id: tunnelStatusProcess
    stdout: StdioCollector { id: tunOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (!root.alive) return
      if (root.cancellingTunnelPoll) {
        root.cancellingTunnelPoll = false
        actionLaunchTimer.restart()
        return
      }
      if (exitCode === 0) root.applyTunnels(tunOut.text)
      else root.tunnelError = exitCode === 124 ? "tunnel status timed out; showing the last known state"
                                : exitCode === 125 ? "tunnel status produced too much output; showing the last known state"
                                : "tunnel status failed; showing the last known state"
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    onExited: function () {
      if (!root.alive) return
      var action = root.activeAction
      root.activeAction = null
      var parsed = root.parseJson(actionOut.text)
      var ok = parsed && parsed.ok === true
      if (ok && action && !root._lastTunnelsKey && parsed.reach === "public" && parsed.url)
        root._startedShareUrls[action.key] = String(parsed.url)
      var targetStopped = parsed && (parsed.effect === "stopped" || parsed.effect === "restarted")
      if (action && action.expectsGone && !targetStopped) root._forgetGone(action.target)
      if (ok && action && action.shareStopKey && root.tunnels[action.shareStopKey])
        root._stoppingShare = action.shareStopKey
      if (!ok) {
        root.actionFailed(parsed && parsed.error ? String(parsed.error)
                          : (action ? action.fallback : "action failed"))
      } else if (parsed.hint) {
        // The action worked but needs one more step (e.g. a hosts entry for a
        // non-localhost TLD). Same channel as errors: it must be seen. A hint
        // carrying a command arrives as a copy card instead of plain text.
        if (parsed.copy) root.actionCopy(String(parsed.hint), String(parsed.copy))
        else root.actionHint(String(parsed.hint))
      } else if (action && action.key.slice(-6) === ":setup") {
        root.actionMoment("Setup complete.")
      }
      if (action && action.lifecycle) restartDelay.restart()
      root.refreshTunnels()
      root.refreshProviders()
    }
  }

  Process {
    id: watchProcess
    stdout: StdioCollector { id: watchOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (!root.alive) return
      var parsed = root.parseJson(watchOut.text)
      if (exitCode === 0 && parsed && parsed.ok === true && Array.isArray(parsed.ports)) root.watchedPorts = parsed.ports
      else root.actionFailed(parsed && parsed.error ? String(parsed.error) : "could not update watched ports")
    }
  }

  Process {
    id: diskReadProcess
    stdout: StdioCollector { id: diskOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (!root.alive) return
      var request = root._metricRead
      root._metricRead = null
      var parsed = root.parseJson(diskOut.text)
      var success = exitCode === 0 && parsed && parsed.ok === true && parsed.view && Array.isArray(parsed.view.buckets)
      var error = success ? "" : (parsed && parsed.error ? String(parsed.error) : "could not load saved history")
      root.flushMetricBatch()
      root.dispatchMetricRead()
      root.metricRangeLoaded(request.port, request.seconds, request.id, success ? parsed.view : null,
                             error)
    }
  }

  Process {
    id: metricsAppendProcess
    stdout: StdioCollector { id: metricsAppendOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (!root.alive) return
      var parsed = root.parseJson(metricsAppendOut.text)
      if (exitCode === 0 && parsed && parsed.ok === true) {
        var saved = root._metricBatches.shift()
        root._metricQueuedBytes -= saved.text.length
        root.metricsError = root._metricDropped ? "Recording gap: " + root._metricDropped + " batches could not be queued"
                           : ""
        root.metricsRevision++
        root.flushMetricBatch()
      } else {
        root.metricsError = (parsed && parsed.error ? String(parsed.error) : "History not saved") + "; retrying"
        metricsRetry.restart()
      }
      root.dispatchMetricRead()
    }
  }

  Timer {
    id: metricsRetry
    interval: 5000
    onTriggered: root.flushMetricBatch()
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
      if (root.providers.length === 0) return "error: providers not loaded yet, try again"
      if (!root.shareTarget(port, provider)) return "error: bad provider or port"
      var p = root.providerFor(String(provider))
      if (p.status !== "ready") return "error: " + provider + " is not ready (" + p.status + ")"
      // Bind the share to the process the scan saw on that port, like the
      // panel does, so a port that has changed hands is refused rather than
      // silently exposing whatever took it.
      var n = parseInt(port, 10), owner = null
      for (var i = 0; i < root.ports.length; i++) if (root.ports[i].port === n) { owner = root.ports[i]; break }
      if (!owner) return "error: nothing Portal scanned is listening on port " + port
      if (p.reach === "public" && !root.validProcessIdentity(owner.process))
        return "error: Portal could not identify the process listening on port " + port
      return root.expose(port, provider, "", p.reach === "public" ? owner.process : null)
        ? "ok" : "error: busy, try again"
    }
    function unexpose(provider: string, port: string): string {
      if (!root.stopTarget(port, provider)) return "error: bad provider, port, or exposure"
      return root.unexpose(port, provider) ? "ok" : "error: busy, try again"
    }
  }
}
