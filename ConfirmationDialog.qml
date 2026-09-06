pragma ComponentBehavior: Bound

import QtQuick
import qs.Ui
import qs.Commons

FocusScope {
  id: dialog

  property string title: ""
  property string target: ""
  property string context: ""
  property string message: ""
  property string acceptText: "Confirm"
  property bool urgent: false
  property bool busy: false
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  property Item previousFocus: null
  readonly property real minimumHeight: surface.implicitHeight + Style.spacing.lg * 2

  signal accepted()
  signal canceled()
  signal focusReleased()

  function rememberFocus() { previousFocus = dialog.Window.window ? dialog.Window.window.activeFocusItem : null }
  function focusCancel() { if (visible) cancelButton.forceActiveFocus(Qt.PopupFocusReason) }

  onVisibleChanged: {
    if (visible) Qt.callLater(focusCancel)
    else Qt.callLater(function () {
      if (dialog.visible) return
      if (dialog.previousFocus && dialog.previousFocus.visible && dialog.previousFocus.enabled)
        dialog.previousFocus.forceActiveFocus(Qt.PopupFocusReason)
      else dialog.focusReleased()
      dialog.previousFocus = null
    })
  }

  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Escape || event.text === "n") {
      dialog.canceled()
      event.accepted = true
    } else if (event.text === "y") {
      if (!dialog.busy) dialog.accepted()
      event.accepted = true
    } else {
      event.accepted = true
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.popups.background, 0.88)
    MouseArea { anchors.fill: parent; onClicked: dialog.canceled() }
  }

  BorderSurface {
    id: surface
    anchors.centerIn: parent
    width: parent.width - Style.spacing.lg * 2
    implicitHeight: body.implicitHeight + Style.spacing.lg * 2
    color: Color.popups.background
    borderSpec: Border.controlSpec("normal", dialog.foreground, dialog.urgent ? Color.urgent : Color.accent)
    radius: Style.cornerRadius

    MouseArea { anchors.fill: parent }

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.spacing.lg
      spacing: Style.spacing.md

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: dialog.title
        color: dialog.urgent ? Color.urgent : Color.accent
        font.family: dialog.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: dialog.target
        elide: Text.ElideRight
        color: dialog.foreground
        font.family: dialog.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: dialog.context
        color: Util.alpha(dialog.foreground, 0.65)
        font.family: dialog.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Flickable {
        width: parent.width
        height: Math.min(messageLabel.implicitHeight, Style.space(100))
        contentHeight: messageLabel.implicitHeight
        clip: true
        interactive: contentHeight > height

        Text {
          id: messageLabel
          width: parent.width
          textFormat: Text.PlainText
          text: dialog.message
          color: Util.alpha(dialog.foreground, 0.8)
          font.family: dialog.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }
      }

      Row {
        anchors.right: parent.right
        spacing: Style.spacing.md

        Button {
          id: cancelButton
          objectName: "confirmationCancel"
          text: "Cancel"
          foreground: dialog.foreground
          fontFamily: dialog.fontFamily
          focusable: true
          bordered: true
          onClicked: dialog.canceled()
          Keys.onTabPressed: if (!dialog.busy) acceptButton.forceActiveFocus(Qt.TabFocusReason)
          Keys.onBacktabPressed: if (!dialog.busy) acceptButton.forceActiveFocus(Qt.BacktabFocusReason)
        }

        Button {
          id: acceptButton
          objectName: "confirmationAccept"
          text: dialog.busy ? "Working…" : dialog.acceptText
          foreground: dialog.urgent ? Color.urgent : Color.accent
          fontFamily: dialog.fontFamily
          focusable: true
          bordered: true
          enabled: !dialog.busy
          onClicked: dialog.accepted()
          Keys.onTabPressed: cancelButton.forceActiveFocus(Qt.TabFocusReason)
          Keys.onBacktabPressed: cancelButton.forceActiveFocus(Qt.BacktabFocusReason)
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "tab choose · enter select · esc cancel"
        color: Util.alpha(dialog.foreground, 0.5)
        font.family: dialog.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  onBusyChanged: if (busy && visible) focusCancel()
  Component.onCompleted: if (visible) Qt.callLater(focusCancel)
}
