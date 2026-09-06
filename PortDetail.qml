pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import qs.Ui
import qs.Commons
import "lib/Icons.js" as Icons
import "lib/Colors.js" as Colors
import "lib/Format.js" as Format
import "lib/History.js" as History

// Live vitals and one shared time window for all four metrics.
Item {
  id: detail

  property var entry: null
  property var service: null
  readonly property var route: service && entry ? service.routeFor(entry.port) : null
  property bool brandColors: true
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  signal closed()

  readonly property bool watched: service && entry ? service.isWatched(entry.port) : false
  readonly property var stats: service && entry ? (service.stats[entry.port] || null) : null
  readonly property string effectiveUrl: service && entry ? service.urlFor(entry.port, entry.url) : ""

  property bool active: true
  onActiveChanged: if (!active && service) service.cancelMetricRanges(detail)
  property int rangeSeconds: 3600
  signal rangeRequested(int seconds)
  property real hoverTime: -1
  property int requestId: 0
  property string historyStatus: "loading"
  property string historyError: ""
  property var savedView: null
  readonly property string queryKey: active && service && service.pluginDir && entry
    ? service.pluginDir + ":" + entry.port + ":" + rangeSeconds : ""
  readonly property var liveView: {
    void (service ? service.historyRevision : 0)
    return History.aggregate(service && entry ? (service.history[entry.port] || []) : [],
                             rangeSeconds, Math.floor(Date.now() / 1000))
  }
  readonly property var view: savedView && savedView.count > 0 ? savedView : liveView
  readonly property bool retained: savedView !== null && savedView.count > 0

  function requestRange(initial) {
    if (initial) {
      savedView = null
      hoverTime = -1
      historyError = ""
      historyStatus = queryKey ? "loading" : "idle"
    }
    if (!queryKey || !service || !entry) {
      if (service) service.cancelMetricRanges(detail)
      return
    }
    requestId = ++service.metricRequestSequence
    service.loadMetricRange(entry.port, rangeSeconds, Math.floor(Date.now() / 1000), requestId, detail)
  }

  Connections {
    target: detail.service
    function onMetricRangeLoaded(port, seconds, id, result, error) {
      if (!detail.queryKey || !detail.entry || id !== detail.requestId || port !== detail.entry.port
          || seconds !== detail.rangeSeconds) return
      detail.historyError = error
      if (!error) detail.savedView = result
      detail.historyStatus = error ? "error" : "ready"
    }
    function onMetricsRevisionChanged() { detail.requestRange(false) }
  }
  onQueryKeyChanged: Qt.callLater(requestRange, true)
  Component.onCompleted: Qt.callLater(requestRange, true)
  Component.onDestruction: if (service) service.cancelMetricRanges(detail)

  Timer {
    interval: 30000
    running: detail.active && detail.queryKey !== ""
    repeat: true
    onTriggered: detail.requestRange(false)
  }

  property string latencyChoice: ""
  readonly property int latencyPort: entry ? entry.port : 0
  readonly property string latencyField: entry && entry.httpProbe === true ? (latencyChoice || "latMs") : "tcpRttMs"
  onLatencyPortChanged: latencyChoice = ""

  function toggleLatency() {
    if (entry && entry.httpProbe === true)
      latencyChoice = latencyField === "latMs" ? "tcpRttMs" : "latMs"
  }

  function formatLatency(value) {
    if (value === null || value === undefined) return "—"
    if (value > 0 && value < 0.001) return "<0.001ms"
    var decimals = value < 1 ? 3 : value < 10 ? 2 : value < 100 ? 1 : 0
    return Number(value.toFixed(decimals)) + "ms"
  }

  readonly property var metricDefs: [
    { title: latencyField === "latMs" ? "HTTP LATENCY" : "TCP RTT", field: latencyField, fmt: formatLatency,
      zeroAnchored: true, zeroLabel: "below timing resolution" },
    { title: "CONNECTIONS", field: "conns",  fmt: function (v) { return String(Math.round(v)) },
      zeroAnchored: true,  zeroLabel: "no connections" },
    { title: "CPU",         field: "cpuPct", fmt: function (v) { return Math.round(v) + "%" },
      zeroAnchored: true,  zeroLabel: "idle" },
    { title: "MEMORY",      field: "rssKb",  fmt: Format.bytesKb,
      zeroAnchored: false, zeroLabel: "" }
  ]

  function emptyReasonFor(field) {
    if (field === "latMs") return "HTTP response unavailable"
    if (field === "tcpRttMs") return stats && stats.conns === 0 ? "No active connections" : "No RTT samples in this range"
    return "No samples in this range"
  }

  function timeLabel(time) {
    return Qt.formatDateTime(new Date(time * 1000), rangeSeconds >= 86400 ? "ddd HH:mm" : "HH:mm")
  }

  implicitHeight: layout.implicitHeight

  Column {
    id: layout
    width: parent.width
    spacing: Style.spacing.md

    // ---- identity -----------------------------------------------------------
    // Hand-rolled rather than PanelHero: the hero force-uppercases its meta,
    // pins its color, and has no leading slot for the back button.
    Item {
      width: parent.width
      height: Style.space(30)

      PanelActionButton {
        id: backBtn
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: Icons.g("back")
        tooltipText: "Back to ports"
        foreground: detail.foreground
        onClicked: detail.closed()
      }

      OpticalGlyph {
        id: stackGlyph
        anchors.left: backBtn.right
        anchors.leftMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.iconLarge
        height: Style.font.iconLarge
        text: detail.entry ? Icons.g(detail.entry.icon) : ""
        fontSize: Style.font.icon
        color: Colors.iconColor(detail.entry, detail.brandColors, Color.popups.background, detail.foreground)
      }

      Column {
        anchors.left: stackGlyph.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: headActions.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: detail.route ? detail.route.host : (detail.entry ? detail.entry.name : "")
          color: detail.route ? Color.accent : detail.foreground
          font.family: detail.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: {
            if (!detail.entry) return ""
            var bits = [":" + detail.entry.port]
            if (detail.entry.label) bits.push(detail.entry.label)
            if (detail.stats && detail.stats.upSec != null)
              bits.push(Format.uptimeLine(detail.stats.upSec))
            if (detail.stats && detail.stats.paused) bits.push("paused")
            return bits.join(" · ")
          }
          color: detail.stats && detail.stats.paused
            ? Color.urgent : Util.alpha(detail.foreground, 0.55)
          font.family: detail.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: headActions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        PanelActionButton {
          iconText: Icons.g(detail.watched ? "watch" : "unwatch")
          tooltipText: detail.watched
            ? "Watching · retain 48 hours. Click to pause recording."
            : "Watch · retain samples for 48 hours"
          foreground: detail.watched ? Color.accent : detail.foreground
          onClicked: if (detail.service && detail.entry) detail.service.toggleWatched(detail.entry.port)
        }

        PanelActionButton {
          visible: detail.effectiveUrl !== ""
          iconText: Icons.g("open")
          tooltipText: "Open " + detail.effectiveUrl
          foreground: detail.foreground
          onClicked: if (detail.service) detail.service.openUrl(detail.effectiveUrl)
        }

        PanelActionButton {
          visible: detail.effectiveUrl !== ""
          iconText: Icons.g("copy")
          tooltipText: "Copy " + detail.effectiveUrl
          foreground: detail.foreground
          onClicked: if (detail.service) detail.service.copyText(detail.effectiveUrl)
        }
      }
    }

    ButtonGroup {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.spacing.xs
      focusable: false
      options: History.ranges.map(function (r) { return { value: String(r.seconds), label: r.label } })
      value: String(detail.rangeSeconds)
      foreground: detail.foreground
      fontFamily: detail.fontFamily
      fontSize: Style.font.caption
      onChanged: function (value) { detail.rangeRequested(Number(value)) }
    }

    // ---- charts: small multiples, one metric each ---------------------------
    Grid {
      id: chartGrid
      width: parent.width
      columns: 2
      columnSpacing: Style.spacing.lg
      rowSpacing: Style.spacing.lg

      readonly property real cardWidth: (width - columnSpacing) / 2

      Repeater {
        model: detail.metricDefs

        SparkCard {
          required property var modelData
          width: chartGrid.cardWidth
          title: modelData.title
          modeOptions: (modelData.field === "latMs" || modelData.field === "tcpRttMs")
            && detail.entry && detail.entry.httpProbe === true
            ? [{ value: "latMs", label: "HTTP" }, { value: "tcpRttMs", label: "TCP" }] : []
          modeValue: detail.latencyField
          onModeRequested: function (value) { detail.latencyChoice = value }
          field: modelData.field
          format: modelData.fmt
          view: detail.view
          lo: detail.view.stats[modelData.field].lo
          hi: detail.view.stats[modelData.field].hi
          last: detail.stats && detail.stats[modelData.field] != null ? detail.stats[modelData.field] : null
          loading: detail.historyStatus === "loading"
          hoverTime: detail.hoverTime
          onHoverTimeRequested: function (time) { detail.hoverTime = time }
          zeroAnchored: modelData.zeroAnchored
          zeroLabel: modelData.zeroLabel
          emptyLabel: detail.emptyReasonFor(modelData.field)
          foreground: detail.foreground
          fontFamily: detail.fontFamily
        }
      }
    }

    Text {
      width: parent.width
      visible: detail.latencyField === "tcpRttMs"
      text: "Kernel RTT · may stay unchanged while idle"
      HoverHandler { id: tcpHelpHover }
      Controls.ToolTip {
        id: tcpTooltip
        visible: tcpHelpHover.hovered
        delay: 500
        text: "Kernel round-trip estimate averaged across existing port connections"
          + (detail.stats && detail.stats.tcpRttCount > 0 ? " (" + detail.stats.tcpRttCount + " contributing sockets)" : "")
          + ". Measures TCP transport, not application response or health."
        contentItem: Text {
          text: tcpTooltip.text
          textFormat: Text.PlainText
          width: Style.space(280)
          wrapMode: Text.WordWrap
          color: Color.tooltip.text
          font.family: detail.fontFamily
          font.pixelSize: Style.font.caption
        }
        background: Rectangle { color: Color.tooltip.background; radius: Style.cornerRadius }
      }
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Util.alpha(detail.foreground, 0.45)
      font.family: detail.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: detail.historyStatus !== "loading"
      horizontalAlignment: Text.AlignHCenter
      text: Qt.formatDateTime(new Date(detail.view.start * 1000), "ddd HH:mm") + " – "
        + Qt.formatDateTime(new Date(detail.view.end * 1000), "ddd HH:mm")
      textFormat: Text.PlainText
      color: Util.alpha(detail.foreground, 0.45)
      font.family: detail.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: historyFooter
      width: parent.width
      height: footerFont.height * 2
      FontMetrics { id: footerFont; font: historyFooter.font }
      maximumLineCount: 2
      elide: Text.ElideRight
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: {
        if (detail.historyStatus === "loading") return "Loading saved history"
        if (detail.hoverTime >= 0) {
          var index = History.bucketAt(detail.view, detail.hoverTime)
          if (index < 0) return detail.timeLabel(detail.hoverTime) + " · no samples"
          var bucket = detail.view.buckets[index]
          return Qt.formatDateTime(new Date(bucket.t * 1000), "ddd HH:mm:ss") + " – "
            + Qt.formatDateTime(new Date(bucket.end * 1000), "HH:mm:ss")
            + " · " + bucket.count + " samples · averages with min–max"
        }
        var note = detail.view.count + " samples in range"
        if (detail.view.first !== null)
          note += " · coverage " + Format.span(Math.max(0, detail.view.last - detail.view.first))
        note += detail.retained ? (detail.watched ? " · retaining 48 hours" : " · recording paused")
          : " · live memory only" + (detail.watched ? "" : " · Watch to record")
        return note
      }
      color: Util.alpha(detail.foreground, detail.hoverTime >= 0 ? 0.7 : 0.4)
      font.family: detail.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: text.length > 0
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: [detail.historyError ? "Saved history unavailable: " + detail.historyError : "",
             detail.service ? detail.service.metricsError : ""]
        .filter(function (text) { return text !== "" }).join(" · ")
      color: Color.urgent
      font.family: detail.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
