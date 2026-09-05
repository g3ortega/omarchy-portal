pragma ComponentBehavior: Bound

import QtQuick
import qs.Ui
import qs.Commons
import "lib/Icons.js" as Icons
import "lib/Colors.js" as Colors
import "lib/Format.js" as Format

// Charts for one port: identity, live vitals, and four sparklines.
// Reached from the row's metrics icon or the l key.
//
// Data shape: one pass per scan over the merged series computes exact
// lo/hi for every metric, and a strided view (≤ ~400 points) feeds the
// canvases — paint cost is capped no matter how much disk history a watched
// port carries.
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

  readonly property int historyPort: service && service.pluginDir && entry && watched ? entry.port : 0
  property string historyStatus: "idle"
  property var diskPrefix: []

  // The hovered instant, shared by every card on the page.
  property int hoverIndex: -1

  Connections {
    target: detail.service
    function onDiskHistoryLoaded(port, samples, error) {
      if (!detail.historyPort || port !== detail.historyPort) return
      var ring = detail.service.history[port] || []
      var cutoff = ring.length > 0 ? ring[0].t : Number.MAX_SAFE_INTEGER
      var prefix = []
      for (var i = 0; i < samples.length; i++) {
        if (samples[i].t < cutoff) prefix.push(samples[i])
      }
      detail.diskPrefix = prefix
      detail.historyStatus = error ? "error" : "ready"
    }
  }

  onHistoryPortChanged: {
    diskPrefix = []
    hoverIndex = -1
    historyStatus = historyPort ? "loading" : "idle"
    if (historyPort) service.loadDiskHistory(historyPort)
  }

  // zeroAnchored says whether zero is a reading this metric can actually
  // take. It decides both the axis floor and whether the area is drawn — see
  // the rule at the top of SparkCard.qml. Resident memory is the one metric
  // here that never approaches zero while the process is alive, so it gets a
  // truncated axis, no fill, and a range label that declares the band.
  readonly property var metricDefs: [
    { title: "LATENCY",     field: "latMs",  fmt: function (v) { return Math.round(v) + "ms" },
      zeroAnchored: true,  zeroLabel: "instant" },
    { title: "CONNECTIONS", field: "conns",  fmt: function (v) { return String(Math.round(v)) },
      zeroAnchored: true,  zeroLabel: "no connections" },
    { title: "CPU",         field: "cpuPct", fmt: function (v) { return Math.round(v) + "%" },
      zeroAnchored: true,  zeroLabel: "idle" },
    { title: "MEMORY",      field: "rssKb",  fmt: Format.bytesKb,
      zeroAnchored: false, zeroLabel: "" }
  ]

  // Latency is the one series that can stay empty forever rather than merely
  // being young: it comes from an HTTP probe, and a port with no URL is never
  // probed. Say which it is.
  function emptyReasonFor(field) {
    if (field !== "latMs") return "waiting for the first sample"
    if (!effectiveUrl) return "no URL to probe"
    return watched ? "waiting for the first probe" : "probed while this page is open"
  }

  // The single per-scan pass: exact stats for each metric over the full
  // series, plus the strided paint view.
  readonly property var view: {
    // Read for the dependency only: the ring is mutated in place, and
    // historyRevision is what changes.
    void (service ? service.historyRevision : 0)
    var ring = service && entry ? (service.history[entry.port] || []) : []
    var full = diskPrefix.length > 0 ? diskPrefix.concat(ring) : ring

    var agg = ({})
    for (var m = 0; m < metricDefs.length; m++) {
      agg[metricDefs[m].field] = { lo: null, hi: null }
    }
    for (var i = 0; i < full.length; i++) {
      for (var f = 0; f < metricDefs.length; f++) {
        var key = metricDefs[f].field
        var v = full[i][key]
        if (v === undefined || v === null) continue
        var st = agg[key]
        if (st.lo === null || v < st.lo) st.lo = v
        if (st.hi === null || v > st.hi) st.hi = v
      }
    }

    var maxPoints = 400
    var strided = full
    if (full.length > maxPoints) {
      var step = Math.ceil(full.length / maxPoints)
      strided = []
      for (var j = 0; j < full.length; j += step) strided.push(full[j])
      if (strided[strided.length - 1] !== full[full.length - 1]) strided.push(full[full.length - 1])
    }

    var minutes = full.length >= 2
      ? Math.round((full[full.length - 1].t - full[0].t) / 60) : 0
    return { samples: strided, stats: agg, count: full.length, minutes: minutes }
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
          // Watching = active monitoring: samples persist to disk (~24h) and
          // the port joins the latency probe set.
          iconText: Icons.g(detail.watched ? "watch" : "unwatch")
          tooltipText: detail.watched
            ? "Watching — samples persist for ~24h. Click to stop."
            : "Watch — persist samples and probe latency"
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
          samples: detail.view.samples
          lo: detail.view.stats[modelData.field].lo
          hi: detail.view.stats[modelData.field].hi
          last: detail.stats && detail.stats[modelData.field] != null ? detail.stats[modelData.field] : null
          loading: detail.historyStatus === "loading"
          hoverIndex: detail.hoverIndex
          onHoverIndexRequested: function (i) { detail.hoverIndex = i }
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
      textFormat: Text.PlainText
      // While hovering, this line answers "when" once for all four cards —
      // so no card has to repeat the timestamp beside its value.
      text: {
        var h = detail.hoverIndex
        var samples = detail.view.samples
        if (h >= 0 && samples[h]) {
          var d = new Date(samples[h].t * 1000)
          var ago = Math.max(0, Math.round(Date.now() / 1000) - samples[h].t)
          return Qt.formatDateTime(d, "HH:mm:ss") + "  ·  " + Format.span(ago) + " ago"
        }
        if (detail.historyStatus === "loading") return "Loading saved history"
        if (detail.historyStatus === "error") return "Saved history unavailable · showing live samples"
        var n = detail.view.count
        if (n === 0) return "Collecting samples — one every scan."
        var m = detail.view.minutes
        var note = (m <= 0 ? "" : "last " + Format.span(m * 60) + " · ") + n + " samples"
        note += detail.watched ? " · persisted ~24h" : " · in memory (~1h) — Watch to persist"
        return note
      }
      color: Util.alpha(detail.foreground, detail.hoverIndex >= 0 ? 0.7 : 0.4)
      font.family: detail.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
