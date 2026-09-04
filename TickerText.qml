import QtQuick
import qs.Commons

// A Text that reads truncated content aloud on hover: at rest it elides
// exactly like the Text it replaces; hovered past its edge, the full string
// loops by at a constant vintage pace. Anything that fits never moves.
Item {
  id: ticker

  property string text: ""
  property color color: Color.popups.text
  property string fontFamily: Style.font.family
  property int fontSize: Style.font.body
  property bool hovered: false
  property real pace: 48 // px per second

  clip: true
  implicitWidth: copyA.contentWidth
  implicitHeight: rest.implicitHeight

  readonly property real gap: 48
  readonly property bool truncated: width > 0 && copyA.contentWidth > width
  readonly property bool sliding: hovered && truncated
  readonly property real loopWidth: copyA.contentWidth + gap

  Text {
    id: rest
    anchors.fill: parent
    visible: !slider.visible
    textFormat: Text.PlainText
    text: ticker.text
    color: ticker.color
    font.family: ticker.fontFamily
    font.pixelSize: ticker.fontSize
    elide: Text.ElideRight
  }

  // Two copies for a seamless wrap: when the first has slid exactly one loop
  // width left, the second sits where it started and the jump home is invisible.
  Item {
    id: slider
    anchors.fill: parent
    visible: ticker.sliding
    onVisibleChanged: if (!visible) track.x = 0

    Row {
      id: track
      height: parent.height
      spacing: ticker.gap

      Text {
        id: copyA
        height: slider.height
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: ticker.text
        color: ticker.color
        font.family: ticker.fontFamily
        font.pixelSize: ticker.fontSize
      }

      Text {
        height: slider.height
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: ticker.text
        color: ticker.color
        font.family: ticker.fontFamily
        font.pixelSize: ticker.fontSize
      }
    }

    NumberAnimation {
      target: track
      property: "x"
      from: 0
      to: -ticker.loopWidth
      duration: Math.round(ticker.loopWidth / ticker.pace * 1000)
      loops: Animation.Infinite
      running: ticker.sliding
    }
  }
}
