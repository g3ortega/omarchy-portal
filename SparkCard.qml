pragma ComponentBehavior: Bound

import QtQuick
import qs.Ui
import qs.Commons

// Fill only zero-anchored plots. A truncated axis shows relative change.
// The owner supplies strided samples and exact full-series bounds to cap painting cost.
// The crosshair is an overlay, so hovering does not repaint the canvas.
Item {
  id: card

  property string title: ""
  property bool loading: false
  property var samples: []          // strided [{t, <field>...}] oldest -> newest
  property string field: ""
  // Exact over the full (un-strided) series, provided by the owner.
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
    if (lo === null) return "collecting"
    if (hi === 0 && lo === 0) return "zero"
    if (hi === lo || format(lo) === format(hi)) return "steady"
    return "active"
  }
  readonly property bool hasShape: phase === "active"

  readonly property var series: {
    var out = []
    for (var i = 0; i < samples.length; i++) {
      var v = samples[i][field]
      out.push({ t: samples[i].t, v: (v === undefined || v === null) ? null : Number(v) })
    }
    return out
  }

  // Owned by the page, not the card: every card renders the same sample
  // array, so one X is one instant across all of them. Hovering any card
  // reads out all four — "one readout, every series" — instead of making the
  // reader chase the same moment card by card.
  property int hoverIndex: -1
  signal hoverIndexRequested(int index)

  // Shared plot geometry for the canvas and the crosshair overlay.
  readonly property int pad: 2
  // Shapeless phases paint one flat rule and never call plotY; only the
  // active phase needs a real axis.
  readonly property real plotFloor: {
    if (phase !== "active" || zeroAnchored) return 0
    return lo - (hi - lo) * 0.15                        // headroom below a truncated band
  }
  readonly property real plotSpan: {
    if (phase !== "active") return 1
    return zeroAnchored ? Math.max(hi * 1.08, 1) : (hi - lo) * 1.3
  }

  function plotX(i) {
    var n = series.length
    return pad + (n < 2 ? 0 : (canvas.width - 2 * pad) * i / (n - 1))
  }
  function plotY(v) {
    return canvas.height - pad - (canvas.height - 2 * pad) * (v - plotFloor) / plotSpan
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
      width: parent.width
      height: Style.font.heading

      Text {
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
          // The page states the hovered instant once; each card just answers
          // for its own metric.
          if (card.hoverIndex >= 0 && card.series[card.hoverIndex]) {
            var h = card.series[card.hoverIndex]
            return h.v === null ? "no sample" : card.format(h.v)
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
      height: parent.height - Style.font.heading - Style.font.caption - Style.spacing.xs * 2

      Canvas {
        id: canvas
        anchors.fill: parent
        visible: !card.loading

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var s = card.series
          var n = s.length
          if (card.lo === null) return
          var pad = card.pad

          // Recessive baseline — the one line the grid gets.
          ctx.strokeStyle = Util.alpha(card.foreground, 0.12)
          ctx.lineWidth = 1
          ctx.beginPath(); ctx.moveTo(pad, height - pad); ctx.lineTo(width - pad, height - pad); ctx.stroke()

          // No shape to show: one flat rule, quietly. Zero sits on the
          // baseline because that is where zero is; a steady non-zero value
          // sits mid-plot, where its height claims nothing.
          if (!card.hasShape) {
            var flatY = card.phase === "zero" ? height - pad : height / 2
            ctx.strokeStyle = Util.alpha(card.accent, 0.45)
            ctx.lineWidth = 2
            ctx.lineCap = "round"
            ctx.beginPath(); ctx.moveTo(pad, flatY); ctx.lineTo(width - pad, flatY); ctx.stroke()
            return
          }

          // Area, then line, broken at nulls so gaps read as gaps.
          function eachRun(cb) {
            var start = -1
            for (var i = 0; i <= n; i++) {
              var ok = i < n && s[i].v !== null
              if (ok && start === -1) start = i
              if (!ok && start !== -1) { cb(start, i - 1); start = -1 }
            }
          }

          // Area only when the axis is anchored at zero: otherwise the fill
          // would claim a magnitude the plot is not measuring.
          if (card.zeroAnchored) {
            ctx.fillStyle = Util.alpha(card.accent, 0.12)
            eachRun(function (a, b) {
              ctx.beginPath()
              ctx.moveTo(card.plotX(a), height - pad)
              for (var i = a; i <= b; i++) ctx.lineTo(card.plotX(i), card.plotY(s[i].v))
              ctx.lineTo(card.plotX(b), height - pad)
              ctx.closePath(); ctx.fill()
            })
          }

          ctx.strokeStyle = card.accent
          ctx.lineWidth = 2
          ctx.lineJoin = "round"
          eachRun(function (a, b) {
            ctx.beginPath()
            for (var i = a; i <= b; i++) {
              if (i === a) ctx.moveTo(card.plotX(i), card.plotY(s[i].v))
              else ctx.lineTo(card.plotX(i), card.plotY(s[i].v))
            }
            ctx.stroke()
          })

          // The endpoint dot marks "where it is now".
          for (var last = n - 1; last >= 0; last--) {
            if (s[last].v !== null) {
              ctx.fillStyle = card.accent
              ctx.beginPath(); ctx.arc(card.plotX(last), card.plotY(s[last].v), 3, 0, Math.PI * 2); ctx.fill()
              break
            }
          }
        }
      }

      // Crosshair as items: hover costs two bindings, zero repaints.
      Rectangle {
        visible: !card.loading && card.hoverIndex >= 0 && card.phase !== "collecting"
        x: card.plotX(card.hoverIndex)
        y: card.pad
        width: 1
        height: plot.height - card.pad * 2
        color: Util.alpha(card.foreground, 0.35)
      }

      Rectangle {
        visible: !card.loading && card.hoverIndex >= 0 && card.hasShape && card.series[card.hoverIndex]
          && card.series[card.hoverIndex].v !== null
        x: card.plotX(card.hoverIndex) - 3
        y: visible ? card.plotY(card.series[card.hoverIndex].v) - 3 : 0
        width: 6; height: 6; radius: 3
        color: card.accent
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

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        enabled: !card.loading && card.series.length > 1
        onPositionChanged: function (mouse) {
          var n = card.series.length
          var i = Math.round((mouse.x - card.pad) / (canvas.width - 2 * card.pad) * (n - 1))
          card.hoverIndexRequested(Util.clamp(i, 0, n - 1))
        }
        onExited: card.hoverIndexRequested(-1)
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
  onSeriesChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()
  Component.onCompleted: canvas.requestPaint()
}
