pragma ComponentBehavior: Bound

import QtQuick
import qs.Ui
import qs.Commons
import "lib/History.js" as History

// Buckets preserve extrema; hover reads the same time interval in every card.
Item {
  id: card

  property string title: ""
  property var modeOptions: []
  property string modeValue: ""
  signal modeRequested(string value)
  property bool loading: false
  property var view: History.aggregate([], 3600, 0)
  property string field: ""
  // Exact bounds over every raw sample in the selected window.
  property var lo: null
  property var hi: null
  property var last: null

  property color accent: Color.accent
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  property var format: function (v) { return String(Math.round(v)) }

  // Is zero a real reading for this metric, or just an unreachable floor?
  property bool zeroAnchored: true
  // What an all-zero series means, in the reader's words ("idle", "no
  // connections"). Falls back to a generic phrasing.
  property string zeroLabel: ""
  // Why there is nothing yet — an empty state should say what it is waiting
  // for, not just draw a blank box.
  property string emptyLabel: "waiting for the first sample"

  // collecting | zero | steady | active
  //
  // "steady" is decided on the FORMATTED bounds, not the raw ones. A
  // truncated axis magnifies whatever variation exists to fill the card, so a
  // process drifting between 20.6M and 21.4M — both of which the reader sees
  // as "21M" — would otherwise draw a cliff the numbers cannot explain. If
  // the difference is below what the card displays, there is nothing to plot.
  readonly property string phase: {
    if (lo === null || hi === null) return "collecting"
    if (hi === 0 && lo === 0) return "zero"
    if (hi === lo || format(lo) === format(hi)) return "steady"
    return "active"
  }
  readonly property bool hasShape: phase === "active"

  readonly property var series: view.buckets
  property real hoverTime: -1
  signal hoverTimeRequested(real time)
  readonly property int hoverIndex: hoverTime < 0 ? -1 : History.bucketAt(view, hoverTime)

  // Shared plot geometry for the canvas and the crosshair overlay.
  readonly property int pad: 2
  readonly property real plotFloor: {
    if (phase !== "active" || zeroAnchored) return 0
    return lo - (hi - lo) * 0.15                        // headroom below a truncated band
  }
  readonly property real plotSpan: {
    if (phase !== "active") return 1
    return zeroAnchored ? hi * 1.08 : (hi - lo) * 1.3
  }

  function plotX(time) {
    return pad + (canvas.width - 2 * pad) * (time - view.start) / (view.end - view.start)
  }
  function plotY(value) {
    if (!hasShape) return phase === "zero" ? canvas.height - pad : canvas.height / 2
    return canvas.height - pad - (canvas.height - 2 * pad) * (value - plotFloor) / plotSpan
  }
  function hoverAt(x) {
    var fraction = Util.clamp((x - pad) / Math.max(1, plot.width - 2 * pad), 0, 1)
    hoverTimeRequested(view.start + fraction * (view.end - view.start))
  }

  implicitHeight: Style.space(96)

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Style.normalFillFor(card.foreground, card.accent, Color.urgent)
    borderSpec: Border.controlSpec("normal", card.foreground, card.accent)
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.lg
    spacing: Style.spacing.xs

    Item {
      id: heading
      width: parent.width
      height: Math.max(Style.font.heading, modeControls.implicitHeight)

      Row {
        id: modeControls
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs
        Repeater {
          model: card.modeOptions
          Button {
            required property var modelData
            text: modelData.label
            selected: modelData.value === card.modeValue
            bordered: true
            focusable: false
            horizontalPadding: Style.spacing.xs
            verticalPadding: 0
            foreground: card.foreground
            fontFamily: card.fontFamily
            fontSize: Style.font.caption
            onClicked: card.modeRequested(modelData.value)
          }
        }
      }

      Text {
        visible: card.modeOptions.length === 0
        anchors.left: parent.left
        anchors.baseline: heroText.baseline
        textFormat: Text.PlainText
        text: card.title
        color: Util.alpha(card.foreground, 0.55)
        font.family: card.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: heroText
        anchors.right: parent.right
        anchors.top: parent.top
        textFormat: Text.PlainText
        text: {
          if (card.hoverTime >= 0) {
            var bucket = card.series[card.hoverIndex]
            return !bucket || bucket[card.field].avg === null ? "no sample"
              : card.format(bucket[card.field].avg)
          }
          return card.last === null ? "—" : card.format(card.last)
        }
        // Dim only when there is genuinely nothing to read. A steady value is
        // still the answer to "how much" — it just is not a trend.
        color: card.phase === "zero" || card.phase === "collecting"
          ? Util.alpha(card.foreground, 0.5) : card.foreground
        font.family: card.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }
    }

    Item {
      id: plot
      width: parent.width
      height: parent.height - heading.height - Style.font.caption - Style.spacing.xs * 2

      Canvas {
        id: canvas
        anchors.fill: parent
        visible: !card.loading

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          if (card.lo === null) return
          var previous = null
          for (var i = 0; i < card.series.length; i++) {
            var bucket = card.series[i]
            var metric = bucket[card.field]
            if (metric.count === 0) { previous = null; continue }
            var x = card.plotX((bucket.t + bucket.end) / 2)
            var y = card.plotY(metric.avg)
            ctx.strokeStyle = Util.alpha(card.accent, 0.55)
            ctx.lineWidth = 2
            ctx.beginPath()
            ctx.moveTo(x, card.plotY(metric.lo))
            ctx.lineTo(x, card.plotY(metric.hi))
            ctx.stroke()
            ctx.strokeStyle = card.accent
            ctx.lineWidth = 1.5
            if (History.connected(previous, bucket, card.field)) {
              ctx.beginPath()
              ctx.moveTo(card.plotX((previous.t + previous.end) / 2), card.plotY(previous[card.field].avg))
              ctx.lineTo(x, y)
              ctx.stroke()
            } else {
              ctx.fillStyle = card.accent
              ctx.fillRect(x - 1, y - 1, 2, 2)
            }
            previous = bucket
          }
        }
      }

      Rectangle {
        visible: !card.loading && card.hoverTime >= card.view.start && card.hoverTime <= card.view.end
        x: card.plotX(card.hoverTime)
        y: card.pad
        width: 1
        height: plot.height - card.pad * 2
        color: Util.alpha(card.foreground, 0.35)
      }

      Text {
        anchors.centerIn: parent
        visible: card.loading || card.phase === "collecting"
        width: plot.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: card.loading ? "Loading…" : card.emptyLabel
        color: Util.alpha(card.foreground, 0.45)
        font.family: card.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      HoverHandler {
        id: plotHover
        enabled: !card.loading
        onPointChanged: if (hovered) card.hoverAt(point.position.x)
        onHoveredChanged: {
          if (hovered) card.hoverAt(point.position.x)
          else card.hoverTimeRequested(-1)
        }
      }
    }

    Item {
      width: parent.width
      height: Style.font.caption

      Text {
        anchors.left: parent.left
        anchors.right: parent.right
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: {
          if (card.loading) return ""
          if (card.hoverTime >= 0) {
            var bucket = card.series[card.hoverIndex]
            var metric = bucket ? bucket[card.field] : null
            return metric && metric.count > 0 ? "min " + card.format(metric.lo) + " · max " + card.format(metric.hi) : ""
          }
          if (card.phase === "collecting") return ""
          if (card.phase === "zero") return card.zeroLabel !== "" ? card.zeroLabel : "none recorded"
          if (card.phase === "steady") return "steady at " + card.format(card.lo)
          // A truncated axis must say so: the band IS the scale.
          return card.zeroAnchored ? "peak " + card.format(card.hi)
            : card.format(card.lo) + " – " + card.format(card.hi)
        }
        color: Util.alpha(card.foreground, 0.4)
        font.family: card.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  onLoadingChanged: canvas.requestPaint()
  onViewChanged: canvas.requestPaint()
  onLoChanged: canvas.requestPaint()
  onHiChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()
  Component.onCompleted: canvas.requestPaint()
}
