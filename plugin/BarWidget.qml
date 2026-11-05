import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

// Petal in Omarchy's bar: the mode of the workspace this screen shows, in the
// mode's color, and how many notifications are held. A click opens the Petal
// menu; a right-click, the held notifications.
//
// The bar hands a plugin's widget its own service (Dock.qml) through
// bar.shell.serviceFor(); a replacement bar may not, and then the widget
// shows nothing.
BarWidget {
  id: root
  moduleName: "egesuren.petal"

  // The widget can be built before Petal's service is: look again until it's there.
  property var dock: null
  function findDock() {
    if (!root.dock && root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
      root.dock = root.bar.shell.serviceFor("egesuren.petal") || null
  }
  onBarChanged: findDock()
  Component.onCompleted: findDock()
  Timer {
    interval: 1000
    repeat: true
    running: !root.dock && !!root.bar
    onTriggered: root.findDock()
  }
  readonly property var screenMonitor: QsWindow.window && QsWindow.window.screen ? Hyprland.monitorFor(QsWindow.window.screen) : Hyprland.focusedMonitor
  readonly property int workspaceId: screenMonitor && screenMonitor.activeWorkspace ? screenMonitor.activeWorkspace.id : -1
  readonly property var mode: dock && dock.settings.modes ? dock.modeForWorkspace(workspaceId) : null
  readonly property int held: dock ? dock.heldTotal : 0
  readonly property color hue: mode && mode.color ? Qt.color(mode.color) : (bar ? bar.barForeground : "white")
  readonly property color ink: bar ? bar.barForeground : "white"

  visible: !!mode
  implicitWidth: visible ? (vertical ? barSize : row.implicitWidth + Style.space(14)) : 0
  implicitHeight: visible ? (vertical ? column.implicitHeight + Style.space(10) : barSize) : 0

  readonly property string tip: mode ? mode.name + (held > 0 ? " · " + held + " held" : "") : ""

  Row {
    id: row
    visible: !root.vertical
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.mode ? (root.mode.icon || "●") : ""
      color: root.hue
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.mode ? root.mode.name : ""
      color: root.ink
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
    }
    Text {
      visible: root.held > 0
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "· " + root.held
      color: root.hue
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
    }
  }

  Column {
    id: column
    visible: root.vertical
    anchors.centerIn: parent
    spacing: Style.space(2)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: root.mode ? (root.mode.icon || "●") : ""
      color: root.hue
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
    }
    Text {
      visible: root.held > 0
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: String(root.held)
      color: root.hue
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (!root.dock) return
      if (root.bar) root.bar.hideTooltip(root)
      root.dock.openPanel(mouse.button === Qt.RightButton ? "held" : "")
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tip)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}
