pragma ComponentBehavior: Bound

import QtQuick
import qs.Ui
import qs.Commons
import "lib/Icons.js" as Icons
import "lib/Colors.js" as Colors
import "lib/Format.js" as Format

// One listening port.
//
// A row's title is its best name: the local route when one exists
// (anycable.test), else the project or stack. What the process is DOING —
// connections, cpu, memory, uptime — lives in service.stats and shows while
// the row has attention, so identity stays put while numbers move.
//
// Layout: every element on the main line is a sibling positioned by anchors.
// Actions float over the right edge on a scrim instead of reserving width, so
// a resting row gives its full width to the name.
//
// Security: every string here except our own literals is untrusted — process
// names, command lines, tunnel URLs — so every Text sets Text.PlainText.
Item {
  id: row

  property var entry: null
  property var service: null
  property bool brandColors: true
  property bool selected: false
  // Which panel this row has open, if any: "" | actions | naming | sharing.
  property string expandedKind: ""
  // Non-empty while this row's pending action awaits an answer: the verb the
  // answer wears, what it names, and the consequence in a few words.
  property string confirmKind: ""
  property string confirmLabel: ""
  property string confirmClause: ""
  // The verb line, built by the panel (one model for mouse and keyboard) and
  // only rendered here. verbCursor is the keyboard's place in it.
  property var verbs: []
  property int verbCursor: -1
  readonly property bool confirming: confirmKind !== ""
  readonly property bool sharing: expandedKind === "sharing"
  readonly property bool naming: expandedKind === "naming"
  readonly property bool expanded: expandedKind !== "" || confirming
  readonly property var route: service && entry ? service.routeFor(entry.port) : null
  readonly property var publicTunnel: service && entry ? service.publicTunnelFor(entry.port) : null
  readonly property bool dnsPending: publicTunnel !== null && publicTunnel.dns === "pending"
  readonly property bool targetOffline: publicTunnel !== null && publicTunnel.targetHealthy === false
  readonly property string publicTunnelText: publicTunnel ? publicTunnel.url + (targetOffline ? " · target offline" : "") : ""
  // Index of the provider chip the panel's keyboard cursor is on while the
  // share picker is open on this row; -1 when the cursor is elsewhere.
  property int shareCursor: -1
  property string portlessTld: "localhost"
  property color foreground: Color.popups.text

  signal detailRequested()
  signal expandRequested(string kind)
  signal editorDone()
  signal editorCanceled()
  signal verbClicked(var verb)
  signal confirmAccepted()
  signal confirmCanceled()
  signal providerChosen(var provider)

  readonly property bool revealed: hover.hovered || selected || expanded

  // Every secondary line — the URL subrow, the verbs, the editors — starts
  // exactly where the main line's title does: one alignment axis, read off
  // the title column itself so nothing can drift from it.
  readonly property real titleAxis: titleColumn.x
  // The center of the icon slot: where the thread rule hangs from.
  readonly property real iconAxis: iconGlyph.x + iconGlyph.width / 2
  readonly property var stats: service && entry ? (service.stats[entry.port] || null) : null
  readonly property bool paused: stats ? stats.paused === true : false

  readonly property bool named: route !== null
  readonly property string routeHost: route ? route.host : ""
  readonly property string effectiveUrl: service && entry ? service.urlFor(entry.port, entry.url) : ""
  readonly property bool hasUrl: effectiveUrl !== ""

  implicitHeight: body.implicitHeight
  opacity: paused ? 0.7 : 1.0

  readonly property string stackLine: {
    if (!entry) return ""
    var bits = []
    if (named && entry.name && entry.name !== routeHost) bits.push(entry.name)
    if (entry.label && entry.label !== entry.name) bits.push(entry.label)
    if (entry.scope === "all") bits.push("all interfaces")
    else if (entry.scope === "lan") bits.push("LAN")
    if (entry.comm && entry.comm !== entry.name && entry.comm !== entry.label) bits.push(entry.comm)
    if (entry.port === 1337) bits.push("elite")
    return bits.join(" · ")
  }

  readonly property string statsLine: {
    if (!stats) return ""
    var bits = []
    if (paused) bits.push("paused")
    bits.push(stats.conns === 1 ? "1 conn" : stats.conns + " conns")
    if (stats.cpuPct != null) bits.push(stats.cpuPct + "% cpu")
    if (stats.rssKb != null) bits.push(Format.bytesKb(stats.rssKb))
    if (stats.upSec != null) bits.push(Format.uptimeLine(stats.upSec))
    return bits.join(" · ")
  }

  component PublicAction: Item {
    id: action

    required property string icon
    required property string text
    property color color: Util.alpha(Color.popups.text, 0.6)
    signal clicked()

    implicitWidth: actionGlyph.width + Style.spacing.xs + actionLabel.implicitWidth
    implicitHeight: Style.space(24)

    OpticalGlyph {
      id: actionGlyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(16)
      height: Style.space(16)
      text: action.icon
      fontSize: Style.font.caption
      color: action.color
    }

    Text {
      id: actionLabel
      anchors.left: actionGlyph.right
      anchors.leftMargin: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: action.text
      color: action.color
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.underline: action.enabled && actionHover.hovered
    }

    HoverHandler { id: actionHover }
    MouseArea {
      anchors.fill: parent
      cursorShape: action.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: action.clicked()
    }
  }

  Column {
    id: body
    width: parent.width
    spacing: 0

    // ---- main line ----------------------------------------------------------
    Item {
      id: mainLine
      width: parent.width
      height: Math.max(Style.spacing.popupRowHeight, Style.space(36))

      CursorSurface {
        anchors.fill: parent
        anchors.topMargin: Style.spacing.hairline
        anchors.bottomMargin: Style.spacing.hairline
        radius: Style.cornerRadius
        hasCursor: hover.hovered
        current: row.selected
        foreground: row.foreground
      }

      HoverHandler { id: hover }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.PointingHandCursor
        // A click unfolds the verbs; the URL stays behind the open icon.
        onClicked: row.expandRequested("actions")
      }

      OpticalGlyph {
        id: iconGlyph
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.iconLarge + Style.spacing.sm
        height: Style.font.iconLarge
        text: row.entry ? Icons.g(row.entry.icon) : ""
        fontSize: Style.font.icon
        color: Colors.iconColor(row.entry, row.brandColors, Color.popups.background, row.foreground)
      }

      Text {
        id: portText
        anchors.left: iconGlyph.right
        anchors.leftMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(46)
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: row.entry ? String(row.entry.port) : ""
        color: row.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Column {
        id: titleColumn
        anchors.left: portText.right
        anchors.leftMargin: Style.spacing.lg
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        TickerText {
          width: parent.width
          text: row.named ? row.routeHost : (row.entry ? row.entry.name : "")
          color: row.named ? Color.accent : row.foreground
          fontFamily: Style.font.family
          fontSize: Style.font.body
          hovered: hover.hovered
        }

        TickerText {
          width: parent.width
          visible: text.length > 0
          text: row.revealed && row.statsLine ? row.statsLine : row.stackLine
          color: row.paused ? Color.urgent : Util.alpha(row.foreground, 0.55)
          fontFamily: Style.font.family
          fontSize: Style.font.caption
          hovered: hover.hovered
        }
      }

      // ---- floating actions ------------------------------------------------
      Item {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: actions.width + Style.space(28)
        visible: opacity > 0
        opacity: row.revealed ? 1.0 : ((row.publicTunnel || row.paused) ? 0.9 : 0.0)
        Behavior on opacity { NumberAnimation { duration: 80 } }

        // Scrim so icons stay legible over long titles without reserving
        // permanent width from the label column.
        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.35; color: Color.popups.background }
            GradientStop { position: 1.0; color: Color.popups.background }
          }
        }

        Row {
          id: actions
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.xs
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs

          PanelActionButton {
            visible: row.hasUrl && !row.paused
            iconText: Icons.g("open")
            tooltipText: "Open " + row.effectiveUrl
            foreground: row.foreground
            onClicked: if (row.service) row.service.openUrl(row.effectiveUrl)
          }

          PanelActionButton {
            visible: row.hasUrl
            iconText: Icons.g("copy")
            tooltipText: "Copy " + row.effectiveUrl
            foreground: row.foreground
            onClicked: if (row.service) row.service.copyText(row.effectiveUrl)
          }

          PanelActionButton {
            visible: row.entry && row.entry.pid !== null
            iconText: Icons.g("metrics")
            tooltipText: "Charts"
            foreground: row.foreground
            onClicked: row.detailRequested()
          }
        }
      }
    }

    // ---- expansion ----------------------------------------------------------
    // Everything a row can unfold — the verb line, the name editor, the
    // exposure choices — is one block in one register: quiet text at one
    // indent, tied to its row by a thread rule where the icon column runs.
    Loader {
      width: parent.width
      active: row.expanded
      visible: active

      sourceComponent: Item {
        // The same breath above the content as below it: the block sits
        // centered between its row and the next, not glued to one of them.
        implicitHeight: expansion.implicitHeight + Style.spacing.md * 2

        Rectangle {
          x: row.iconAxis - width / 2
          width: 2
          height: parent.height
          radius: 1
          color: Util.alpha(Color.accent, 0.3)
        }

        Column {
          id: expansion
          anchors.left: parent.left
          anchors.leftMargin: row.titleAxis
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          // -- the confirmation -----------------------------------------------
          // In place of the verbs, in their register. The answers are
          // anchored to the right edge so they can never overflow off it —
          // a long name or clause must cost the clause (it elides), never
          // the cancel. Only the destructive word wears urgent.
          Item {
            width: parent.width
            visible: row.confirming
            implicitHeight: confirmAnswers.implicitHeight + Style.spacing.xs

            Text {
              id: confirmQuestion
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth,
                parent.width - confirmAnswers.width - Style.spacing.lg * 2)
              elide: Text.ElideMiddle
              textFormat: Text.PlainText
              text: row.confirmKind + " " + row.confirmLabel + "?"
              color: Util.alpha(row.foreground, 0.85)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.left: confirmQuestion.right
              anchors.leftMargin: Style.spacing.sm
              anchors.right: confirmAnswers.left
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              visible: width > Style.space(40)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              readonly property var clause: ({ pause: "resume brings it back", restart: "re-runs its own command line" })
              text: row.confirmClause || clause[row.confirmKind] || ""
              color: Util.alpha(row.foreground, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Row {
              id: confirmAnswers
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              LinkText {
                anchors.verticalCenter: parent.verticalCenter
                text: row.confirmKind
                color: Util.alpha(Color.urgent, 0.95)
                font.pixelSize: Style.font.bodySmall
                onClicked: row.confirmAccepted()
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "·"
                color: Util.alpha(row.foreground, 0.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              LinkText {
                anchors.verticalCenter: parent.verticalCenter
                text: "cancel"
                color: Util.alpha(row.foreground, 0.7)
                font.pixelSize: Style.font.bodySmall
                onClicked: row.confirmCanceled()
              }
            }
          }

          // -- the verbs ------------------------------------------------------
          Row {
            visible: !row.confirming
            spacing: Style.spacing.sm

            Repeater {
              model: row.verbs

              delegate: Row {
                id: verb
                required property var modelData
                required property int index
                spacing: Style.spacing.sm

                Text {
                  visible: verb.index > 0
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "·"
                  color: Util.alpha(row.foreground, 0.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                LinkText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: verb.modelData.label
                  // Underline is the cursor, wherever it comes from; accent
                  // marks the verb whose section is open below.
                  active: verb.modelData.on || verb.index === row.verbCursor
                  color: verb.modelData.on ? Color.accent
                    : verb.modelData.urgent ? Util.alpha(Color.urgent, 0.85)
                    : Util.alpha(row.foreground, 0.7)
                  font.pixelSize: Style.font.bodySmall
                  onClicked: row.verbClicked(verb.modelData)
                }
              }
            }
          }

          // -- the name editor ------------------------------------------------
          Item {
            width: parent.width
            visible: row.naming && !row.confirming
            implicitHeight: Style.spacing.controlHeight
            onVisibleChanged: if (visible) { nameField.forceActiveFocus(); nameField.selectAll() }

            TextField {
              id: nameField
              anchors.left: parent.left
              anchors.right: tldText.left
              anchors.rightMargin: Style.spacing.xs
              anchors.verticalCenter: parent.verticalCenter
              foreground: row.foreground
              text: row.named ? row.routeHost.split(".")[0]
                : (row.service && row.entry ? row.service.suggestedName(row.entry) : "")
              Keys.onEscapePressed: row.editorCanceled()
              // Enter on an empty field removes an existing name: the keyboard
              // route to what the remove link does.
              onAccepted: {
                var n = text.trim()
                if (row.service && row.entry) {
                  if (n.length > 0) row.service.expose(row.entry.port, "portless", n)
                  else if (row.named) row.service.unexpose(row.entry.port, "portless")
                }
                row.editorDone()
              }
            }

            Text {
              id: tldText
              anchors.right: removeLink.visible ? removeLink.left : parent.right
              anchors.rightMargin: removeLink.visible ? Style.spacing.lg : 0
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "." + row.portlessTld
              color: Util.alpha(row.foreground, 0.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            LinkText {
              id: removeLink
              visible: row.named
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "remove"
              onClicked: {
                if (row.service && row.entry) row.service.unexpose(row.entry.port, "portless")
                row.editorDone()
              }
            }
          }

          // -- the exposure choices -------------------------------------------
          // Same register as the verbs. The providers wear the urgent tint
          // because one click here reaches the internet — the color is the
          // warning, not a shouted label.
          Row {
            visible: row.sharing && !row.publicTunnel && !row.confirming
            spacing: Style.spacing.sm

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "publicly via"
              color: Util.alpha(row.foreground, 0.45)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: row.service ? row.service.publicProviders : []

              delegate: Row {
                id: choice
                required property var modelData
                required property int index
                readonly property bool ready: choice.modelData.status === "ready"
                readonly property bool actionable: ready || choice.modelData.status === "setup"
                readonly property bool starting: row.service && row.entry
                  && row.service.busyAction === choice.modelData.id + ":" + row.entry.port
                readonly property bool installing: row.service
                  && row.service.busyAction === choice.modelData.id + ":setup"
                spacing: Style.spacing.sm

                Text {
                  visible: choice.index > 0
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "·"
                  color: Util.alpha(row.foreground, 0.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                LinkText {
                  anchors.verticalCenter: parent.verticalCenter
                  active: choice.index === row.shareCursor
                  text: {
                    if (choice.starting) return choice.modelData.label + " — starting…"
                    if (choice.installing) return choice.modelData.label + " — installing…"
                    if (choice.modelData.status === "setup") return choice.modelData.label + " — fix"
                    return choice.modelData.label
                  }
                  color: choice.ready ? Util.alpha(Color.urgent, 0.9)
                    : choice.actionable ? Util.alpha(row.foreground, 0.7)
                    : Util.alpha(row.foreground, 0.35)
                  font.pixelSize: Style.font.bodySmall
                  onClicked: if (choice.actionable) row.providerChosen(choice.modelData)
                }
              }
            }
          }
        }
      }
    }
    Item {
      width: parent.width
      visible: row.publicTunnel !== null
      height: visible ? Style.space(44) : 0

      OpticalGlyph {
        id: shareGlyph
        anchors.left: parent.left
        anchors.leftMargin: row.titleAxis - width - Style.spacing.sm
        anchors.verticalCenter: publicUrl.verticalCenter
        width: Style.font.caption + Style.spacing.sm
        height: Style.font.caption
        text: Icons.g("broadcast")
        fontSize: Style.font.caption
        color: Color.urgent
      }

      Text {
        id: publicUrl
        anchors.left: parent.left
        anchors.leftMargin: row.titleAxis
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.md
        anchors.top: parent.top
        height: Style.space(20)
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: row.publicTunnelText
        color: Util.alpha(Color.urgent, row.dnsPending ? 0.5 : 1.0)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle

        MouseArea {
          anchors.fill: parent
          enabled: !row.dnsPending
          cursorShape: Qt.PointingHandCursor
          onClicked: if (row.service && row.publicTunnel) row.service.openUrl(row.publicTunnel.url)
        }
      }

      Row {
        anchors.left: parent.left
        anchors.leftMargin: row.titleAxis
        anchors.bottom: parent.bottom
        spacing: Style.spacing.lg

        PublicAction {
          icon: Icons.g("open")
          text: "Open"
          enabled: !row.dnsPending
          opacity: enabled ? 1 : 0.5
          onClicked: if (row.service && row.publicTunnel) row.service.openUrl(row.publicTunnel.url)
        }
        PublicAction {
          icon: Icons.g("copy")
          text: "Copy"
          onClicked: if (row.service && row.publicTunnel) row.service.copyText(row.publicTunnel.url)
        }
        PublicAction {
          readonly property bool stopping: !!(row.service && row.service.activeAction && row.publicTunnel
            && row.service.activeAction.shareStopKey === row.publicTunnel.provider + ":" + row.entry.port)
          icon: Icons.g("stop")
          text: stopping ? "Stopping…" : "Stop sharing"
          color: Color.urgent
          enabled: !!row.service && !row.service.activeAction
          opacity: enabled || stopping ? 1 : 0.5
          onClicked: if (row.service && row.publicTunnel) row.service.unexpose(row.entry.port, row.publicTunnel.provider)
        }
      }
    }
  }
}
