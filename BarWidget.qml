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

  function mergedSettings(changes) {
    var merged = Object.assign({ id: moduleName }, liveEntry() || settings || ({}))
    for (var key in changes) merged[key] = changes[key]
    return merged
  }

  function saveSetting(key, value) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return false
    var changes = Object.assign({}, _pending || ({}))
    changes[key] = value
    root._pending = changes
    root.settings = mergedSettings(changes)
    persistTimer.restart()
    return true
  }

  property var _pending: null
  property string settingsSaveError: ""

  Timer {
    id: persistTimer
    interval: 200
    onTriggered: {
      if (!root._pending) return
      var entry = root.mergedSettings(root._pending)
      var current = root.liveEntry()
      // The host also returns false when the entry already matches.
      var unchanged = current && Object.keys(current).length === Object.keys(entry).length
        && Object.keys(entry).every(function (key) { return current[key] === entry[key] })
      if (!unchanged && root.bar.shell.updateEntryInline(root.moduleName, entry) === false) {
        root.settingsSaveError = "Settings were not saved. Select a setting to retry. Check the Portal entry in ~/.config/omarchy/shell.json."
        return
      }
      root._pending = null
      root.settings = entry
      root.settingsSaveError = ""
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
