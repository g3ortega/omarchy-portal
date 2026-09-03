pragma ComponentBehavior: Bound

import QtQuick
import qs.Ui
import qs.Commons
import "lib/Icons.js" as Icons

// Portal's panel. Service.qml owns the g3ortega.portal IPC target; a second
// handler on the same target warns at runtime, so this one manages none.
Panel {
  id: root
  moduleName: "g3ortega.portal"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  // ---- state ---------------------------------------------------------------
  // The filter field is the query.
  property alias query: search.text
  onQueryChanged: selectedPort = -1
  // Selection is keyed by port number, not by position: the 5-second poll
  // rebuilds the row list, and an ordinal would silently land on a different
  // port mid-interaction.
  property int selectedPort: -1
  // What the selected row has unfolded: "" | actions | naming | sharing.
  // Keyed on the selection, so moving the cursor closes it structurally.
  property string expandedKind: ""
  onSelectedPortChanged: collapse()
  property var detailEntry: null
  onDetailEntryChanged: if (service) service.focusPort = detailEntry ? detailEntry.port : 0
  // Anything that disrupts a running process — stop, pause, restart — goes
  // through one confirmation. Resume does not: it is the recovery action, and
  // friction on the way back out is friction in the wrong place.
  // { kind, entry, label?, clause?, run }. kind is the verb the answer wears
  // (stop, pause, restart, share, install); run is what accepting does.
  property var pendingAction: null
  property bool helpOpen: false
  property bool settingsOpen: false
  property int settingsIndex: 0
  // Cursors: into publicProviders while a share picker is open, and along
  // the verbs while a row's actions are open.
  property int shareIndex: 0
  property int verbIndex: 0
  property string toast: ""
  property bool toastIsHint: false
  // A hint carrying a command renders as a card (title + copyable command)
  // instead of plain toast text; cleared everywhere the toast is.
  property string toastCopy: ""

  function showToast(message, hint) {
    toast = message; toastIsHint = hint === true
    // A moment ("copied …") clears itself; guidance (a setup step) stays
    // until read — Esc dismisses it, anything new replaces it.
    if (toastIsHint) toastTimer.stop()
    else toastTimer.restart()
  }

  function showCopyCard(message, command) {
    toast = message; toastIsHint = true; toastCopy = command
    toastTimer.stop()
  }

  // A toast is a moment, not a status line — unless it is guidance.
  Timer { id: toastTimer; interval: 5000; onTriggered: root.toast = "" }

  function expand(port, kind) {
    // Moving anywhere abandons an unanswered question — Enter must never act
    // on a row the user has navigated away from.
    pendingAction = null
    if (selectedPort === port && expandedKind === kind) { collapse(); return }
    // Acting on a port happens on its row, even when asked from the charts.
    detailEntry = null
    selectedPort = port
    expandedKind = kind
    if (kind === "sharing") shareIndex = 0
    if (kind === "actions") verbIndex = 0
    // A mouse click must never leave the keyboard dead: whatever had focus
    // (the filter, a just-closed editor) hands it back — except the name
    // editor, which takes it itself.
    if (kind !== "naming") keyCatcher.forceActiveFocus()
  }

  function collapse() { expandedKind = "" }

  // Page precedence. Every handler and every `visible` reads mode, so a new
  // page is one rung here and nowhere else.
  readonly property string mode: helpOpen ? "help"
    : pendingAction !== null ? "confirm"
    : settingsOpen ? "settings"
    : detailEntry !== null ? "detail"
    : expandedKind === "sharing" ? "share"
    : expandedKind === "naming" ? "naming"
    : expandedKind === "actions" ? "actions"
    : "list"

  // Everything in this panel is drawn on the popup surface. Panel.barForeground
  // follows the bar's text color, which is dark on a light bar — correct for a
  // bar widget, unreadable inside a popup.
  readonly property color panelText: Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var portlessProvider: service ? service.providerFor("portless") : null
  readonly property bool portlessReady: portlessProvider !== null && portlessProvider.status === "ready"

  readonly property var publicProviders: service ? service.publicProviders : []
  readonly property bool broadcasting: service ? service.hasPublicTunnel : false
  readonly property color pillColor: broadcasting ? Color.urgent : Color.accent

  // Presentation only. manifest.json's barWidget.schema — which the host
  // injects onto the service — is the source of truth for which settings
  // exist, their options, and their defaults. This table carries just the two
  // things a JSON schema cannot: a label short enough for a narrow panel, and
  // discrete steps for the types that are free-form by design.
  readonly property var settingUi: ({
    "portlessTld":      { label: "Local domain",        prefix: ".", steps: ["localhost", "test", "internal"] },
    "portlessAutoName": { label: "Name new routes by" },
    "showSystemPorts":  { label: "System ports" },
    "iconColors":       { label: "Icon colors" },
    "refreshSeconds":   { label: "Rescan every",        suffix: "s", steps: ["2", "5", "10", "30"] },
    "barLabel":         { label: "Bar label" }
  })

  readonly property var settingDefs: {
    var out = []
    var schema = service && service.manifest && service.manifest.barWidget
      ? service.manifest.barWidget.schema : null
    if (!Array.isArray(schema)) return out
    for (var i = 0; i < schema.length; i++) {
      var row = schema[i]
      var ui = settingUi[row.key]
      if (!ui) continue
      var opts = (Array.isArray(row.options) && row.options.length > 0)
        ? row.options.map(String) : (ui.steps || [])
      if (opts.length === 0) continue
      var def = String(row.defaultValue)
      // A value set outside this panel is legal — the schema allows any
      // integer for refreshSeconds, any string for the TLD — so show it as
      // its own chip instead of letting the first keypress overwrite it.
      var held = String(setting(row.key, def))
      if (opts.indexOf(held) === -1) opts = opts.concat([held])
      out.push({ key: row.key, label: ui.label, opts: opts,
                 prefix: ui.prefix || "", suffix: ui.suffix || "",
                 def: def, type: row.type })
    }
    return out
  }

  function settingValue(def) { return String(setting(def.key, def.def)) }

  function applySetting(def, value) {
    if (value === settingValue(def)) return              // nothing to write
    if (!hostWidget.saveSetting(def.key, def.type === "integer" ? Number(value) : value))
      showToast("Could not save " + def.label + " — check ~/.config/omarchy/shell.json")
  }

  function cycleSetting(def, dir) {
    if (!def) return
    var at = def.opts.indexOf(settingValue(def))
    applySetting(def, def.opts[at < 0 ? 0 : wrapIndex(at, dir, def.opts.length)])
  }

  function toggleSettings() {
    helpOpen = false
    pendingAction = null
    detailEntry = null
    // A name editor left open under a hidden page keeps the key catcher
    // blocked, so the settings page would open keyboard-dead.
    collapse()
    settingsOpen = !settingsOpen
    settingsIndex = 0
    keyCatcher.forceActiveFocus()
  }

  readonly property bool brandColors: String(setting("iconColors", "Brand")) !== "Theme"
  readonly property bool showSystem: String(setting("showSystemPorts", "Off")) === "On"

  onOpenedChanged: {
    // A closed panel must not keep four canvases repainting for nobody:
    // dropping the detail page unloads them until the next visit.
    detailEntry = null
    if (!opened) return
    query = ""
    selectedPort = -1
    toast = ""
    toastCopy = ""
    pendingAction = null
    helpOpen = false
    settingsOpen = false
    if (service) service.refreshAll()
  }

  Connections {
    target: root.service
    function onActionFailed(message) { root.showToast(message) }
    function onActionHint(message) { root.showToast(message, true) }
    function onActionCopy(message, command) { root.showCopyCard(message, command) }
  }

  // ---- model ---------------------------------------------------------------
  // One pass builds both the flat render list ({type: "header" | "port"}) and
  // the ordered array of visible port entries that selection walks.
  readonly property var viewData: buildViewData()
  readonly property var rows: viewData.rows
  readonly property var visibleEntries: viewData.entries
  // A row that vanishes takes its expansion and any unanswered question with
  // it: an answer must never land on a port that stopped listening.
  onVisibleEntriesChanged: {
    if (expandedKind !== "" && indexOfPort(selectedPort) < 0) collapse()
    if (pendingAction !== null && !stillListed(pendingAction.entry)) pendingAction = null
  }
  // The row a question was asked about, still: same port, and the same
  // process behind it, or at least the same program in the same directory
  // (a dev server that restarted itself). A different service that took the
  // port in the meantime gets no answer meant for another.
  function stillListed(entry) {
    var now = entryForPort(entry.port)
    if (!now) return false
    return (now.pid === entry.pid && now.start === entry.start) || (now.name === entry.name && now.cwd === entry.cwd)
  }

  readonly property var groupOrder: [
    { key: "dev", label: "YOUR APPS" },
    { key: "service", label: "SERVICES" },
    { key: "system", label: "SYSTEM" }
  ]

  // Runs on every keystroke while filtering, so the query is lowercased once
  // and the port list walked once — not once per group with a fresh array
  // allocation per entry.
  function buildViewData() {
    var rows = [], entries = []
    if (!service || !service.ports) return { rows: rows, entries: entries }
    var all = service.ports.concat(service.orphanShares)
    var q = String(root.query).trim().toLowerCase()
    var buckets = ({})
    for (var g = 0; g < groupOrder.length; g++) buckets[groupOrder[g].key] = []
    for (var i = 0; i < all.length; i++) {
      var e = all[i]
      var bucket = buckets[e.category]
      if (bucket === undefined) continue
      if (q) {
        // The project's name, not its path: every path contains the username.
        var proj = e.projectRoot ? String(e.projectRoot).split("/").pop() : ""
        var hay = (e.name + " " + e.label + " " + e.comm + " " + e.port + " " + proj).toLowerCase()
        if (hay.indexOf(q) === -1) continue
      }
      bucket.push(e)
    }
    for (var k = 0; k < groupOrder.length; k++) {
      var group = groupOrder[k]
      if (group.key === "system" && !showSystem) continue
      var got = buckets[group.key]
      if (got.length === 0) continue
      rows.push({ type: "header", label: group.label, count: got.length })
      for (var j = 0; j < got.length; j++) {
        rows.push({ type: "port", entry: got[j] })
        entries.push(got[j])
      }
    }
    return { rows: rows, entries: entries }
  }

  function indexOfPort(port) {
    for (var i = 0; i < visibleEntries.length; i++) {
      if (visibleEntries[i].port === port) return i
    }
    return -1
  }

  function selectedEntry() { return entryForPort(selectedPort) }

  function selectedOrFirst() {
    if (indexOfPort(selectedPort) < 0 && visibleEntries.length > 0)
      selectedPort = visibleEntries[0].port
    return selectedEntry()
  }

  function wrapIndex(at, dir, n) { return ((at + dir) % n + n) % n }

  function moveSelection(delta) {
    if (visibleEntries.length === 0) { selectedPort = -1; return }
    var next = Util.clamp(indexOfPort(selectedPort) + delta, 0, visibleEntries.length - 1)
    selectedPort = visibleEntries[next].port
  }

  function activateSelected() {
    var e = selectedOrFirst()
    if (e) expand(e.port, "actions")
  }

  function openDetail() { showDetail(selectedOrFirst()) }

  // The entry a key acts on: the detail page's when open, else the cursor's.
  function currentEntry() {
    return detailEntry !== null ? detailEntry : selectedEntry()
  }

  function currentUrl() {
    var e = currentEntry()
    return e && service ? service.urlFor(e.port, e.url) : ""
  }

  function requestAction(kind, entry, extra) {
    var run = kind === "restart" ? function () { service.restartProcess(entry) }
                                 : function () { service.signalProcess(entry, kind) }
    pendingAction = Object.assign({ kind: kind, entry: entry, run: run }, extra || {})
    // The question renders on the row itself, so the row must be on screen
    // and current — even when the key was pressed from the charts page — and
    // the keyboard must answer it even if a name editor had focus.
    detailEntry = null
    selectedPort = entry.port
    keyCatcher.forceActiveFocus()
  }

  // One verb list, built where every fact lives; the row only renders it.
  // Mouse clicks, Enter on the verb cursor, and the direct keys (n s p r x)
  // all land in activateVerb, so the flows cannot drift apart.
  function verbsFor(entry) {
    if (!entry || !service) return []
    var out = []
    var named = service.routeFor(entry.port) !== null
    var tunnel = service.publicTunnelFor(entry.port)
    var st = service.stats[entry.port]
    var paused = st ? st.paused === true : false
    var stoppable = entry.pid && entry.category !== "system"
    var expandedHere = selectedPort === entry.port
    if ((portlessReady || named) && entry.category !== "system" && entry.kind !== "orphan")
      out.push({ id: "name", label: named ? "rename" : "name",
                 on: expandedHere && expandedKind === "naming", urgent: false })
    if (service.urlFor(entry.port, entry.url) !== "" && entry.category !== "system")
      out.push({ id: "share", label: tunnel ? "stop sharing" : "share",
                 on: expandedHere && expandedKind === "sharing", urgent: tunnel !== null })
    if (stoppable)
      out.push({ id: "pause", label: paused ? "resume" : "pause", on: false, urgent: paused })
    if (entry.category === "dev" && service.canRestart(entry))
      out.push({ id: "restart", label: "restart", on: false, urgent: false })
    if (stoppable)
      out.push({ id: "stop", label: "stop", on: false, urgent: true })
    return out
  }

  function activateVerb(entry, verb) {
    switch (verb.id) {
    case "name": expand(entry.port, "naming"); break
    case "share":
      var tunnel = service.publicTunnelFor(entry.port)
      if (tunnel) service.unexpose(entry.port, tunnel.provider)
      else expand(entry.port, "sharing")
      break
    case "pause":
      var st = service.stats[entry.port]
      if (st && st.paused) service.signalProcess(entry, "resume")
      else requestAction("pause", entry)
      break
    case "restart": requestAction("restart", entry); break
    case "stop": requestAction("stop", entry); break
    }
  }

  // A direct key is the verb by name, subject to the same availability rules.
  function activateVerbById(entry, id) {
    var vs = verbsFor(entry)
    for (var i = 0; i < vs.length; i++) if (vs[i].id === id) { activateVerb(entry, vs[i]); return }
  }

  function activateVerbAtCursor() {
    var e = selectedEntry()
    var vs = verbsFor(e)
    if (vs.length > 0) activateVerb(e, vs[Math.min(verbIndex, vs.length - 1)])
  }

  function showDetail(entry) {
    if (!entry) return
    pendingAction = null
    detailEntry = entry
    selectedPort = entry.port
    collapse()
  }

  function confirmAccept() {
    var a = pendingAction
    pendingAction = null
    if (stillListed(a.entry)) a.run()
  }

  // j/k on the detail page walk sibling ports without leaving the charts.
  function detailStep(delta) {
    if (detailEntry === null || visibleEntries.length === 0) return
    var at = Math.max(indexOfPort(detailEntry.port), 0)
    detailEntry = visibleEntries[Util.clamp(at + delta, 0, visibleEntries.length - 1)]
    selectedPort = detailEntry.port
  }

  // One activation body for the keyboard and the row's own chips.
  // Reaching the internet, or putting something on the machine, is asked
  // first, in the row, like any other consequential action. What a setup
  // does comes from the provider itself (setupClause), so no provider is
  // named here.
  function chooseProvider(port, provider) {
    if (!service || !provider) return
    var entry = entryForPort(port)
    if (!entry) return
    if (provider.status === "ready") {
      requestAction("share", entry, { label: entry.name, clause: "publicly, via " + provider.label,
        // stillListed may keep this question through a dev-server restart, so
        // the pid is read now, at accept time, not when the question opened.
        run: function () { var e = entryForPort(port); service.expose(port, provider.id, "", (e || entry).pid) } })
    } else if (provider.status === "setup" && provider.setupClause) {
      requestAction("install", entry, { label: provider.id, clause: provider.setupClause,
        run: function () { service.setupProvider(provider.id) } })
    } else if (provider.status === "setup") {
      service.setupProvider(provider.id)   // nothing to do here; the provider says what to run
    }
  }

  function entryForPort(port) {
    var i = indexOfPort(port)
    return i < 0 ? null : visibleEntries[i]
  }

  function activateShareChip() {
    var e = selectedEntry()
    if (e) chooseProvider(e.port, publicProviders[shareIndex])
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Editors own the keyboard while they exist: the filter field and the
      // inline name editor both need plain letters, including j/k/x/space.
      // A confirmation is not blocked: y/n/enter are routed below.
      blocked: search.activeFocus || root.mode === "naming"
      // Esc steps back one level, in mode precedence order. A persistent
      // hint is the topmost level: it goes first, the rest is untouched.
      onCloseRequested: {
        if (root.toast !== "" && root.toastIsHint) { root.toast = ""; root.toastCopy = ""; return }
        switch (root.mode) {
        case "help":     root.helpOpen = false; return
        case "confirm":  root.pendingAction = null; return
        case "settings": root.settingsOpen = false; return
        case "detail":   root.detailEntry = null; return
        case "share":    root.expand(root.selectedPort, "actions"); return
        case "actions":  root.collapse(); return
        }
        if (root.query.length > 0) { root.query = ""; return }
        root.close()
      }
      onMoveRequested: function (dx, dy) {
        if (root.mode === "help" || root.mode === "confirm") return
        if (root.mode === "settings") {
          if (dy !== 0) {
            root.settingsIndex = Util.clamp(root.settingsIndex + dy, 0, root.settingDefs.length - 1)
          } else if (dx !== 0) {
            root.cycleSetting(root.settingDefs[root.settingsIndex], dx)
          }
          return
        }
        if (root.mode === "detail") {
          if (dy !== 0) root.detailStep(dy)
          else if (dx < 0) root.detailEntry = null
          return
        }
        if (root.mode === "share" && root.publicProviders.length > 0) {
          root.shareIndex = root.wrapIndex(root.shareIndex, dx !== 0 ? dx : dy, root.publicProviders.length)
          return
        }
        if (root.mode === "actions") {
          if (dx !== 0) {
            var vs = root.verbsFor(root.selectedEntry())
            if (vs.length > 0) root.verbIndex = root.wrapIndex(root.verbIndex, dx, vs.length)
            return
          }
          // Leaving the row closes what it had open, even at the list's edge.
          root.collapse()
          root.moveSelection(dy)
          return
        }
        if (dy !== 0) root.moveSelection(dy)
        else if (dx > 0) root.openDetail()
      }
      onActivateRequested: {
        switch (root.mode) {
        case "help":     root.helpOpen = false; return
        case "confirm":  root.confirmAccept(); return
        case "settings": root.cycleSetting(root.settingDefs[root.settingsIndex], 1); return
        case "share":    root.activateShareChip(); return
        case "actions":  root.activateVerbAtCursor(); return
        case "detail":   return
        default:         root.activateSelected()
        }
      }
      onTabRequested: function (direction) { if (root.bar) root.bar.switchPanelFrom(root.hostWidget, direction) }
      // The catcher routes x as a delete request rather than a text key.
      onDeleteRequested: {
        if (root.mode !== "list" && root.mode !== "detail" && root.mode !== "actions") return
        var e = root.mode === "detail" ? root.detailEntry : root.selectedOrFirst()
        if (e) root.activateVerbById(e, "stop")
      }
      readonly property var verbKeys: ({ n: "name", s: "share", p: "pause", r: "restart" })
      onTextKey: function (t) {
        if (!root.service) return
        if (root.mode === "help") { root.helpOpen = false; return }
        if (root.mode === "confirm") {
          if (t === "y") root.confirmAccept()
          else if (t === "n") root.pendingAction = null
          return
        }
        if (t === "?") { root.helpOpen = true; return }
        if (t === ",") { root.toggleSettings(); return }
        if (root.mode === "settings") return
        if (t === "/") {
          root.detailEntry = null
          search.forceActiveFocus()
          search.selectAll()
          return
        }
        if (t === "R") { root.service.refreshAll(); return }

        // Below here the key acts on an entry: the charts' port, else the
        // cursor's (falling back to the first row).
        var e = root.mode === "detail" ? root.detailEntry : root.selectedOrFirst()
        if (!e) return
        var u = root.currentUrl()
        if (t === "o") { root.service.openUrl(u); return }
        if (t === "c") { root.service.copyText(u); return }
        if (t === "w") { root.service.toggleWatched(e.port); return }
        if (t === "a") { root.expand(e.port, "actions"); return }
        if (verbKeys[t]) { root.activateVerbById(e, verbKeys[t]); return }

        if (root.mode === "detail") return

        if (t === "g" || t === "G") {
          if (root.visibleEntries.length > 0)
            root.selectedPort = root.visibleEntries[t === "g" ? 0 : root.visibleEntries.length - 1].port
          return
        }

        // Anything unbound starts the filter, launcher-style: the first
        // keystroke lands in the field and focus follows for the rest.
        if (/^[a-z0-9 ._-]$/i.test(t)) {
          root.detailEntry = null
          search.forceActiveFocus()
          search.text = search.text + t
          search.cursorPosition = search.text.length
        }
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.md

        PanelHero {
          width: parent.width
          foreground: root.panelText
          fontFamily: root.fontFamily
          iconSize: Style.font.title
          // The wordmark lives in the icon slot: a ring, then the name set
          // wide, the way a chamber sign is lettered.
          iconComponent: Component {
            Row {
              spacing: Style.spacing.md

              OpticalGlyph {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.font.title
                height: Style.font.title
                text: Icons.g("portal")
                fontSize: Style.font.title
                color: Color.accent
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "PORTAL"
                color: root.panelText
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                font.letterSpacing: Style.space(3)
              }
            }
          }
          trailingControl: Component {
            Row {
              spacing: Style.spacing.md

              // Anything leaving this machine is stated in the header, in the
              // urgent color, whether or not its row is scrolled into view.
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.service && root.service.tunnelCount > 0
                implicitWidth: pillRow.implicitWidth + Style.spacing.lg * 2
                implicitHeight: Style.font.caption + Style.spacing.md
                radius: height / 2
                color: Util.alpha(root.pillColor, 0.15)
                border.width: 1
                border.color: Util.alpha(root.pillColor, 0.6)

                Row {
                  id: pillRow
                  anchors.centerIn: parent
                  spacing: Style.spacing.xs

                  OpticalGlyph {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.font.caption
                    height: Style.font.caption
                    text: Icons.g(root.broadcasting ? "broadcast" : "localRoute")
                    fontSize: Style.font.caption
                    color: root.pillColor
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    // Only public tunnels are "exposed"; local names never
                    // inflate the alarming number.
                    text: {
                      if (!root.service) return ""
                      var c = root.service.tunnelCounts
                      if (c.pub > 0) return c.pub + " exposed" + (c.named > 0 ? " · " + c.named + " named" : "")
                      return c.named + " named"
                    }
                    color: root.panelText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: text.length > 0
                textFormat: Text.PlainText
                text: {
                  if (!root.service) return ""
                  if (!root.service.everScanned) return "scanning…"
                  // The total is only interesting while a filter hides part of it.
                  if (root.query.length > 0)
                    return root.visibleEntries.length + (root.visibleEntries.length === 1 ? " match" : " matches")
                  return ""
                }
                color: Util.alpha(root.panelText, 0.55)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: Icons.g("cog")
                tooltipText: "Settings"
                foreground: root.settingsOpen ? Color.accent : root.panelText
                onClicked: root.toggleSettings()
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: Icons.g("refresh")
                tooltipText: "Rescan now"
                foreground: root.panelText
                onClicked: if (root.service) root.service.refreshAll()
              }
            }
          }
        }

        // ---- detail page ----------------------------------------------------
        Loader {
          width: parent.width
          active: root.detailEntry !== null
          visible: root.mode === "detail"

          sourceComponent: PortDetail {
            width: parent.width
            entry: root.detailEntry
            service: root.service
            brandColors: root.brandColors
            foreground: root.panelText
            fontFamily: root.fontFamily
            onClosed: root.detailEntry = null
          }
        }

        // ---- list page: hidden whenever another page owns the panel ---------
        Column {
          width: parent.width
          spacing: Style.spacing.md
          visible: root.mode !== "detail" && root.mode !== "settings" && root.mode !== "help"

          // ---- search ---------------------------------------------------------
          TextField {
            id: search
            width: parent.width
            placeholderText: "Filter by port, project, or framework"
            foreground: root.panelText
            // Arrows hand the keyboard back to the list; Esc clears the
            // filter first and only then leaves the field. The catcher is
            // blocked while this field has focus, so all of these are ours.
            Keys.onDownPressed: { keyCatcher.forceActiveFocus(); root.moveSelection(1) }
            Keys.onUpPressed: { keyCatcher.forceActiveFocus(); root.moveSelection(-1) }
            Keys.onTabPressed: keyCatcher.forceActiveFocus()
            Keys.onEscapePressed: {
              if (text.length > 0) text = ""
              else keyCatcher.forceActiveFocus()
            }
            // Keys handlers accept the event; onAccepted would let it reach the catcher.
            Keys.onReturnPressed: root.activateSelected()
            Keys.onEnterPressed: root.activateSelected()
          }

          // ---- portless infra strip -------------------------------------------
          // Local names are panel-level infrastructure, not a per-row action.
          // When the proxy is down this is the one place that says so, with the
          // fix attached; when it is running (or not installed) it is silent.
          Rectangle {
            width: parent.width
            visible: root.portlessProvider !== null && root.portlessProvider.status === "setup"
            implicitHeight: stripRow.implicitHeight + Style.spacing.lg
            radius: Style.cornerRadius
            color: Util.alpha(Color.accent, 0.08)
            border.width: 1
            border.color: Util.alpha(Color.accent, 0.35)

            HoverHandler { id: stripHover }

            Row {
              id: stripRow
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.lg
              anchors.right: stripLink.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              OpticalGlyph {
                id: stripGlyph
                anchors.verticalCenter: parent.verticalCenter
                width: Style.font.caption + Style.spacing.xs
                height: Style.font.caption
                text: Icons.g("localRoute")
                fontSize: Style.font.caption
                color: Color.accent
              }

              TickerText {
                anchors.verticalCenter: parent.verticalCenter
                text: stripLink.armed && root.portlessProvider
                  ? root.portlessProvider.setupClause
                  : (root.portlessProvider ? root.portlessProvider.detail : "")
                color: root.panelText
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                width: Math.min(implicitWidth, stripRow.width - stripGlyph.width - stripRow.spacing)
                hovered: stripHover.hovered
              }
            }

            // Two shapes of "needs setup": something this plugin may do itself
            // (after saying what, in the provider's own words), and something
            // only the user's terminal should do — copy, never execute.
            Row {
              id: stripLink
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm
              readonly property bool copyOnly: !!(root.portlessProvider && root.portlessProvider.fix)
              readonly property bool busy: root.service && root.service.busyAction === "portless:setup"
              property bool armed: false
              onVisibleChanged: armed = false

              LinkText {
                anchors.verticalCenter: parent.verticalCenter
                text: {
                  if (stripLink.busy) return "setting up…"
                  if (stripLink.copyOnly) return "Copy fix"
                  return stripLink.armed ? "set up" : "Set up"
                }
                color: Color.accent
                font.pixelSize: Style.font.bodySmall
                onClicked: {
                  if (!root.service || stripLink.busy) return
                  if (stripLink.copyOnly) {
                    root.service.copyText(root.portlessProvider.fix)
                  } else if (stripLink.armed) {
                    stripLink.armed = false
                    root.service.setupProvider("portless")
                  } else {
                    stripLink.armed = true
                  }
                }
              }

              Text {
                visible: stripLink.armed
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "·"
                color: Util.alpha(root.panelText, 0.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              LinkText {
                visible: stripLink.armed
                anchors.verticalCenter: parent.verticalCenter
                text: "cancel"
                color: Util.alpha(root.panelText, 0.7)
                font.pixelSize: Style.font.bodySmall
                onClicked: stripLink.armed = false
              }
            }
          }

          // ---- list -----------------------------------------------------------
          Flickable {
            id: listView
            width: parent.width
            implicitHeight: Math.min(list.implicitHeight, Style.space(420))
            contentWidth: width
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            // Keep the keyboard cursor on screen. Row heights vary (revealed
            // stats, subrows), so this reads the real geometry instead of
            // estimating from an index.
            function reveal(item) {
              if (!interactive) return
              var top = item.y - Style.spacing.md
              var bottom = item.y + item.implicitHeight + Style.spacing.md
              if (top < contentY) contentY = Util.clamp(top, 0, contentHeight - height)
              else if (bottom > contentY + height)
                contentY = Util.clamp(bottom - height, 0, contentHeight - height)
            }

            Column {
              id: list
              // A Flickable's children belong to its contentItem, so
              // parent.width here would be zero. Bind to the Flickable by id.
              width: listView.width
              spacing: 0

              Repeater {
                model: root.rows

                // Headers are one light Text; port rows are a heavy tree. A
                // Loader instantiates only the shape each row actually is,
                // instead of both with visibility switching.
                delegate: Item {
                  id: rowItem
                  required property var modelData
                  readonly property bool isHeader: modelData.type === "header"
                  readonly property bool isSelected: !isHeader
                    && rowItem.modelData.entry.port === root.selectedPort
                  onIsSelectedChanged: if (isSelected) listView.reveal(rowItem)
                  width: list.width
                  implicitHeight: isHeader
                    ? sectionHeader.implicitHeight + Style.spacing.lg
                    : (portLoader.item ? portLoader.item.implicitHeight : 0)

                  PanelSectionHeader {
                    id: sectionHeader
                    visible: rowItem.isHeader
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.spacing.xs
                    text: rowItem.isHeader ? rowItem.modelData.label : ""
                    foreground: Util.alpha(root.panelText, 0.5)
                    fontFamily: root.fontFamily
                  }

                  Loader {
                    id: portLoader
                    active: !rowItem.isHeader
                    width: parent.width
                    sourceComponent: PortRow {
                      width: rowItem.width
                      entry: rowItem.modelData.entry
                      service: root.service
                      brandColors: root.brandColors
                      foreground: root.panelText
                      selected: rowItem.isSelected
                      expandedKind: selected ? root.expandedKind : ""
                      portlessTld: root.portlessProvider && root.portlessProvider.tld
                        ? root.portlessProvider.tld : "localhost"
                      shareCursor: selected && root.expandedKind === "sharing" ? root.shareIndex : -1
                      verbs: selected ? root.verbsFor(entry) : []
                      verbCursor: selected && root.expandedKind === "actions" ? root.verbIndex : -1
                      confirmKind: root.pendingAction && root.pendingAction.entry.port === entry.port
                        ? root.pendingAction.kind : ""
                      confirmLabel: root.pendingAction && root.pendingAction.label ? root.pendingAction.label : entry.name
                      confirmClause: root.pendingAction && root.pendingAction.clause ? root.pendingAction.clause : ""
                      onDetailRequested: root.showDetail(entry)
                      onVerbClicked: function (verb) { root.activateVerb(entry, verb) }
                      onExpandRequested: function (kind) { root.expand(entry.port, kind) }
                      onEditorDone: { root.collapse(); keyCatcher.forceActiveFocus() }
                      onEditorCanceled: root.expand(entry.port, "actions")
                      onConfirmAccepted: root.confirmAccept()
                      onConfirmCanceled: root.pendingAction = null
                      onProviderChosen: function (provider) { root.chooseProvider(entry.port, provider) }
                    }
                  }
                }
              }
            }
          }

          // ---- empty state ----------------------------------------------------
          // Two rings, one in each of the panel's colors.
          Column {
            id: emptyState
            width: parent.width
            visible: root.service && root.service.everScanned && root.visibleEntries.length === 0
            spacing: Style.spacing.md
            topPadding: Style.spacing.lg
            bottomPadding: Style.spacing.md

            readonly property string ring: "  .----.  \n /      \\ \n|        |\n|        |\n|        |\n \\      / \n  `----'  "

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.spacing.xl

              Repeater {
                model: [Color.accent, Color.urgent]

                delegate: Text {
                  required property color modelData
                  textFormat: Text.PlainText
                  text: emptyState.ring
                  color: Util.alpha(modelData, 0.8)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  lineHeight: 0.92
                }
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: {
                var q = root.query.trim().toLowerCase()
                if (q === "cake") return "the cake is a lie."
                if (q.length > 0) return "nothing matches \"" + root.query + "\""
                return root.showSystem ? "nothing is listening." : "nothing of yours is listening. system ports are hidden."
              }
              color: Util.alpha(root.panelText, 0.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

        }

        // ---- settings -------------------------------------------------------
        // Six rows of chips is ~70 items nobody is looking at until the gear
        // is pressed, so it loads on demand like the detail page.
        Loader {
          width: parent.width
          active: root.mode === "settings"
          visible: active

          sourceComponent: Component {
            Column {
              width: parent.width
              spacing: Style.spacing.xs

              PanelSectionHeader {
                text: "SETTINGS"
                foreground: Util.alpha(root.panelText, 0.5)
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.settingDefs

                delegate: CursorSurface {
                  id: settingRow
                  required property var modelData
                  required property int index
                  readonly property string chosen: root.settingValue(settingRow.modelData)
                  width: parent.width
                  implicitHeight: Math.max(Style.spacing.controlHeight, optsFlow.implicitHeight + Style.spacing.md)
                  hasCursor: root.settingsIndex === settingRow.index
                  foreground: root.panelText

                  MouseArea {
                    anchors.fill: parent
                    z: -1
                    hoverEnabled: true
                    onEntered: root.settingsIndex = settingRow.index
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: settingRow.modelData.label
                    color: root.panelText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  ButtonGroup {
                    id: optsFlow
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.xs
                    // Tab belongs to the panel switcher; this row is driven by
                    // the panel cursor and the mouse.
                    focusable: false
                    options: settingRow.modelData.opts.map(function (v) {
                      return { value: v,
                               label: settingRow.modelData.prefix + v + settingRow.modelData.suffix }
                    })
                    value: settingRow.chosen
                    foreground: root.panelText
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onChanged: function (v) { root.applySetting(settingRow.modelData, v) }
                    onHovered: function (i, isHovered) { if (isHovered) root.settingsIndex = settingRow.index }
                  }
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: ".localhost works everywhere with zero setup. Other domains need a one-time resolver rule and a proxy restart — the strip on the main page carries the exact fix, and existing .localhost names keep working."
                color: Util.alpha(root.panelText, 0.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        // ---- keyboard help --------------------------------------------------
        Loader {
          width: parent.width
          active: root.mode === "help"
          visible: active

          sourceComponent: Component {
            Rectangle {
              width: parent.width
              implicitHeight: helpColumn.implicitHeight + Style.spacing.lg * 2
              radius: Style.cornerRadius
              color: Util.alpha(Color.accent, 0.06)
              border.width: 1
              border.color: Util.alpha(Color.accent, 0.3)

              Column {
                id: helpColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.spacing.lg
                spacing: Style.spacing.sm

                Repeater {
                  model: [
                    { k: "j / k  ·  g / G", d: "move · first / last" },
                    { k: "enter  ·  a", d: "actions for this port" },
                    { k: "l  ·  h / esc", d: "charts · back" },
                    { k: "type  or  /", d: "filter the list" },
                    { k: "o  ·  c", d: "open in browser · copy URL" },
                    { k: "n  ·  s", d: "name it locally · share to internet" },
                    { k: "w", d: "watch — persist metrics to disk" },
                    { k: "p  ·  r", d: "pause / resume · restart (dev)" },
                    { k: "x  ·  R", d: "stop process · rescan now" },
                    { k: "y / n", d: "answer a confirmation" },
                    { k: ",", d: "settings" },
                    { k: "tab  ·  esc", d: "next panel · close" }
                  ]

                  delegate: Item {
                    id: helpRow
                    required property var modelData
                    width: helpColumn.width
                    implicitHeight: helpKey.implicitHeight + Style.spacing.xs

                    Text {
                      id: helpKey
                      width: Style.space(150)
                      textFormat: Text.PlainText
                      text: helpRow.modelData.k
                      color: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      anchors.left: helpKey.right
                      anchors.leftMargin: Style.spacing.md
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: helpRow.modelData.d
                      color: Util.alpha(root.panelText, 0.75)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                  }
                }

                Text {
                  width: parent.width
                  topPadding: Style.spacing.md
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  readonly property var lines: [
                    "now you're thinking with ports.",
                    "the cake is a lie. the ports are not.",
                    "every port is a door. some of them are yours.",
                    "portal " + (root.service && root.service.manifest ? root.service.manifest.version : "")
                  ]
                  text: lines[Math.floor(Math.random() * lines.length)]
                  color: Util.alpha(Color.accent, 0.55)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.italic: true
                }
              }
            }
          }
        }

        // ---- error / toast --------------------------------------------------
        Text {
          width: parent.width
          visible: text.length > 0 && root.toastCopy === ""
          textFormat: Text.PlainText
          text: root.toast || (root.service ? root.service.lastError : "")
          // A hint is guidance, not an alarm.
          color: root.toast && root.toastIsHint ? Color.accent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---- setup card -----------------------------------------------------
        // A hint carrying a command: the title, the command as its own block,
        // and a button that copies it. Persistent like hint toasts; Esc clears.
        Rectangle {
          visible: root.toastCopy !== ""
          width: parent.width
          implicitHeight: cardColumn.implicitHeight + Style.spacing.lg
          radius: Style.cornerRadius
          color: Util.alpha(Color.accent, 0.08)
          border.width: 1
          border.color: Util.alpha(Color.accent, 0.35)

          Column {
            id: cardColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.lg
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.toast
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.toastCopy
              color: root.panelText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }

            LinkText {
              text: "Copy command"
              color: Color.accent
              font.pixelSize: Style.font.bodySmall
              onClicked: if (root.service) root.service.copyText(root.toastCopy)
            }
          }
        }

        // One quiet line keeps the keys discoverable without a manual.
        Text {
          readonly property var hintByMode: ({
            confirm:  "enter/y confirm · esc/n cancel",
            actions:  "h/l choose · enter act · esc close",
            share:    "h/l choose · enter expose · esc back",
            naming:   "enter save · esc back",
            settings: "j/k move · h/l change · esc back",
            detail:   "j/k next port · o open · c copy · w watch · esc back",
            list:     "j/k move · enter actions · l charts · ? shortcuts"
          })
          width: parent.width
          visible: root.mode !== "help"
          textFormat: Text.PlainText
          text: hintByMode[root.mode] || hintByMode.list
          color: Util.alpha(root.panelText, 0.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
