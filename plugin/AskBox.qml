import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// The Claude panel: a Claude Code chat that lives above the dock. It can
// change your dock, your Omarchy setup or your files, and asks before it
// runs commands (unless you give it full access).
PanelWindow {
  id: box

  property var dock: null
  property bool open: false
  property string prefill: ""
  property bool optionsOpen: false
  readonly property var settings: dock ? dock.settings : null
  readonly property var chat: dock ? dock.chat : null
  readonly property string uiFont: "Adwaita Sans"
  readonly property color ink: Commons.Color.popups.text
  readonly property color soft: Qt.rgba(ink.r, ink.g, ink.b, 0.55)
  readonly property color accent: Commons.Color.accent

  visible: open
  color: "transparent"
  WlrLayershell.namespace: "omarchy-dock-search"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }

  onOpenChanged: {
    if (!open) {
      optionsOpen = false
      return
    }
    input.text = box.prefill
    input.forceActiveFocus()
  }

  HyprlandFocusGrab {
    active: box.open
    windows: [box]
    onCleared: box.open = false
  }

  readonly property var suggestions: [
    "Add a Gaming mode to my dock",
    "Why is my laptop slow right now?",
    "Make my terminal font a bit bigger"
  ]
  readonly property var models: [["haiku", "Haiku"], ["sonnet", "Sonnet"], ["opus", "Opus"], ["fable", "Fable"]]
  readonly property var efforts: ["low", "medium", "high", "xhigh", "max"]

  function modelName(id) {
    for (var i = 0; i < models.length; i++) if (models[i][0] === id) return models[i][1]
    return id
  }

  readonly property var worstLimit: {
    var limits = dock && dock.usage && dock.usage.limits ? dock.usage.limits : []
    var worst = null
    for (var i = 0; i < limits.length; i++) if (!worst || Number(limits[i].percent) > Number(worst.percent)) worst = limits[i]
    return worst
  }

  function send() {
    if (!box.chat || box.chat.running) return
    var t = input.text
    input.text = ""
    box.chat.send(t)
  }

  MouseArea {
    anchors.fill: parent
    onClicked: box.open = false
  }

  Rectangle {
    id: card

    readonly property int pad: Math.round(18 * Style.fontScale)
    width: Math.round(560 * Style.fontScale)
    height: column.implicitHeight + pad * 2
    x: Math.round((box.width - width) / 2)
    y: box.height - height - Math.round(104 * Style.fontScale)
    radius: Math.round(22 * Style.fontScale)
    color: Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g, Commons.Color.popups.background.b, 0.74)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.1)

    Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    MouseArea { anchors.fill: parent }

    Column {
      id: column
      x: card.pad
      y: card.pad
      width: card.width - card.pad * 2
      spacing: Math.round(14 * Style.fontScale)

      // ── Header ──
      Item {
        width: parent.width
        height: Math.round(28 * Style.fontScale)

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Math.round(10 * Style.fontScale)

          Image {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(20 * Style.fontScale)
            height: width
            sourceSize: Qt.size(width * 2, height * 2)
            source: Qt.resolvedUrl("assets/claude.svg")
            RotationAnimation on rotation {
              running: !!box.chat && box.chat.running
              from: 0; to: 360; duration: 2400; loops: Animation.Infinite
              onRunningChanged: if (!running) parent.rotation = 0
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Claude"
            color: box.ink
            font.family: box.uiFont
            font.pixelSize: Math.round(15 * Style.fontScale)
            font.weight: Font.DemiBold
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: !!box.worstLimit
            textFormat: Text.PlainText
            text: box.worstLimit ? Math.round((1 - Number(box.worstLimit.percent)) * 100) + "% left · resets in " + box.dock.untilText(box.worstLimit.resetsAt) : ""
            color: box.worstLimit && Number(box.worstLimit.percent) >= 0.9 ? "#ff6b8a" : box.soft
            font.family: box.uiFont
            font.pixelSize: Math.round(12 * Style.fontScale)
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Math.round(6 * Style.fontScale)

          Pill {
            text: box.settings ? box.modelName(box.settings.chatModel) + " · " + box.settings.chatEffort : ""
            active: box.optionsOpen
            onClicked: box.optionsOpen = !box.optionsOpen
          }
          Pill {
            visible: !!box.chat && box.chat.messages.count > 0
            text: "New chat"
            onClicked: box.chat.reset()
          }
          RoundButton { glyph: "×"; onClicked: box.open = false }
        }
      }

      // ── Options: one model, effort, access ──
      Column {
        visible: box.optionsOpen
        width: parent.width
        spacing: Math.round(8 * Style.fontScale)

        Flow {
          width: parent.width
          spacing: Math.round(6 * Style.fontScale)
          Repeater {
            model: box.models
            delegate: Pill {
              required property var modelData
              text: modelData[1]
              active: !!box.settings && box.settings.chatModel === modelData[0]
              onClicked: box.settings.chatModel = modelData[0]
            }
          }
          Item { width: Math.round(10 * Style.fontScale); height: 1 }
          Repeater {
            model: box.efforts
            delegate: Pill {
              required property string modelData
              text: modelData
              active: !!box.settings && box.settings.chatEffort === modelData
              onClicked: box.settings.chatEffort = modelData
            }
          }
        }

        Pill {
          text: box.settings && box.settings.claudeAccess === "full" ? "Full access: runs commands without asking" : "Asks before running commands"
          active: !!box.settings && box.settings.claudeAccess === "full"
          onClicked: box.settings.claudeAccess = box.settings.claudeAccess === "full" ? "ask" : "full"
        }
      }

      // ── Empty state ──
      Column {
        visible: !box.chat || box.chat.messages.count === 0
        width: parent.width
        spacing: Math.round(10 * Style.fontScale)

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: "Ask anything. Claude can change your dock and modes, your Omarchy setup, or your files."
          color: box.soft
          font.family: box.uiFont
          font.pixelSize: Math.round(13 * Style.fontScale)
        }

        Flow {
          width: parent.width
          spacing: Math.round(6 * Style.fontScale)
          Repeater {
            model: box.suggestions
            delegate: Pill {
              required property string modelData
              text: modelData
              onClicked: box.chat.send(modelData)
            }
          }
        }
      }

      // ── Conversation ──
      ListView {
        id: log
        visible: !!box.chat && box.chat.messages.count > 0
        width: parent.width
        height: Math.min(contentHeight, Math.round(box.height * 0.5))
        clip: true
        spacing: Math.round(10 * Style.fontScale)
        model: box.chat ? box.chat.messages : null
        boundsBehavior: Flickable.StopAtBounds
        onCountChanged: Qt.callLater(function() { log.positionViewAtEnd() })
        onContentHeightChanged: if (atYEnd || box.chat.running) Qt.callLater(function() { log.positionViewAtEnd() })

        footer: Item {
          width: log.width
          height: box.chat && box.chat.running ? Math.round(26 * Style.fontScale) : 0
          visible: height > 0
          Row {
            anchors.bottom: parent.bottom
            spacing: 5
            Repeater {
              model: 3
              delegate: Rectangle {
                required property int index
                width: 6; height: 6; radius: 3
                color: box.accent
                SequentialAnimation on opacity {
                  loops: Animation.Infinite
                  running: true
                  PauseAnimation { duration: index * 160 }
                  NumberAnimation { to: 0.25; duration: 420 }
                  NumberAnimation { to: 1; duration: 420 }
                }
              }
            }
          }
        }

        delegate: Item {
          id: entry
          required property string kind
          required property string text
          required property int index
          width: log.width
          height: kind === "user" ? bubble.height
            : kind === "ask" ? askCard.height
            : body.implicitHeight

          // You
          Rectangle {
            id: bubble
            visible: entry.kind === "user"
            anchors.right: parent.right
            width: Math.min(log.width * 0.8, userText.implicitWidth + 28)
            height: visible ? userText.implicitHeight + 16 : 0
            radius: Math.round(14 * Style.fontScale)
            color: Qt.rgba(box.accent.r, box.accent.g, box.accent.b, 0.22)
            Text {
              id: userText
              x: 14; y: 8
              width: Math.min(log.width * 0.8 - 28, implicitWidth)
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: entry.text
              color: box.ink
              font.family: box.uiFont
              font.pixelSize: Math.round(13.5 * Style.fontScale)
            }
          }

          // Claude, a step it took, or an error
          Text {
            id: body
            visible: entry.kind === "claude" || entry.kind === "step" || entry.kind === "error"
            width: parent.width
            wrapMode: entry.kind === "step" ? Text.NoWrap : Text.Wrap
            elide: entry.kind === "step" ? Text.ElideRight : Text.ElideNone
            textFormat: entry.kind === "claude" ? Text.MarkdownText : Text.PlainText
            text: entry.kind === "step" ? "›  " + entry.text : entry.text
            color: entry.kind === "error" ? "#ff6b8a" : entry.kind === "step" ? box.soft : box.ink
            font.family: box.uiFont
            font.pixelSize: Math.round((entry.kind === "step" ? 12 : 13.5) * Style.fontScale)
            lineHeight: entry.kind === "claude" ? 1.15 : 1
            onLinkActivated: link => Qt.openUrlExternally(link)
          }

          // "Allow?"
          Rectangle {
            id: askCard
            visible: entry.kind === "ask"
            width: parent.width
            height: visible ? askColumn.implicitHeight + 24 : 0
            radius: Math.round(14 * Style.fontScale)
            color: Qt.rgba(1, 1, 1, 0.05)
            border.width: 1
            border.color: Qt.rgba(box.accent.r, box.accent.g, box.accent.b, 0.45)

            Column {
              id: askColumn
              x: 12; y: 12
              width: parent.width - 24
              spacing: 8
              Text {
                text: "Claude wants to"
                color: box.soft
                font.family: box.uiFont
                font.pixelSize: Math.round(12 * Style.fontScale)
              }
              Text {
                width: parent.width
                wrapMode: Text.WrapAnywhere
                textFormat: Text.PlainText
                text: entry.text
                color: box.ink
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: Math.round(12 * Style.fontScale)
              }
              Row {
                visible: entry.index === log.count - 1 && !!box.chat && box.chat.pendingAsk.length > 0
                spacing: 6
                Pill { text: "Allow"; active: true; onClicked: box.chat.allow() }
                Pill { text: "Don't allow"; onClicked: box.chat.deny() }
              }
            }
          }
        }
      }

      // ── Input ──
      Rectangle {
        width: parent.width
        height: Math.round(42 * Style.fontScale)
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.06)
        border.width: 1
        border.color: input.activeFocus ? Qt.rgba(box.accent.r, box.accent.g, box.accent.b, 0.6) : Qt.rgba(1, 1, 1, 0.1)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          x: Math.round(18 * Style.fontScale)
          visible: input.text.length === 0
          text: box.chat && box.chat.messages.count > 0 ? "Reply…" : "Ask Claude…"
          color: box.soft
          font.family: box.uiFont
          font.pixelSize: Math.round(14 * Style.fontScale)
        }

        TextInput {
          id: input
          anchors.verticalCenter: parent.verticalCenter
          x: Math.round(18 * Style.fontScale)
          width: parent.width - x - sendButton.width - Math.round(14 * Style.fontScale)
          color: box.ink
          selectionColor: box.accent
          font.family: box.uiFont
          font.pixelSize: Math.round(14 * Style.fontScale)
          clip: true
          Keys.onEscapePressed: box.open = false
          Keys.onReturnPressed: box.send()
          Keys.onEnterPressed: box.send()
        }

        RoundButton {
          id: sendButton
          anchors.right: parent.right
          anchors.rightMargin: Math.round(6 * Style.fontScale)
          anchors.verticalCenter: parent.verticalCenter
          filled: true
          glyph: box.chat && box.chat.running ? "■" : "↑"
          onClicked: box.chat && box.chat.running ? box.chat.stop() : box.send()
        }
      }
    }
  }

  component Pill: Rectangle {
    id: pill
    property string text: ""
    property bool active: false
    signal clicked()
    width: pillText.implicitWidth + Math.round(22 * Style.fontScale)
    height: Math.round(26 * Style.fontScale)
    radius: height / 2
    color: pill.active ? Qt.rgba(box.accent.r, box.accent.g, box.accent.b, 0.85) : (pillMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05))
    Behavior on color { ColorAnimation { duration: 140 } }

    Text {
      id: pillText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: pill.text
      color: pill.active ? "white" : box.ink
      opacity: pill.active ? 1 : 0.8
      font.family: box.uiFont
      font.pixelSize: Math.round(12 * Style.fontScale)
      font.weight: pill.active ? Font.DemiBold : Font.Normal
    }

    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.clicked()
    }
  }

  component RoundButton: Rectangle {
    id: rb
    property string glyph: ""
    property bool filled: false
    signal clicked()
    width: Math.round(30 * Style.fontScale)
    height: width
    radius: width / 2
    color: rb.filled ? (rbMouse.containsMouse ? Qt.lighter(box.accent, 1.12) : box.accent) : (rbMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.05))

    Text {
      anchors.centerIn: parent
      text: rb.glyph
      color: rb.filled ? "white" : box.ink
      font.family: box.uiFont
      font.pixelSize: Math.round(15 * Style.fontScale)
      font.weight: Font.DemiBold
    }

    MouseArea {
      id: rbMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: rb.clicked()
    }
  }
}
