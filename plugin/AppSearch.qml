import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The dock's "+" search: type to find any installed app or folder, click (or
// Enter) to add it to the current mode's dock or take it out. Folders become
// stacks. Esc or a click outside closes it.
PanelWindow {
  id: search

  property var dock: null
  readonly property color accent: dock ? dock.accent : Commons.Color.accent
  readonly property string uiFont: dock ? dock.uiFont : "Adwaita Sans"
  property bool open: false
  property string query: ""
  property int selected: 0

  readonly property int rowHeight: Math.round(40 * Style.fontScale)
  readonly property int maxRows: 8

  visible: open
  color: "transparent"
  WlrLayershell.namespace: "omarchy-dock-search"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  // Covers the screen (transparent) so a click anywhere outside the card
  // closes it.
  anchors { top: true; bottom: true; left: true; right: true }

  onOpenChanged: {
    if (!open) return
    input.text = ""
    search.selected = 0
    input.forceActiveFocus()
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property var mode: dock ? dock.focusedMode : null

  // Typed a path ("~/Projects/", "/mnt/")? List the folders in it.
  readonly property string typedPath: {
    var q = search.query.trim()
    if (q.indexOf("~") === 0) q = search.home + q.slice(1)
    return q.indexOf("/") === 0 ? q : ""
  }
  readonly property string browseDir: typedPath ? typedPath.slice(0, typedPath.lastIndexOf("/") + 1) : search.home + "/"
  readonly property string browsePrefix: typedPath ? typedPath.slice(typedPath.lastIndexOf("/") + 1).toLowerCase() : search.query.trim().toLowerCase()

  FolderListModel {
    id: dirs
    folder: "file://" + search.browseDir
    showFiles: false
    showHidden: false
    showDotAndDotDot: false
  }

  // Best matches first: name starts with the query, then contains it, then a
  // match in the generic name or keywords. With no query, everything A to Z.
  // Matching folders follow the apps.
  readonly property var results: {
    var q = search.query.trim().toLowerCase()
    var scored = []
    if (!search.typedPath) {
      var values = DesktopEntries.applications.values
      for (var i = 0; i < values.length; i++) {
        var entry = values[i]
        if (entry.noDisplay) continue
        var name = String(entry.name || "").toLowerCase()
        var extra = (String(entry.genericName || "") + " " + (entry.keywords || []).join(" ")).toLowerCase()
        var score = !q ? 1 : name.indexOf(q) === 0 ? 4 : name.indexOf(q) > 0 ? 3 : extra.indexOf(q) >= 0 ? 2 : 0
        if (score > 0) scored.push({ type: "app", entry: entry, id: entry.id, name: entry.name, score: score, sort: name })
      }
      scored.sort(function(a, b) { return b.score - a.score || a.sort.localeCompare(b.sort) })
      scored = scored.slice(0, 60)
    }
    var folders = []
    var count = dirs.count
    for (var j = 0; j < count && (q || search.typedPath); j++) {
      var fname = String(dirs.get(j, "fileName"))
      if (search.browsePrefix && fname.toLowerCase().indexOf(search.browsePrefix) !== 0) continue
      folders.push({ type: "folder", path: String(dirs.get(j, "filePath")), name: fname })
    }
    return scored.concat(folders.slice(0, 20))
  }

  function isAdded(r) {
    if (!r || !search.dock) return false
    return r.type === "folder" ? search.dock.hasStack(r.path) : search.dock.isPinned(r.id)
  }

  onResultsChanged: search.selected = 0

  function toggle(r) {
    if (!r || !search.dock) return
    if (r.type === "folder") {
      if (search.dock.hasStack(r.path)) search.dock.removeStack(r.path)
      else search.dock.addStack(r.path)
      return
    }
    search.dock.setPinned(r.id, !search.dock.isPinned(r.id))
  }

  HyprlandFocusGrab {
    active: search.open
    windows: [search]
    onCleared: search.open = false
  }

  MouseArea {
    anchors.fill: parent
    onClicked: search.open = false
  }

  Glass {
    id: card

    width: Math.round(440 * Style.fontScale)
    x: Math.round((search.width - width) / 2)
    y: search.height - height - (search.dock ? search.dock.dockReach : 0) - Math.round(12 * Style.fontScale)
    height: column.implicitHeight + padding * 2
    radius: Math.round(22 * Style.fontScale)
    color: search.dock ? search.dock.popupFill : Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g, Commons.Color.popups.background.b, 0.74)
    padding: Style.spacing.lg

    // Clicks on the card stay on the card.
    MouseArea { anchors.fill: parent }

    // Close
    Rectangle {
      id: closeButton
      z: 2
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.spacing.md
      width: Math.round(26 * Style.fontScale)
      height: width
      radius: width / 2
      color: closeMouse.containsMouse ? search.accent : Qt.rgba(1, 1, 1, 0.08)

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "×"
        color: Commons.Color.popups.text
        font.pixelSize: Style.font.title
      }

      MouseArea {
        id: closeMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: search.open = false
      }
    }

    Column {
      id: column
      x: card.contentLeftInset
      y: card.contentTopInset
      width: card.width - card.contentLeftInset - card.contentRightInset
      spacing: Style.spacing.md

      Text {
        height: Math.round(26 * Style.fontScale)
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: search.mode ? "Add to " + search.mode.name : "Add to the dock"
        color: search.accent
        font.family: search.uiFont
        font.pixelSize: Style.font.title
        font.bold: true
      }

      // Search field
      Rectangle {
        width: parent.width
        height: Math.round(38 * Style.fontScale)
        radius: Style.cornerRadius
        color: Qt.rgba(1, 1, 1, 0.06)
        border.width: 1
        border.color: input.activeFocus ? search.accent : Qt.rgba(1, 1, 1, 0.12)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          x: Style.spacing.lg
          textFormat: Text.PlainText
          text: search.mode ? "Add an app or folder to " + search.mode.name + "…" : "Add an app or folder…"
          visible: input.text.length === 0
          color: Commons.Color.muted
          font.family: search.uiFont
          font.pixelSize: Style.font.title
        }

        TextInput {
          id: input
          anchors.verticalCenter: parent.verticalCenter
          x: Style.spacing.lg
          width: parent.width - Style.spacing.lg * 2
          color: Commons.Color.popups.text
          selectionColor: search.accent
          font.family: search.uiFont
          font.pixelSize: Style.font.title
          clip: true
          onTextChanged: search.query = text

          Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
              search.open = false
            } else if (event.key === Qt.Key_Down) {
              search.selected = Math.min(search.results.length - 1, search.selected + 1)
              list.positionViewAtIndex(search.selected, ListView.Contain)
            } else if (event.key === Qt.Key_Up) {
              search.selected = Math.max(0, search.selected - 1)
              list.positionViewAtIndex(search.selected, ListView.Contain)
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              search.toggle(search.results[search.selected])
            } else {
              return
            }
            event.accepted = true
          }
        }
      }

      ListView {
        id: list
        width: parent.width
        height: Math.min(search.results.length, search.maxRows) * search.rowHeight
        clip: true
        model: search.results
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: row
          required property var modelData
          required property int index
          readonly property bool pinned: search.isAdded(modelData)

          width: list.width
          height: search.rowHeight
          radius: Style.cornerRadius
          color: index === search.selected ? Qt.rgba(search.accent.r, search.accent.g, search.accent.b, 0.22)
            : rowMouse.containsMouse ? Style.hoverFill : "transparent"

          Image {
            id: icon
            anchors.verticalCenter: parent.verticalCenter
            x: Style.spacing.md
            width: Math.round(search.rowHeight * 0.7)
            height: width
            sourceSize: Qt.size(width * 2, height * 2)
            source: row.modelData.type === "folder" ? Quickshell.iconPath("folder", true)
              : search.dock ? search.dock.iconFor({ key: row.modelData.id }) : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            mipmap: true
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: icon.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: badge.left
            anchors.rightMargin: Style.spacing.md
            textFormat: Text.PlainText
            text: row.modelData.type === "folder" && search.dock ? search.dock.tildePath(row.modelData.path) : row.modelData.name
            elide: Text.ElideMiddle
            color: Commons.Color.popups.text
            font.family: search.uiFont
            font.pixelSize: Style.font.title
          }

          Text {
            id: badge
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.lg
            textFormat: Text.PlainText
            text: row.modelData.type === "folder" ? (row.pinned ? "Stack ✓" : "+ Stack") : (row.pinned ? "In dock ✓" : "+ Add")
            color: row.pinned ? search.accent : Commons.Color.muted
            font.family: search.uiFont
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: search.selected = row.index
            onClicked: search.toggle(row.modelData)
          }
        }
      }

      Text {
        visible: search.results.length === 0
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: "Nothing matches"
        color: Commons.Color.muted
        font.family: search.uiFont
        font.pixelSize: Style.font.body
      }
    }
  }

  component Glass: Rectangle {
    property int padding: 0
    readonly property int contentLeftInset: padding
    readonly property int contentRightInset: padding
    readonly property int contentTopInset: padding
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.1)
  }
}
