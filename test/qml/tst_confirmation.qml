import QtQuick
import QtTest

Item {
  width: 420
  height: 400

  TextInput { id: editor; text: "keep my name" }

  ConfirmationDialog {
    id: dialog
    anchors.fill: parent
    visible: false
    title: "Share publicly?"
    target: "My service"
    context: ":3000 · via Cloudflare"
    message: "Anyone with the link can reach this service."
    acceptText: "Share"
    onAccepted: { checks.accepted++; visible = false }
    onCanceled: { checks.canceled++; visible = false }
  }

  TestCase {
    id: checks
    name: "Confirmation"
    when: windowShown
    property int accepted: 0
    property int canceled: 0

    function init() {
      dialog.visible = false
      dialog.busy = false
      accepted = 0
      canceled = 0
      wait(0)
    }

    function openDialog() {
      editor.forceActiveFocus()
      dialog.rememberFocus()
      dialog.visible = true
      tryCompare(findChild(dialog, "confirmationCancel"), "activeFocus", true)
    }

    function test_cancelIsDefault() {
      openDialog()
      keyClick(Qt.Key_Return)
      compare(canceled, 1)
      compare(accepted, 0)
      tryCompare(editor, "activeFocus", true)
      compare(editor.text, "keep my name")
    }

    function test_tabStaysInside() {
      openDialog()
      keyClick(Qt.Key_Tab)
      compare(findChild(dialog, "confirmationAccept").activeFocus, true)
      keyClick(Qt.Key_Tab)
      compare(findChild(dialog, "confirmationCancel").activeFocus, true)
      keyClick(Qt.Key_Tab, Qt.ShiftModifier)
      compare(findChild(dialog, "confirmationAccept").activeFocus, true)
      keyClick(Qt.Key_Return)
      compare(accepted, 1)
      compare(canceled, 0)
    }

    function test_escapeCancels() {
      openDialog()
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Escape)
      compare(canceled, 1)
      compare(accepted, 0)
    }

    function test_busyCannotConfirm() {
      openDialog()
      keyClick(Qt.Key_Tab)
      dialog.busy = true
      tryCompare(findChild(dialog, "confirmationCancel"), "activeFocus", true)
      keyClick(Qt.Key_Tab)
      compare(findChild(dialog, "confirmationCancel").activeFocus, true)
      keyClick(Qt.Key_Y)
      compare(accepted, 0)
      compare(dialog.visible, true)
      keyClick(Qt.Key_Escape)
      compare(canceled, 1)
    }

    function test_scrimCancels() {
      openDialog()
      mouseClick(dialog, 1, 1)
      compare(canceled, 1)
      compare(accepted, 0)
    }

    function test_longContentStaysBounded() {
      var message = dialog.message
      dialog.message = "long consequence ".repeat(1000)
      dialog.target = "long name ".repeat(1000)
      openDialog()
      verify(dialog.minimumHeight < dialog.height)
      verify(findChild(dialog, "confirmationCancel").visible)
      keyClick(Qt.Key_Escape)
      dialog.message = message
    }
  }
}
