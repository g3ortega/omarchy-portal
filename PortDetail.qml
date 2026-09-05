pragma ComponentBehavior: Bound

import QtQuick
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
  property int rangeSeconds: 3600
  signal rangeRequested(int seconds)
  property real hoverTime: -1
  property int requestId: 0
  property string historyStatus: "idle"
  property string historyError: ""
  property string historyWarning: ""
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
      historyWarning = ""
      historyStatus = queryKey ? "loading" : "idle"
    }
    if (!queryKey || !service || !entry) return
    requestId = ++service.metricRequestSequence
    service.loadMetricRange(entry.port, rangeSeconds, Math.floor(Date.now() / 1000), requestId)
  }

  Connections {
    target: detail.service
    function onMetricRangeLoaded(port, seconds, id, result, error, warning) {
      if (!detail.queryKey || !detail.entry || id !== detail.requestId || port !== detail.entry.port
          || seconds !== detail.rangeSeconds) return
      detail.historyError = error
      detail.historyWarning = warning
      if (!error) detail.savedView = result
      detail.historyStatus = error ? "error" : "ready"
    }
    function onMetricsRevisionChanged() { detail.requestRange(false) }
  }
  onQueryKeyChanged: requestRange(true)
  onWatchedChanged: requestRange(false)

  Timer {
    interval: 30000
    running: detail.active && detail.queryKey !== ""
    repeat: true
    onTriggered: detail.requestRange(false)
  }

  readonly property var metricDefs: [
    { title: "HTTP LATENCY",     field: "latMs",  fmt: function (v) { return Math.round(v) + "ms" },
      zeroAnchored: true,  zeroLabel: "instant" },
    { title: "CONNECTIONS", field: "conns",  fmt: function (v) { return String(Math.round(v)) },
      zeroAnchored: true,  zeroLabel: "no connections" },
    { title: "CPU",         field: "cpuPct", fmt: function (v) { return Math.round(v) + "%" },
      zeroAnchored: true,  zeroLabel: "idle" },
    { title: "MEMORY",      field: "rssKb",  fmt: Format.bytesKb,
      zeroAnchored: false, zeroLabel: "" }
  ]

  function emptyReasonFor(field) {
    return field === "latMs" ? "HTTP response unavailable" : "No samples in this range"
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
      width: parent.width
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
             detail.historyWarning, detail.service ? detail.service.metricsError : ""]
        .filter(function (text) { return text !== "" }).join(" · ")
      color: Color.urgent
      font.family: detail.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
