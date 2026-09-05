pragma ComponentBehavior: Bound

import QtQuick
import qs.Ui
import qs.Commons
import "lib/Icons.js" as Icons

// Bar entry for Portal. Deliberately thin: all state lives in Service.qml so
// that a two-monitor setup does not scan twice.
BarWidget {
  id: root
  moduleName: "g3ortega.portal"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("g3ortega.portal") : null

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing : false

  // The panel is created on first open, not at shell startup: each monitor has
  // one of these widgets, and an unopened panel is a whole KeyboardPanel tree
  // nobody is looking at. The first open after activation must be deferred one
  // tick — showing in the same tick the KeyboardPanel is created loses the
  // open edge and the surface never appears.
  function _withPanel(method) {
    if (panelLoader.item) { panelLoader.item[method](); return }
    panelLoader.active = true
    Qt.callLater(function () { if (panelLoader.item) panelLoader.item[method]() })
  }

  function open() { _withPanel("open") }
  function toggle() { _withPanel("toggle") }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // Settings live on the shell.json entry; the service does the work, so push
  // them down whenever either side changes.
  function pushSettings() {
    if (!service) return
    service.refreshSeconds = Number(setting("refreshSeconds", 5)) || 5
    service.namingMode = String(setting("portlessAutoName", "Project"))
    service.portlessTld = String(setting("portlessTld", "localhost"))
  }

  // The live shell.json entry for this widget. The injected `settings` object
  // is a snapshot the host does not refresh when a plugin component is
  // re-registered, so merging onto it can silently revert earlier saves.
  function liveEntry() {
    var cfg = bar && bar.shell ? bar.shell.shellConfig : null
    var layout = cfg && cfg.bar ? cfg.bar.layout : null
    if (!layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var arr = layout[sections[s]] || []
      for (var i = 0; i < arr.length; i++) {
        // A string entry is a legal shorthand, but it carries no settings and
        // the host's writer cannot match it — treat it as "nothing to merge".
        if (Util.isPlainObject(arr[i]) && arr[i].id === moduleName) return arr[i]
      }
    }
    return null
  }

  // updateEntryInline REPLACES the whole entry, so a save carries every
  // current value plus the one change. Returns whether anything persisted.
  function saveSetting(key, value) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return false
    var current = liveEntry() || settings || ({})
    var merged = { id: moduleName }
    for (var k in current) if (k !== "id") merged[k] = current[k]
    merged[key] = value
    // Apply locally first so the chip reflects the click immediately rather
    // than waiting for the shell's write-back (same as the built-in clock).
    // Every read of `settings` is now correct, which is what lets the disk
    // write be coalesced below.
    root.settings = merged
    root._pending = merged
    persistTimer.restart()
    return true
  }

  // A held h/l repeats at ~25/s, and each persist is two deep clones of the
  // whole shell config plus an atomic write whose watcher fires a reload. One
  // write per burst is indistinguishable to the user and cheap to the shell.
  property var _pending: null

  Timer {
    id: persistTimer
    interval: 200
    onTriggered: {
      if (!root._pending) return
      var entry = root._pending
      root._pending = null
      if (root.bar.shell.updateEntryInline(root.moduleName, entry) === false)
        console.warn("g3ortega.portal: shell.json did not accept the settings write")
    }
  }

  readonly property bool showCount: String(setting("barLabel", "Count")) !== "Icon only"

  function summarizeCounts(counts, devCount) {
    var lines = []
    if (counts.pub > 0) lines.push(counts.pub + (counts.pub === 1 ? " public share" : " public shares"))
    if (counts.named > 0) lines.push(counts.named + (counts.named === 1 ? " named route" : " named routes"))
    if (devCount > 0 || lines.length === 0)
      lines.push(devCount + (devCount === 1 ? " dev server" : " dev servers"))
    return {
      broadcasting: counts.pub > 0,
      count: counts.pub > 0 ? counts.pub : counts.named > 0 ? counts.named : devCount,
      tooltip: lines.join(" · ")
    }
  }

  readonly property var indicator: summarizeCounts(service ? service.tunnelCounts : ({ pub: 0, named: 0 }),
                                                  service ? service.devCount : 0)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The host injects `bar` and `settings` after construction, so the service
  // binding may land before or after completion; both paths push, and
  // registerWidget dedupes.
  onServiceChanged: {
    pushSettings()
    if (service) service.registerWidget(root)
  }
  onSettingsChanged: pushSettings()
  Component.onCompleted: {
    pushSettings()
    if (service) service.registerWidget(root)
  }
  Component.onDestruction: {
    if (service) service.unregisterWidget(root)
  }

  Connections {
    target: root.service
    function onSummonRequested() {
      // One panel per keypress: the service names a single responder among the
      // per-monitor widgets, and hands the role on when that monitor goes.
      if (root.service.summonWidget() === root) root.toggle()
    }
  }

  Loader {
    id: panelLoader
    active: false
    visible: false
    sourceComponent: PortalPanel {
      bar: root.bar
      settings: root.settings
      service: root.service
      anchorItem: button
      hostWidget: root
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.opened
    readonly property string glyph: Icons.g("portal")
    labelVisible: false
    // Vertical bars have no room for a label.
    text: root.vertical || !root.showCount || root.indicator.count <= 0 ? glyph : glyph + " " + root.indicator.count
    foreground: root.indicator.broadcasting
      ? (root.bar ? root.bar.urgent : Color.urgent)
      : (root.bar ? root.bar.barForeground : Color.foreground)
    tooltipText: root.service ? root.indicator.tooltip : "Portal"

    OpticalGlyph {
      id: label
      anchors.fill: parent
      transform: Translate { x: label.width / 2 - label.paintedCenterX }
      text: button.text
      fontFamily: button.fontFamily
      fontSize: button.fontSize
      color: button.active ? button.activeColor : button.foreground
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton && root.service) root.service.refreshAll()
    }
  }
}
