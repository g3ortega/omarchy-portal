import QtQuick
import qs.Commons

// Inline text link: underline on hover (or while active), pointer cursor, one
// click signal.
Text {
  id: link

  signal clicked()
  property bool active: false

  textFormat: Text.PlainText
  color: Util.alpha(Color.popups.text, 0.6)
  font.family: Style.font.family
  font.pixelSize: Style.font.caption
  font.underline: enabled && (hover.hovered || active)

  HoverHandler { id: hover }
  MouseArea {
    anchors.fill: parent
    cursorShape: link.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: link.clicked()
  }
}
