#!/bin/bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runner=$(command -v qmltestrunner || true)
[[ -n $runner ]] || runner=/usr/lib/qt6/bin/qmltestrunner
if [[ ! -x $runner ]]; then
  echo "skip Qt confirmation runtime test: qmltestrunner unavailable"
  exit 0
fi
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/qs/Commons" "$scratch/qs/Ui"
cp "$root/ConfirmationDialog.qml" "$root/test/qml/tst_confirmation.qml" "$scratch/"
cat > "$scratch/qs/Commons/qmldir" <<'QML'
module qs.Commons
singleton Style 1.0 Style.qml
singleton Color 1.0 Color.qml
singleton Util 1.0 Util.qml
singleton Border 1.0 Border.qml
QML
cat > "$scratch/qs/Commons/Style.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  property var spacing: ({lg:12,md:8,xs:4})
  property var font: ({family:"monospace",heading:16,body:14,bodySmall:12,caption:10})
  property int cornerRadius: 0
  function space(n) { return n }
}
QML
cat > "$scratch/qs/Commons/Color.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject { property color accent: "orange"; property color urgent: "red"; property var popups: ({background:"#102030",text:"white"}) }
QML
cat > "$scratch/qs/Commons/Util.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject { function alpha(c,a) { return Qt.rgba(c.r,c.g,c.b,a) } }
QML
cat > "$scratch/qs/Commons/Border.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject { function controlSpec(a,b,c) { return ({}) } }
QML
cat > "$scratch/qs/Ui/qmldir" <<'QML'
module qs.Ui
BorderSurface 1.0 BorderSurface.qml
Button 1.0 Button.qml
QML
cat > "$scratch/qs/Ui/BorderSurface.qml" <<'QML'
import QtQuick
Rectangle { property var borderSpec }
QML
cat > "$scratch/qs/Ui/Button.qml" <<'QML'
import QtQuick
Rectangle {
  id: button
  property string text: ""
  property color foreground: "white"
  property string fontFamily: "monospace"
  property bool focusable: false
  property bool bordered: false
  implicitWidth: 88
  implicitHeight: 32
  signal clicked()
  activeFocusOnTab: focusable
  Keys.onReturnPressed: if (focusable) button.clicked()
  Keys.onEnterPressed: if (focusable) button.clicked()
  Keys.onSpacePressed: if (focusable) button.clicked()
  MouseArea { anchors.fill: parent; onClicked: button.clicked() }
}
QML
QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 "$runner" -input "$scratch" -import "$scratch"
