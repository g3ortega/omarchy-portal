import QtQuick
import QtTest

Item {
  width: 420
  height: 240

  QtObject {
    id: backend
    function copyText(text, quiet) { checks.copies++; checks.copiedText = text; checks.quiet = quiet }
  }

  NoticeCopyHarness { id: notice; anchors.fill: parent; service: backend }
  Window { id: otherWindow; width: 100; height: 100; visible: false }

  TestCase {
    id: checks
    name: "NoticeCopy"
    when: windowShown
    property int copies: 0
    property string copiedText: ""
    property bool quiet: false

    function init() {
      copies = 0
      copiedText = ""
      notice.opened = true
      notice.noticeError = true
      notice.noticeText = "Full error <literal>\\n".repeat(1000)
      notice.confirmation = null
      notice.mode = "list"
      notice.focusList()
    }

    function test_copiesEntireError() {
      keyClick(Qt.Key_C, Qt.ControlModifier)
      compare(copies, 1)
      compare(copiedText, notice.noticeText)
      compare(quiet, true)
    }

    function test_inactiveWindowCannotCopy() {
      otherWindow.show()
      otherWindow.requestActivate()
      tryCompare(otherWindow, "active", true)
      try {
        keyClick(Qt.Key_C, Qt.ControlModifier)
        compare(copies, 0)
      } finally {
        otherWindow.close()
        notice.Window.window.requestActivate()
        tryCompare(notice.Window.window, "active", true)
      }
    }

    function test_plainCIsNotErrorCopy() {
      keyClick(Qt.Key_C)
      compare(copies, 0)
    }

    function test_preservesEditorCopy() {
      var editor = findChild(notice, "noticeEditor")
      editor.text = "my selected alias"
      editor.forceActiveFocus()
      editor.selectAll()
      keyClick(Qt.Key_C, Qt.ControlModifier)
      compare(copies, 0)
      editor.text = ""
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(editor.text, "my selected alias")
    }

    function test_disabledOutsideNoticeContext_data() {
      return [{tag:"closed", key:"opened", value:false},
              {tag:"success", key:"noticeError", value:false},
              {tag:"no notice", key:"noticeText", value:""},
              {tag:"confirming", key:"confirmation", value:({})},
              {tag:"naming", key:"mode", value:"naming"}]
    }

    function test_disabledOutsideNoticeContext(data) {
      notice[data.key] = data.value
      keyClick(Qt.Key_C, Qt.ControlModifier)
      compare(copies, 0)
    }
  }
}
