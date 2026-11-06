import QtQuick
import QtQuick.Shapes
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Services.Mpris
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DockModel.js" as DockModel

// One screen's Petal dock: mode pills, the mode's apps, "+",
// now playing, minimized windows, folder stacks and the trash. Every extra can be switched off in the settings menu
// (right-click "+" or the glass). Cards above it ask before you drift out of
// a focus mode.
PanelWindow {
  id: window
  Binding { target: window.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
  Binding { target: window.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

  property var dock: null
  readonly property var settings: dock ? dock.settings : null
  function opt(name) { return !!window.settings && window.settings[name] === true }

  readonly property string glyphFont: "JetBrainsMono Nerd Font"
  readonly property string uiFont: dock ? dock.uiFont : "Adwaita Sans"
  readonly property color accent: dock ? dock.accent : Commons.Color.accent
  function setting(name, fallback) {
    var v = window.settings ? window.settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }
  readonly property int popRadius: Math.round(16 * Style.fontScale)

  // ── Where we are ──────────────────────────────────────────────────────
  readonly property string position: dock ? dock.position : "bottom"
  readonly property bool vertical: dock ? dock.vertical : false
  readonly property var monitor: Hyprland.monitorFor(screen)
  readonly property var workspace: monitor ? monitor.activeWorkspace : null
  readonly property int workspaceId: workspace ? workspace.id : -1
  readonly property bool isFocusedScreen: Hyprland.focusedMonitor === window.monitor
  readonly property var mode: dock && opt("modes") ? dock.modeForWorkspace(workspaceId) : null
  readonly property string modeId: mode ? mode.id : (dock && dock.modes.length ? dock.modes[0].id : "")
  readonly property color modeTint: mode ? window.tint(mode.color) : window.accent

  function tint(c) {
    return c ? Qt.color(c) : window.accent
  }

  // ── This screen's apps ────────────────────────────────────────────────
  readonly property var items: dock ? dock.itemsFor(modeId, workspaceId) : []
  readonly property var itemsByKey: {
    var byKey = {}
    for (var i = 0; i < items.length; i++) byKey[items[i].key] = items[i]
    return byKey
  }
  function itemFor(key) { return window.itemsByKey[key] || null }

  // Slots the app stage keeps room for: the most apps any mode shows here,
  // plus "+".
  readonly property int stageSlots: {
    if (!dock) return 0
    var most = items.length
    var modes = opt("modes") ? dock.modes : []
    for (var i = 0; i < modes.length; i++) most = Math.max(most, dock.itemsFor(modes[i].id, workspaceId).length)
    return most + 1
  }

  // Slots follow this model so a slot survives windows opening and closing.
  ListModel { id: itemModel }
  onItemsChanged: syncItemModel()
  Component.onCompleted: syncItemModel()

  function syncItemModel() {
    var keys = window.items.map(function(item) { return item.key })
    for (var i = 0; i < keys.length; i++) {
      if (i < itemModel.count && itemModel.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < itemModel.count; j++) {
        if (itemModel.get(j).key === keys[i]) { found = j; break }
      }
      if (found >= 0) itemModel.move(found, i, 1)
      else itemModel.insert(i, { key: keys[i] })
    }
    if (itemModel.count > keys.length) itemModel.remove(keys.length, itemModel.count - keys.length)
  }

  // A drag puts an app in a new place, keeping it in this mode's dock.
  function moveItem(fromIndex, toIndex) {
    if (fromIndex === toIndex || !dock) return
    var keys = window.items.map(function(item) { return item.key })
    var moved = keys[fromIndex]
    keys.splice(fromIndex, 1)
    keys.splice(toIndex, 0, moved)
    var pinned = dock.modeApps(modeId)
    var pins = keys.filter(function(k) { return k === moved || pinned.indexOf(k) >= 0 })
    pinned.forEach(function(k) { if (pins.indexOf(k) < 0) pins.push(k) })
    dock.setModeApps(modeId, pins)
  }

  // ── Media ─────────────────────────────────────────────────────────────
  readonly property var player: {
    var players = Mpris.players.values
    var best = null
    for (var i = 0; i < players.length; i++) {
      if (players[i].isPlaying) return players[i]
      if (!best && players[i].trackTitle) best = players[i]
    }
    return best
  }

  // ── Visibility ────────────────────────────────────────────────────────
  readonly property int fullscreenMode: {
    var mode = 0
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      if (!toplevel.workspace || toplevel.workspace.id !== workspaceId) continue
      var ipc = toplevel.lastIpcObject
      mode = Math.max(mode, ipc && ipc.fullscreen ? ipc.fullscreen : 0)
    }
    return mode
  }
  readonly property bool shown: !!dock && fullscreenMode < 2
  // Auto-hide is exactly the setting. With it off, the dock keeps its own strip
  // of the screen (windows, maximized ones too, fit beside it).
  readonly property bool autohide: !!dock && dock.autohide
  property bool revealed: false
  readonly property bool menuOpen: menuItem !== null || settingsMenu || trashMenu || stackMenuPath !== "" || modeMenu !== null || mediaMenu
  readonly property bool stackOpen: stackPath !== ""
  readonly property bool previewOpen: previewCard.visible
  readonly property bool cardShown: guardCard.visible || toastCard.visible
  readonly property bool countdown: !!dock && !!dock.pending && dock.pending.ws === workspaceId
  readonly property bool popupOpen: menuOpen || stackOpen || previewOpen || cardShown || countdown || (!!dock && dock.searchOpen)
  readonly property bool tucked: autohide && !(revealed || popupOpen || dragging || dropHover)
  readonly property bool contentShown: shown && !tucked
  property bool dropHover: false

  // ── Sizes ─────────────────────────────────────────────────────────────
  readonly property int gap: setting("dockMargin", -1) >= 0 ? Math.round(setting("dockMargin", 0) * Style.fontScale) : Style.spacing.xs
  readonly property int pillPad: Style.spacing.xs
  readonly property int iconSize: Math.round(Math.max(16, setting("iconSize", 36)) * Style.fontScale)
  readonly property int iconInset: setting("iconPadding", -1) >= 0 ? Math.round(setting("iconPadding", 0) * Style.fontScale) : Style.spacing.md
  readonly property int slotSize: iconSize + iconInset * 2
  readonly property real idleOpacity: setting("idleOpacity", 0.7)
  readonly property int liftRoom: Math.round(iconSize * 0.3)
  readonly property int thumbWidth: Math.round(200 * Style.fontScale)
  readonly property int thumbHeight: Math.round(124 * Style.fontScale)
  readonly property int rowHeight: Style.spacing.popupRowHeight
  readonly property int popupRoom: Math.max(
    rowHeight * 15 + Style.spacing.sm * 2 + Style.normalBorderWidth * 2 + gap * 2,
    thumbHeight + rowHeight + Style.spacing.md * 3 + gap * 2)
  readonly property int popOrigin: position === "top" ? Item.Top
    : position === "left" ? Item.Left
    : position === "right" ? Item.Right
    : Item.Bottom
  // Toward the middle of the screen, for hover lift and bounce.
  readonly property real inwardX: position === "left" ? 1 : position === "right" ? -1 : 0
  readonly property real inwardY: position === "top" ? 1 : position === "bottom" ? -1 : 0

  readonly property color glassFill: dock ? dock.popupFill : Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g, Commons.Color.popups.background.b, 0.74)
  readonly property color ink: Commons.Color.popups.text
  readonly property color soft: Qt.rgba(ink.r, ink.g, ink.b, 0.55)

  // ── Drag state ────────────────────────────────────────────────────────
  property int dragIndex: -1
  property int dropIndex: -1
  property real dragOffset: 0
  readonly property bool dragging: dragIndex >= 0
  property bool animateShifts: true
  property bool hoverStale: false
  property point dropPoint

  // ── Popup state ───────────────────────────────────────────────────────
  property var menuItem: null
  property Item menuSlot: null
  property bool settingsMenu: false
  property bool trashMenu: false
  property bool mediaMenu: false
  property bool confirmEmpty: false
  property bool confirmDelete: false
  property var modeMenu: null
  property string stackMenuPath: ""
  property string stackPath: ""
  property Item stackSlot: null
  property string previewKey: ""
  property Item previewSlot: null
  property Item pendingPreviewSlot: null
  readonly property var previewItem: previewKey ? window.itemFor(previewKey) : null
  property Item hoverSlot: null

  onShownChanged: {
    if (shown) return
    closeMenu()
    closeStack()
    window.revealed = false
  }

  function resetMenus() {
    window.menuItem = null
    window.settingsMenu = false
    window.trashMenu = false
    window.mediaMenu = false
    window.confirmEmpty = false
    window.confirmDelete = false
    window.modeMenu = null
    window.stackMenuPath = ""
  }

  function beforePopup(slot) {
    window.resetMenus()
    window.closeStack()
    window.hidePreview()
    window.menuSlot = slot
  }

  function openMenu(item, slot) { beforePopup(slot); window.menuItem = item }
  function openSettingsMenu(slot) { beforePopup(slot); window.settingsMenu = true }
  function openTrashMenu(slot) { beforePopup(slot); window.trashMenu = true }
  function openMediaMenu(slot) { beforePopup(slot); window.mediaMenu = true }
  function openModeMenu(mode, slot) { beforePopup(slot); window.modeMenu = mode }
  function openStackMenu(path, slot) { beforePopup(slot); window.stackMenuPath = path }

  function closeMenu() {
    window.resetMenus()
    window.menuSlot = null
    if (window.autohide) hideTimer.restart()
  }

  function toggleStack(path, slot) {
    if (window.stackPath === path) {
      window.closeStack()
      return
    }
    window.closeMenu()
    window.hidePreview()
    window.stackPath = path
    window.stackSlot = slot
  }

  function closeStack() {
    window.stackPath = ""
    window.stackSlot = null
    if (window.autohide) hideTimer.restart()
  }

  function requestPreview(slot) {
    if (!opt("previews") || window.menuOpen || window.stackOpen || window.dragging) return
    // A hide queued by a brief leave (the dock sliding up under the pointer
    // fires leave/enter) must not cancel this request.
    previewHideTimer.stop()
    if (window.previewKey) {
      window.previewKey = slot.key
      window.previewSlot = slot
      return
    }
    window.pendingPreviewSlot = slot
    previewShowTimer.restart()
  }

  function releasePreview(slot) {
    if (window.pendingPreviewSlot === slot) window.pendingPreviewSlot = null
    previewHideTimer.restart()
  }

  function hidePreview() {
    previewShowTimer.stop()
    window.pendingPreviewSlot = null
    window.previewKey = ""
    window.previewSlot = null
  }

  Timer {
    id: previewShowTimer
    interval: 380
    onTriggered: {
      var slot = window.pendingPreviewSlot || (window.hoverSlot && window.hoverSlot.key !== undefined && window.hoverSlot.windowCount > 0 ? window.hoverSlot : null)
      if (!slot || !slot.hovered) return
      window.previewKey = slot.key
      window.previewSlot = slot
    }
  }

  Timer {
    id: previewHideTimer
    interval: 220
    onTriggered: {
      if (previewHover.hovered) return
      if (window.previewSlot && window.previewSlot.hovered) return
      if (window.pendingPreviewSlot && window.pendingPreviewSlot.hovered) return
      window.hidePreview()
      if (window.autohide) hideTimer.restart()
    }
  }

  function settleShifts() {
    window.animateShifts = false
    Qt.callLater(function() { window.animateShifts = true })
  }

  function endDrag() {
    window.settleShifts()
    window.hoverStale = true
    window.dragIndex = -1
    window.dropIndex = -1
    window.dragOffset = 0
  }

  // Places a popup inward of the dock, centered on a slot (or on the pill).
  function popupX(slot, popup) {
    if (window.position === "left") return body.x + body.width + window.gap
    if (window.position === "right") return body.x - window.gap - popup.width
    var center = slot ? slot.mapToItem(window.contentItem, slot.width / 2, 0).x : body.x + body.width / 2
    return Math.max(window.gap, Math.min(window.width - popup.width - window.gap, center - popup.width / 2))
  }

  function popupY(slot, popup) {
    if (window.position === "top") return body.y + body.height + window.gap
    if (window.position === "bottom") return body.y - window.gap - popup.height
    var center = slot ? slot.mapToItem(window.contentItem, 0, slot.height / 2).y : body.y + body.height / 2
    return Math.max(window.gap, Math.min(window.height - popup.height - window.gap, center - popup.height / 2))
  }

  function folderIcon(path) {
    var name = String(path).toLowerCase()
    var icon = name.indexOf("download") >= 0 ? "folder-download"
      : (name.indexOf("screenshot") >= 0 || name.indexOf("picture") >= 0) ? "folder-pictures"
      : name.indexOf("document") >= 0 ? "folder-documents"
      : name.indexOf("music") >= 0 ? "folder-music"
      : name.indexOf("video") >= 0 ? "folder-videos"
      : "folder"
    return Quickshell.iconPath(icon, "folder")
  }

  function baseName(path) {
    var parts = String(path).replace(/\/+$/, "").split("/")
    return parts[parts.length - 1] || path
  }

  function clock(seconds) {
    var s = Math.max(0, Math.round(seconds))
    return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }

  visible: !remapGuard.remapping
  color: "transparent"
  WlrLayershell.namespace: "omarchy-dock"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: !window.shown || window.autohide ? 0 : window.gap * 2 + window.slotSize + window.pillPad * 2

  anchors {
    top: window.position !== "bottom"
    bottom: window.position !== "top"
    left: window.position !== "right"
    right: window.position !== "left"
  }

  implicitWidth: window.vertical ? window.gap + window.slotSize + window.pillPad * 2 + window.popupRoom + window.thumbWidth : 0
  implicitHeight: window.vertical ? 0 : window.gap + window.slotSize + window.pillPad * 2 + window.popupRoom

  mask: Region {
    item: window.contentShown ? body : null

    Region { item: window.shown && window.autohide ? edgeTrigger : null }
    Region { item: menu.visible ? menu : null }
    Region { item: settingsCard.visible ? settingsCard : null }
    Region { item: stackCard.visible ? stackCard : null }
    Region { item: previewCard.visible ? previewCard : null }
    Region { item: guardCard.visible ? guardCard : null }
    Region { item: toastCard.visible ? toastCard : null }
  }

  onAutohideChanged: window.revealed = false
  // Once a popup (menu, "+" search, Claude box, card) goes away, hide again
  // unless the pointer is on the dock.
  onPopupOpenChanged: if (!popupOpen && autohide) hideTimer.restart()

  Timer {
    id: hideTimer
    interval: 150
    onTriggered: {
      if (!bodyHover.hovered && !edgeHover.hovered && !window.popupOpen && !window.dragging) window.revealed = false
    }
  }

  // The strip along the screen edge that brings an auto-hidden dock back,
  // for the pointer and for files dragged toward it.
  Item {
    id: edgeTrigger

    readonly property int depth: window.gap + Style.spacing.xxs

    x: window.position === "left" ? 0 : window.position === "right" ? window.width - depth : body.x
    y: window.position === "top" ? 0 : window.position === "bottom" ? window.height - depth : body.y
    width: window.vertical ? depth : body.width
    height: window.vertical ? body.height : depth

    HoverHandler {
      id: edgeHover
      onHoveredChanged: {
        if (hovered) window.revealed = true
        else hideTimer.restart()
      }
    }

    DropArea {
      anchors.fill: parent
      onEntered: window.revealed = true
    }
  }

  ScreenMoveRemap {
    id: remapGuard
    window: window
  }

  HyprlandFocusGrab {
    active: window.menuOpen || window.stackOpen
    windows: [window]
    onCleared: {
      window.closeMenu()
      window.closeStack()
    }
  }

  // ── The pill ──────────────────────────────────────────────────────────
  Item {
    id: body

    LayoutMirroring.enabled: false
    LayoutMirroring.childrenInherit: true

    width: slots.implicitWidth + window.pillPad * 2
    height: slots.implicitHeight + window.pillPad * 2
    property real tuck: window.tucked ? window.slotSize + window.pillPad * 2 + window.gap : 0

    Behavior on tuck {
      id: tuckMotion
      enabled: window.shown
      NumberAnimation {
        duration: Style.duration(tuckMotion.targetValue > 0 ? 120 : 180)
        easing.type: Easing.OutCubic
      }
    }

    Behavior on width { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
    Behavior on height { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }

    x: window.position === "left" ? window.gap - tuck
      : window.position === "right" ? window.width - width - window.gap + tuck
      : Math.round((window.width - width) / 2)
    y: window.position === "top" ? window.gap - tuck
      : window.position === "bottom" ? window.height - height - window.gap + tuck
      : Math.round((window.height - height) / 2)
    opacity: window.shown ? 1 : 0

    HoverHandler {
      id: bodyHover
      onHoveredChanged: if (!hovered && window.autohide) hideTimer.restart()
      onPointChanged: {
        var at = point.position
        if (!window.hoverStale || window.dragging) return
        if (Math.hypot(at.x - window.dropPoint.x, at.y - window.dropPoint.y) > Style.space(4)) window.hoverStale = false
      }
    }

    DropArea {
      anchors.fill: parent
      onEntered: window.dropHover = true
      onExited: { window.dropHover = false; if (window.autohide) hideTimer.restart() }
      onDropped: window.dropHover = false
    }

    // Right-click the glass between icons for the dock's settings.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.RightButton
      onClicked: window.openSettingsMenu(null)
    }

    // The dock's body: a translucent fill (blurred by a Hyprland layer rule),
    // a rim, a soft top sheen, and a faint wash of the mode's color. All of
    // it comes from the appearance settings.
    Rectangle {
      id: pill
      readonly property color base: window.setting("dockColor", "") ? Qt.color(window.setting("dockColor", "")) : Commons.Color.bar.background
      readonly property color rim: Qt.color(window.setting("dockBorderColor", "#ffffff"))
      anchors.fill: parent
      radius: window.setting("dockRadius", -1) >= 0 ? Math.min(Math.round(window.setting("dockRadius", 0) * Style.fontScale), Math.min(width, height) / 2) : Math.min(width, height) / 2.6
      color: Qt.rgba(base.r, base.g, base.b, window.setting("dockOpacity", 0.45))
      border.width: window.setting("dockBorderOpacity", 0.28) > 0 ? 1 : 0
      border.color: Qt.rgba(rim.r, rim.g, rim.b, window.setting("dockBorderOpacity", 0.28))

      Rectangle {
        visible: window.setting("dockSheen", true)
        anchors.fill: parent
        anchors.margins: 1
        radius: pill.radius - 1
        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.16) }
          GradientStop { position: 0.45; color: Qt.rgba(1, 1, 1, 0.03) }
          GradientStop { position: 1.0; color: Qt.rgba(window.modeTint.r, window.modeTint.g, window.modeTint.b, 0.16) }
        }
        Behavior on opacity { NumberAnimation { duration: 200 } }
      }
    }

    Grid {
      id: slots
      anchors.centerIn: parent
      columns: window.vertical ? 1 : 64
      verticalItemAlignment: Grid.AlignVCenter
      horizontalItemAlignment: Grid.AlignHCenter

      // Apps slide to their new places and new ones fade in, instead of the
      // dock jumping when the mode (and its apps) change.
      move: Transition {
        enabled: window.animateShifts
        NumberAnimation { properties: "x,y"; duration: Style.duration(220); easing.type: Easing.OutCubic }
      }
      add: Transition {
        enabled: window.animateShifts
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Style.duration(200) }
        NumberAnimation { property: "scale"; from: 0.7; to: 1; duration: Style.duration(220); easing.type: Easing.OutBack }
      }

      // Modes
      ModeSwitcher { visible: window.opt("modes") && !!window.dock && window.dock.modes.length > 0 }
      AskSlot { visible: !!window.dock && window.dock.providers.length > 0 && (window.opt("ai") || window.opt("claudeUsage")) }
      Separator { visible: window.opt("modes") }

      // Apps: a fixed-size stage as wide as the busiest mode needs, with the
      // apps centered on it, so the mode switch and the folders/trash never
      // move when you change modes; only the apps in the middle do.
      Item {
        id: appStage
        readonly property real length: Math.max(window.vertical ? appGrid.implicitHeight : appGrid.implicitWidth, window.stageSlots * window.slotSize)
        width: window.vertical ? window.slotSize : length
        height: window.vertical ? length : window.slotSize
        Behavior on width { enabled: window.vertical === false; NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }

        Grid {
          id: appGrid
          anchors.centerIn: parent
          columns: window.vertical ? 1 : 64

          move: Transition {
            enabled: window.animateShifts
            NumberAnimation { properties: "x,y"; duration: Style.duration(240); easing.type: Easing.OutCubic }
          }
          add: Transition {
            enabled: window.animateShifts
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Style.duration(200) }
            NumberAnimation { property: "scale"; from: 0.7; to: 1; duration: Style.duration(240); easing.type: Easing.OutBack }
          }

          Repeater {
            id: appRepeater
            model: itemModel
            delegate: AppSlot {}
          }
          AddSlot {}
        }
      }

      // Extras
      Separator {
        visible: (window.opt("nowPlaying") && !!window.player) || minimizedRepeater.count > 0
          || (window.opt("stacks") && stackRepeater.count > 0) || window.opt("trash")
      }
      MediaSlot { visible: window.opt("nowPlaying") && !!window.player }
      Repeater {
        id: minimizedRepeater
        model: window.dock && window.opt("minimized") ? window.dock.minimizedWindows : []
        delegate: MinimizedSlot {}
      }
      Repeater {
        id: stackRepeater
        model: window.dock && window.opt("stacks") ? window.dock.settings.stackFolders : []
        delegate: StackSlot {}
      }
      TrashSlot { visible: window.opt("trash") }
    }
  }

  // ── Slot building blocks ──────────────────────────────────────────────
  component Slot: Item {
    id: slot

    property bool hovered: mouse.containsMouse && !window.hoverStale && !window.dragging
    property alias mouse: mouse
    property string tip: ""
    // Hover lift: only the icon under the pointer rises a little.
    readonly property real lift: window.opt("hoverLift") && hovered ? 1 : 0
    property real liftShown: lift
    Behavior on liftShown { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
    readonly property real iconScale: 1 + window.setting("hoverLiftAmount", 0.05) * liftShown

    width: window.slotSize
    height: window.slotSize

    onHoveredChanged: {
      if (hovered) window.hoverSlot = slot
      else if (window.hoverSlot === slot) window.hoverSlot = null
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    }
  }

  component SlotIcon: Image {
    property Item slot: null
    property real extraX: 0
    property real extraY: 0
    x: window.iconInset + extraX + (slot ? window.inwardX * slot.liftShown * window.iconSize * window.setting("hoverLiftAmount", 0.05) * 1.2 : 0)
    y: window.iconInset + extraY + (slot ? window.inwardY * slot.liftShown * window.iconSize * window.setting("hoverLiftAmount", 0.05) * 1.2 : 0)
    width: window.iconSize
    height: window.iconSize
    sourceSize: Qt.size(window.iconSize * 2.4, window.iconSize * 2.4)
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
    mipmap: true
    scale: slot ? slot.iconScale : 1
    transformOrigin: window.popOrigin
  }

  component Separator: Item {
    width: window.vertical ? window.slotSize : Style.spacing.lg * 2 + 1
    height: window.vertical ? Style.spacing.lg * 2 + 1 : window.slotSize

    Rectangle {
      visible: window.setting("separators", true)
      anchors.centerIn: parent
      width: window.vertical ? parent.width * 0.6 : 1
      height: window.vertical ? 1 : parent.height * 0.6
      color: Qt.rgba(1, 1, 1, 0.22)
    }
  }

  component Badge: Rectangle {
    property int count: 0
    visible: count > 0
    width: Math.max(height, badgeText.implicitWidth + 8)
    height: Math.round(window.iconSize * 0.42)
    radius: height / 2
    color: "#ff3b7f"
    border.width: 1.5
    border.color: Qt.rgba(1, 1, 1, 0.85)
    z: 5

    Text {
      id: badgeText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.count > 99 ? "99+" : String(parent.count)
      color: "white"
      font.family: window.uiFont
      font.pixelSize: Math.round(parent.height * 0.62)
      font.bold: true
    }
  }

  // ── Modes ─────────────────────────────────────────────────────────────
  // A segmented switch: one fixed-size segment per mode and a highlight that
  // slides to the active one, so switching never reflows the dock.
  component ModeSwitcher: Item {
    id: sw

    readonly property var list: window.dock ? window.dock.modes : []
    readonly property int seg: Math.round(window.iconSize * 0.95)
    readonly property int pad: 3
    readonly property int activeIndex: {
      for (var i = 0; i < list.length; i++) if (list[i].id === window.modeId) return i
      return 0
    }
    readonly property int pendingIndex: {
      if (!window.countdown) return -1
      for (var i = 0; i < list.length; i++) if (list[i].id === window.dock.pending.mode) return i
      return -1
    }
    readonly property real fraction: window.countdown ? Math.max(0, Math.min(1, (window.dock.pending.deadline - window.dock.now) / window.dock.pending.total)) : 0
    readonly property color activeHue: list.length ? window.tint(list[activeIndex].color) : window.accent
    readonly property int trackLength: list.length * seg + pad * 2
    readonly property int trackDepth: seg + pad * 2

    width: window.vertical ? window.slotSize : trackLength + Style.spacing.sm * 2 + (stay.visible ? stay.width + Style.spacing.sm : 0)
    height: window.vertical ? trackLength + Style.spacing.sm * 2 : window.slotSize

    Rectangle {
      id: track
      x: window.vertical ? (parent.width - width) / 2 : Style.spacing.sm
      y: window.vertical ? Style.spacing.sm : (parent.height - height) / 2
      width: window.vertical ? sw.trackDepth : sw.trackLength
      height: window.vertical ? sw.trackLength : sw.trackDepth
      radius: Math.min(width, height) / 2
      color: Qt.rgba(1, 1, 1, 0.07)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.14)

      // The sliding highlight.
      Rectangle {
        x: window.vertical ? sw.pad : sw.pad + sw.activeIndex * sw.seg
        y: window.vertical ? sw.pad + sw.activeIndex * sw.seg : sw.pad
        width: sw.seg
        height: sw.seg
        radius: sw.seg / 2
        color: sw.activeHue
        border.width: 1
        border.color: Qt.lighter(sw.activeHue, 1.25)
        Behavior on x { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: Style.duration(240) } }
      }

      Repeater {
        model: sw.list

        delegate: Item {
          id: segment
          required property var modelData
          required property int index
          readonly property bool active: index === sw.activeIndex
          readonly property color hue: window.tint(modelData.color)
          readonly property int held: window.dock ? window.dock.heldCount(modelData.id) : 0
          property string tip: modelData.name + (held > 0 ? " · " + held + " held" : "")

          x: window.vertical ? sw.pad : sw.pad + index * sw.seg
          y: window.vertical ? sw.pad + index * sw.seg : sw.pad
          width: sw.seg
          height: sw.seg

          // Countdown ring around the mode being switched to.
          Shape {
            id: countRing
            visible: index === sw.pendingIndex
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              strokeColor: segment.hue
              strokeWidth: 2.5
              capStyle: ShapePath.RoundCap
              fillColor: "transparent"
              PathAngleArc { centerX: sw.seg / 2; centerY: sw.seg / 2; radiusX: sw.seg / 2 - 2; radiusY: sw.seg / 2 - 2; startAngle: -90; sweepAngle: 360 * sw.fraction }
            }
          }

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: segment.modelData.icon || "●"
            color: segment.active ? "white" : (segMouse.containsMouse ? Qt.lighter(segment.hue, 1.2) : segment.hue)
            font.family: window.glyphFont
            font.pixelSize: Math.round(sw.seg * 0.5)
            scale: segMouse.pressed ? 0.88 : 1
            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
            Behavior on scale { NumberAnimation { duration: 90 } }
          }

          Badge {
            count: segment.active ? 0 : segment.held
            x: parent.width - width * 0.7
            y: -height * 0.3
            color: segment.hue
          }

          MouseArea {
            id: segMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function(event) {
              if (event.button === Qt.RightButton) window.openModeMenu(segment.modelData, segment)
              else window.dock.requestMode(window.workspaceId, segment.modelData.id)
            }
            onContainsMouseChanged: {
              if (containsMouse) window.hoverSlot = segment
              else if (window.hoverSlot === segment) window.hoverSlot = null
            }
          }
        }
      }
    }

    // "Stay · 0:12" cancels a switch that is counting down (only with the
    // countdown setting on).
    Rectangle {
      id: stay
      visible: sw.pendingIndex >= 0 && !window.vertical
      anchors.verticalCenter: parent.verticalCenter
      x: track.x + track.width + Style.spacing.sm
      height: sw.seg
      width: stayText.implicitWidth + Style.spacing.lg * 2
      radius: height / 2
      color: stayMouse.containsMouse ? "white" : Qt.rgba(1, 1, 1, 0.9)

      Text {
        id: stayText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "Stay · " + window.clock(window.countdown ? (window.dock.pending.deadline - window.dock.now) / 1000 : 0)
        color: "#2a1426"
        font.family: window.uiFont
        font.pixelSize: Style.font.body
        font.bold: true
      }

      MouseArea {
        id: stayMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: window.dock.stay()
      }
    }
  }

  // The AI button (Claude or Codex): opens the chat panel. The ring shows how
  // much of that AI's tightest limit is used.
  component AskSlot: Item {
    id: askSlot
    readonly property int size: Math.round(window.iconSize * 0.95)
    readonly property real used: window.dock ? window.dock.usageWorst : -1
    readonly property color ringColor: used >= 0.9 ? "#ff4d6d" : used >= 0.7 ? "#ffb347" : window.accent
    property string tip: {
      // The ring shows what's used; the tooltip, what's left.
      var t = window.dock ? window.dock.chatName : "AI"
      var limits = window.dock && window.dock.usage && window.dock.usage.limits ? window.dock.usage.limits : []
      for (var i = 0; i < limits.length; i++)
        t += " · " + String(limits[i].title || limits[i].label).replace(" (7-day)", "") + " " + Math.round((1 - Number(limits[i].percent)) * 100) + "% left"
      return t
    }
    width: window.vertical ? window.slotSize : size + Style.spacing.sm * 2
    height: window.vertical ? size + Style.spacing.sm * 2 : window.slotSize

    Rectangle {
      id: askCircle
      anchors.centerIn: parent
      width: askSlot.size
      height: askSlot.size
      radius: width / 2
      color: askMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.07)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.14)

      Image {
        anchors.centerIn: parent
        width: Math.round(askSlot.size * 0.56)
        height: width
        sourceSize: Qt.size(width * 2, height * 2)
        source: window.dock ? window.dock.providerMark(window.dock.chatProvider) : Qt.resolvedUrl("assets/claude.svg")
        scale: askMouse.pressed ? 0.88 : (askMouse.containsMouse ? 1.08 : 1)
        Behavior on scale { NumberAnimation { duration: 120 } }
      }

      Shape {
        id: usageRing
        visible: window.opt("claudeUsage") && askSlot.used >= 0
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeColor: askSlot.ringColor
          strokeWidth: 2.5
          capStyle: ShapePath.RoundCap
          fillColor: "transparent"
          PathAngleArc { centerX: askSlot.size / 2; centerY: askSlot.size / 2; radiusX: askSlot.size / 2 - 1.5; radiusY: askSlot.size / 2 - 1.5; startAngle: -90; sweepAngle: 360 * Math.max(0.02, askSlot.used) }
        }
      }

      MouseArea {
        id: askMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: window.dock.openAsk("", window.vertical ? -1 : askSlot.mapToItem(null, askSlot.width / 2, 0).x)
        onContainsMouseChanged: {
          if (containsMouse) window.hoverSlot = askSlot
          else if (window.hoverSlot === askSlot) window.hoverSlot = null
        }
      }
    }
  }

  // ── Apps ──────────────────────────────────────────────────────────────
  component AddSlot: Slot {
    id: addSlot
    tip: window.mode ? "Add apps to " + window.mode.name : "Add apps"

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        window.openSettingsMenu(addSlot)
        return
      }
      window.closeMenu()
      window.closeStack()
      if (window.dock) window.dock.openSearch()
    }

    Item {
      x: window.iconInset
      y: window.iconInset
      width: window.iconSize
      height: window.iconSize
      scale: addSlot.iconScale
      transformOrigin: window.popOrigin

      Rectangle {
        anchors.fill: parent
        anchors.margins: Math.round(window.iconSize * 0.1)
        radius: width * 0.28
        color: Qt.rgba(1, 1, 1, addSlot.hovered ? 0.14 : 0.07)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.22)
      }
      Rectangle {
        anchors.centerIn: parent
        width: Math.round(window.iconSize * 0.42)
        height: Math.max(2, Math.round(window.iconSize * 0.08))
        radius: height / 2
        color: window.modeTint
      }
      Rectangle {
        anchors.centerIn: parent
        width: Math.max(2, Math.round(window.iconSize * 0.08))
        height: Math.round(window.iconSize * 0.42)
        radius: width / 2
        color: window.modeTint
      }
    }
  }

  component AppSlot: Slot {
    id: appSlot

    required property int index
    required property string key
    readonly property var modelData: window.itemFor(key)
    readonly property var entry: window.dock && modelData ? window.dock.entryFor(modelData) : null
    readonly property bool launching: !!window.dock && window.dock.isLaunching(key)
    readonly property bool lifted: window.dragIndex === index
    readonly property int windowCount: modelData ? modelData.windows.length : 0
    readonly property bool here: modelData ? modelData.here > 0 : false
    readonly property bool focusedApp: !!window.dock && window.dock.activeKey === key
    readonly property int badge: window.dock ? window.dock.badgeFor(key) : 0
    readonly property real progress: window.dock ? window.dock.progressFor(key) : -1
    readonly property string iconSource: window.dock && modelData ? window.dock.iconFor(modelData) : ""
    property point pressPoint
    property bool dragged: false
    property real pulse: 1
    property real hop: 0

    // App-colored glow: the icon's own color, sampled from a tiny copy of it
    // (theme icons come from an image provider the color quantizer can't read).
    property color sampled: "transparent"
    readonly property color appColor: window.opt("appGlow") && sampled.a > 0 ? sampled : window.accent

    Canvas {
      id: sampler
      width: 16
      height: 16
      opacity: 0
      enabled: false
      readonly property string src: window.opt("appGlow") ? appSlot.iconSource : ""
      onSrcChanged: if (src) loadImage(src)
      Component.onCompleted: if (src) loadImage(src)
      onImageLoaded: requestPaint()
      onPaint: {
        if (!src || !isImageLoaded(src)) return
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, 16, 16)
        ctx.drawImage(src, 0, 0, 16, 16)
        var d = ctx.getImageData(0, 0, 16, 16).data
        // Average the colorful, opaque pixels, weighted by saturation.
        var r = 0, g = 0, b = 0, w = 0, fr = 0, fg = 0, fb = 0, fw = 0
        for (var i = 0; i < d.length; i += 4) {
          var a = d[i + 3] / 255
          if (a < 0.5) continue
          var mx = Math.max(d[i], d[i + 1], d[i + 2]), mn = Math.min(d[i], d[i + 1], d[i + 2])
          var sat = mx > 0 ? (mx - mn) / mx : 0
          fr += d[i]; fg += d[i + 1]; fb += d[i + 2]; fw += 1
          var k = sat * sat * a
          r += d[i] * k; g += d[i + 1] * k; b += d[i + 2] * k; w += k
        }
        if (w < 3 && fw > 0) { r = fr; g = fg; b = fb; w = fw }
        if (w <= 0) return
        var c = Qt.rgba(r / w / 255, g / w / 255, b / w / 255, 1)
        appSlot.sampled = Qt.hsla(c.hslHue < 0 ? 0.92 : c.hslHue, c.hslHue < 0 ? 0.6 : Math.max(0.55, c.hslSaturation), Math.max(0.62, Math.min(0.78, c.hslLightness)), 1)
      }
    }

    tip: entry && entry.name ? entry.name : (modelData && modelData.windows.length > 0 ? String(modelData.windows[0].toplevel.title || key) : key)

    Connections {
      target: appSlot
      function onHoveredChanged() {
        if (appSlot.hovered && appSlot.windowCount > 0) window.requestPreview(appSlot)
        else window.releasePreview(appSlot)
      }
    }

    // Bounce once when the app wants attention.
    readonly property var bounceStamp: window.dock ? window.dock.bounces[key] : undefined
    onBounceStampChanged: if (bounceStamp && Date.now() - bounceStamp < 2000 && !Style.reduceMotion) bounceAnim.restart()

    SequentialAnimation {
      id: bounceAnim
      NumberAnimation { target: appSlot; property: "hop"; to: 1; duration: 220; easing.type: Easing.OutQuad }
      NumberAnimation { target: appSlot; property: "hop"; to: 0; duration: 420; easing.type: Easing.OutBounce }
    }

    readonly property real shift: !window.dragging ? 0
      : lifted ? window.dragOffset
      : (window.dragIndex < index && index <= window.dropIndex) ? -window.slotSize
      : (window.dropIndex <= index && index < window.dragIndex) ? window.slotSize
      : 0
    property real displayedShift: shift

    Behavior on displayedShift {
      enabled: window.animateShifts && window.dragging && !appSlot.lifted
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    z: lifted ? 1 : 0

    function bodyPoint(event) {
      return appSlot.mapToItem(body, event.x, event.y)
    }

    mouse.onPressed: function(event) {
      appSlot.dragged = false
      if (event.button === Qt.LeftButton) appSlot.pressPoint = appSlot.bodyPoint(event)
    }

    mouse.onPositionChanged: function(event) {
      if (!(appSlot.mouse.pressedButtons & Qt.LeftButton)) return
      var point = appSlot.bodyPoint(event)
      var delta = window.vertical ? point.y - appSlot.pressPoint.y : point.x - appSlot.pressPoint.x
      if (Math.hypot(point.x - appSlot.pressPoint.x, point.y - appSlot.pressPoint.y) > Style.space(4)) appSlot.dragged = true
      if (!window.dragging) {
        if (Math.abs(delta) < Style.space(6)) return
        window.closeMenu()
        window.hidePreview()
        window.dropIndex = appSlot.index
        window.dragIndex = appSlot.index
      }
      if (!appSlot.lifted) return
      window.dragOffset = delta
      window.dropIndex = DockModel.dropIndex(appSlot.index, delta, window.slotSize, appRepeater.count)
    }

    mouse.onReleased: function(event) {
      if (!appSlot.lifted) return
      window.dropPoint = appSlot.mapToItem(body, event.x, event.y)
      var from = window.dragIndex
      var to = window.dropIndex
      appSlot.dragged = true
      window.endDrag()
      window.moveItem(from, to)
    }

    mouse.onCanceled: if (appSlot.lifted) window.endDrag()

    mouse.onClicked: function(event) {
      if (appSlot.dragged) {
        appSlot.dragged = false
        return
      }
      if (event.button === Qt.RightButton) {
        window.openMenu(appSlot.modelData, appSlot)
        return
      }
      window.closeMenu()
      window.closeStack()
      window.hidePreview()
      if (event.button === Qt.MiddleButton) window.dock.launch(appSlot.modelData)
      else window.dock.activate(appSlot.modelData)
    }

    // Files dropped on an app open in it.
    DropArea {
      id: fileDrop
      anchors.fill: parent
      enabled: window.opt("dropToOpen") && !!appSlot.entry
      onEntered: function(drag) { window.dropHover = true; drag.accepted = drag.hasUrls }
      onExited: window.dropHover = false
      onDropped: function(drop) {
        window.dropHover = false
        if (drop.hasUrls) window.dock.launchWithFiles(appSlot.entry, drop.urls)
        drop.accept()
      }
    }

    Item {
      id: iconLayer
      anchors.fill: parent
      transform: Translate {
        x: (window.vertical ? 0 : appSlot.displayedShift) + window.inwardX * appSlot.hop * window.iconSize * 0.5
        y: (window.vertical ? appSlot.displayedShift : 0) + window.inwardY * appSlot.hop * window.iconSize * 0.5
      }

      // Soft glow in the app's color behind a running app's icon.
      Shape {
        visible: window.opt("appGlow") && appSlot.windowCount > 0
        anchors.centerIn: parent
        width: window.slotSize
        height: window.slotSize
        opacity: (appSlot.focusedApp ? 0.75 : (appSlot.hovered ? 0.55 : 0.32)) * Math.max(0, Math.min(1, window.setting("glowStrength", 1)))
        Behavior on opacity { NumberAnimation { duration: 200 } }
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeWidth: 0
          strokeColor: "transparent"
          fillGradient: RadialGradient {
            centerX: window.slotSize / 2; centerY: window.slotSize / 2
            focalX: centerX; focalY: centerY
            centerRadius: window.slotSize / 2
            GradientStop { position: 0.0; color: Qt.rgba(appSlot.appColor.r, appSlot.appColor.g, appSlot.appColor.b, 0.55) }
            GradientStop { position: 0.6; color: Qt.rgba(appSlot.appColor.r, appSlot.appColor.g, appSlot.appColor.b, 0.18) }
            GradientStop { position: 1.0; color: "transparent" }
          }
          PathRectangle { x: 0; y: 0; width: window.slotSize; height: window.slotSize }
        }
      }

      SlotIcon {
        id: appIcon
        slot: appSlot
        source: appSlot.iconSource
        opacity: (appSlot.launching ? appSlot.pulse : (appSlot.windowCount > 0 ? 1 : window.idleOpacity)) * (fileDrop.containsDrag ? 0.6 : 1)
        scale: appSlot.lifted || fileDrop.containsDrag ? 1.18 : appSlot.iconScale
      }

      // Progress ring (downloads, copies) around the icon.
      Shape {
        id: ring
        visible: appSlot.progress >= 0
        anchors.centerIn: appIcon
        width: window.iconSize + 8
        height: window.iconSize + 8
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeColor: Qt.rgba(1, 1, 1, 0.18)
          strokeWidth: 3
          fillColor: "transparent"
          PathAngleArc { centerX: ring.width / 2; centerY: ring.height / 2; radiusX: ring.width / 2 - 2; radiusY: ring.height / 2 - 2; startAngle: 0; sweepAngle: 360 }
        }
        ShapePath {
          strokeColor: appSlot.appColor
          strokeWidth: 3
          capStyle: ShapePath.RoundCap
          fillColor: "transparent"
          PathAngleArc { centerX: ring.width / 2; centerY: ring.height / 2; radiusX: ring.width / 2 - 2; radiusY: ring.height / 2 - 2; startAngle: -90; sweepAngle: 360 * Math.max(0.02, appSlot.progress) }
        }
      }

      Badge {
        count: appSlot.badge
        x: appIcon.x + appIcon.width - width * 0.62
        y: appIcon.y - height * 0.28
      }

      // Dot under an open app, stretched when it has several windows; dim
      // when its windows are all on other workspaces.
      Rectangle {
        readonly property int dotSize: Math.max(4, Math.round(window.iconSize * 0.13))
        visible: appSlot.windowCount > 0 && !appSlot.lifted
        width: appSlot.windowCount > 1 ? dotSize * 2.6 : dotSize
        height: dotSize
        radius: dotSize / 2
        color: appSlot.appColor
        opacity: appSlot.here || appSlot.focusedApp ? 1 : 0.4
        x: window.vertical ? (window.position === "left" ? 1 : parent.width - width - 1) : (parent.width - width) / 2
        y: window.vertical ? (parent.height - height) / 2 : (window.position === "top" ? 1 : parent.height - height - 1)
        Behavior on width { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }
      }
    }

    SequentialAnimation {
      running: appSlot.launching && !Style.reduceMotion
      loops: Animation.Infinite
      onRunningChanged: if (!running) appSlot.pulse = 1
      NumberAnimation { target: appSlot; property: "pulse"; from: 1; to: window.idleOpacity; duration: Style.duration(500); easing.type: Easing.InOutSine }
      NumberAnimation { target: appSlot; property: "pulse"; to: 1; duration: Style.duration(500); easing.type: Easing.InOutSine }
    }
  }

  // ── Now playing ───────────────────────────────────────────────────────
  component MediaSlot: Slot {
    id: mediaSlot
    readonly property var p: window.player
    tip: p ? (String(p.trackTitle || p.identity || "Media") + (p.trackArtist ? " — " + p.trackArtist : "")) : ""

    mouse.onClicked: function(event) {
      if (!mediaSlot.p) return
      if (event.button === Qt.RightButton) window.openMediaMenu(mediaSlot)
      else if (event.button === Qt.MiddleButton) { if (mediaSlot.p.canGoNext) mediaSlot.p.next() }
      else if (mediaSlot.p.canTogglePlaying) mediaSlot.p.togglePlaying()
    }

    ClippingRectangle {
      x: window.iconInset + window.inwardX * mediaSlot.liftShown * window.iconSize * window.setting("hoverLiftAmount", 0.05) * 1.2
      y: window.iconInset + window.inwardY * mediaSlot.liftShown * window.iconSize * window.setting("hoverLiftAmount", 0.05) * 1.2
      width: window.iconSize
      height: window.iconSize
      radius: Math.round(window.iconSize * 0.24)
      scale: mediaSlot.iconScale
      transformOrigin: window.popOrigin
      color: Qt.rgba(1, 1, 1, 0.08)

      Text {
        anchors.centerIn: parent
        visible: art.status !== Image.Ready
        textFormat: Text.PlainText
        text: "󰝚"
        color: window.accent
        font.family: window.glyphFont
        font.pixelSize: Math.round(window.iconSize * 0.5)
      }

      Image {
        id: art
        anchors.fill: parent
        source: mediaSlot.p ? String(mediaSlot.p.trackArtUrl || "") : ""
        sourceSize: Qt.size(window.iconSize * 2, window.iconSize * 2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
      }

      Rectangle {
        anchors.fill: parent
        visible: mediaSlot.hovered || (mediaSlot.p && !mediaSlot.p.isPlaying)
        color: Qt.rgba(0, 0, 0, 0.38)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: mediaSlot.p && mediaSlot.p.isPlaying ? "󰏤" : "󰐊"
          color: "white"
          font.family: window.glyphFont
          font.pixelSize: Math.round(window.iconSize * 0.46)
        }
      }
    }

    // Little equalizer under it while music plays.
    Row {
      visible: !!mediaSlot.p && mediaSlot.p.isPlaying
      anchors.horizontalCenter: parent.horizontalCenter
      y: window.position === "top" ? 1 : parent.height - height - 1
      height: Math.max(4, Math.round(window.iconSize * 0.16))
      spacing: 2
      Repeater {
        model: 3
        delegate: Rectangle {
          required property int index
          width: 2
          radius: 1
          anchors.bottom: parent.bottom
          color: window.accent
          height: parent.height * 0.4
          SequentialAnimation on height {
            running: !!mediaSlot.p && mediaSlot.p.isPlaying && !Style.reduceMotion
            loops: Animation.Infinite
            NumberAnimation { to: (index === 1 ? 1 : 0.7) * Math.max(4, Math.round(window.iconSize * 0.16)); duration: 260 + index * 90 }
            NumberAnimation { to: 2; duration: 260 + index * 70 }
          }
        }
      }
    }
  }

  // ── Minimized windows (Super+M) ───────────────────────────────────────
  component MinimizedSlot: Slot {
    id: minSlot
    required property var modelData
    tip: String(modelData.toplevel.title || modelData.key) + " (minimized)"

    mouse.onClicked: function(event) {
      if (event.button === Qt.MiddleButton) minSlot.modelData.toplevel.close()
      else window.dock.bringForward(minSlot.modelData)
    }

    ClippingRectangle {
      x: window.iconInset - 2 + window.inwardX * minSlot.liftShown * window.iconSize * window.setting("hoverLiftAmount", 0.05) * 1.2
      y: window.iconInset - 2 + window.inwardY * minSlot.liftShown * window.iconSize * window.setting("hoverLiftAmount", 0.05) * 1.2
      width: window.iconSize + 4
      height: window.iconSize + 4
      radius: Math.round(window.iconSize * 0.18)
      scale: minSlot.iconScale
      transformOrigin: window.popOrigin
      color: Qt.rgba(0, 0, 0, 0.3)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.25)

      ScreencopyView {
        anchors.centerIn: parent
        captureSource: minSlot.modelData.toplevel
        live: false
        constraintSize: Qt.size(window.iconSize + 4, window.iconSize + 4)
      }
    }

    Image {
      width: Math.round(window.iconSize * 0.5)
      height: width
      x: window.iconInset + window.iconSize - width * 0.7
      y: window.iconInset + window.iconSize - height * 0.7
      sourceSize: Qt.size(width * 2, height * 2)
      source: window.dock ? window.dock.iconFor({ key: minSlot.modelData.key }) : ""
      asynchronous: true
    }
  }

  // ── Folders and trash ─────────────────────────────────────────────────
  component StackSlot: Slot {
    id: stackSlot

    required property string modelData
    readonly property string path: window.dock ? window.dock.expandPath(modelData) : modelData

    tip: window.baseName(modelData)

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        window.openStackMenu(stackSlot.modelData, stackSlot)
        return
      }
      if (event.button === Qt.MiddleButton) {
        window.dock.openPath(stackSlot.modelData)
        return
      }
      window.toggleStack(stackSlot.path, stackSlot)
    }

    SlotIcon {
      slot: stackSlot
      source: window.folderIcon(stackSlot.modelData)
    }

    Rectangle {
      readonly property int dotSize: Math.max(4, Math.round(window.iconSize * 0.13))
      visible: window.stackPath === stackSlot.path
      width: dotSize; height: dotSize; radius: dotSize / 2
      color: window.accent
      x: (parent.width - width) / 2
      y: window.position === "top" ? 1 : parent.height - height - 1
    }
  }

  component TrashSlot: Slot {
    id: trashSlot

    readonly property bool full: trashModel.count > 0
    tip: full ? "Trash (" + trashModel.count + ")" : "Trash"

    FolderListModel {
      id: trashModel
      folder: "file://" + Quickshell.env("HOME") + "/.local/share/Trash/files"
      showHidden: true
      showDirs: true
      showDotAndDotDot: false
    }

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        window.openTrashMenu(trashSlot)
        return
      }
      window.closeMenu()
      window.closeStack()
      if (window.dock) window.dock.openTrash()
    }

    // Files dropped here go to the trash.
    DropArea {
      id: trashDrop
      anchors.fill: parent
      onEntered: function(drag) { window.dropHover = true; drag.accepted = drag.hasUrls }
      onExited: window.dropHover = false
      onDropped: function(drop) {
        window.dropHover = false
        if (drop.hasUrls) window.dock.trashUrls(drop.urls)
        drop.accept()
      }
    }

    SlotIcon {
      slot: trashSlot
      source: Quickshell.iconPath(trashSlot.full ? "user-trash-full" : "user-trash", "user-trash")
      scale: trashDrop.containsDrag ? 1.2 : trashSlot.iconScale
    }
  }

  // ── Tooltip ───────────────────────────────────────────────────────────
  Rectangle {
    id: tooltip

    readonly property Item slot: window.hoverSlot
    readonly property string text: slot && slot.tip !== undefined ? slot.tip : ""

    visible: window.opt("tooltips") && !!slot && text !== "" && window.contentShown && !window.menuOpen && !window.stackOpen
      && !previewCard.visible && !guardCard.visible && !window.dragging
    width: tipText.implicitWidth + Style.spacing.lg * 2
    height: tipText.implicitHeight + Style.spacing.sm * 2
    radius: height / 2
    color: window.glassFill
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.2)
    z: 10

    x: {
      if (!slot) return 0
      var c = slot.mapToItem(window.contentItem, slot.width / 2, slot.height / 2)
      if (window.position === "left") return body.x + body.width + window.liftRoom + window.gap
      if (window.position === "right") return body.x - window.liftRoom - window.gap - width
      return Math.max(window.gap, Math.min(window.width - width - window.gap, c.x - width / 2))
    }
    y: {
      if (!slot) return 0
      var c = slot.mapToItem(window.contentItem, slot.width / 2, slot.height / 2)
      if (window.position === "top") return body.y + body.height + window.liftRoom + window.gap
      if (window.position === "bottom") return body.y - window.liftRoom - window.gap - height
      return c.y - height / 2
    }

    Text {
      id: tipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tooltip.text
      color: Commons.Color.popups.text
      font.family: window.uiFont
      font.pixelSize: Style.font.body
    }
  }

  // ── Focus cards: "belongs to Social — stay focused, or switch?" ───────
  Glass {
    id: guardCard

    readonly property var c: window.dock ? window.dock.card : null
    readonly property var target: c && c.target && window.dock ? window.dock.modeById(c.target) : null
    readonly property var here: c && window.dock ? window.dock.modeById(c.mode || window.modeId) : null
    readonly property int wait: here && window.opt("countdown") ? Number(here.focusDelay || 0) : 0
    // Petal's own quiet cards: a suggestion, the weekly summary, "done".
    readonly property bool quiet: !!c && (c.kind === "suggest" || c.kind === "summary" || c.kind === "done")
    readonly property string range: c && c.kind === "summary" && c.data ? window.dock.shortDay(c.data.from) + " – " + window.dock.shortDay(c.data.to) : ""
    readonly property color hue: target ? window.tint(target.color) : window.accent

    visible: !!c && window.isFocusedScreen && window.shown
    width: Math.max(Math.round(330 * Style.fontScale), cardColumn.implicitWidth) + padding * 2
    height: cardColumn.implicitHeight + padding * 2
    x: window.popupX(null, guardCard)
    y: window.popupY(null, guardCard)
    radius: window.popRadius
    color: window.glassFill
    padding: Style.spacing.lg

    HoverHandler {
      onHoveredChanged: if (window.dock) window.dock.cardHovered = hovered
    }

    TileButton {
      z: 3
      y: Style.spacing.sm
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.sm
      width: Math.round(window.rowHeight * 0.7)
      glyph: "×"
      onClicked: window.dock.cardClose()
    }

    Column {
      id: cardColumn
      x: guardCard.contentLeftInset
      y: guardCard.contentTopInset
      width: guardCard.width - guardCard.contentLeftInset - guardCard.contentRightInset
      spacing: Style.spacing.sm

      Row {
        spacing: Style.spacing.md
        width: parent.width

        Image {
          width: Math.round(window.iconSize * 0.8)
          height: width
          sourceSize: Qt.size(width * 2, height * 2)
          source: guardCard.c ? (guardCard.c.kind === "held" ? (window.dock.iconFor({ key: guardCard.c.n.key || "" })) : (guardCard.c.icon || "")) : ""
          asynchronous: true
        }

        Column {
          width: parent.width - Math.round(window.iconSize * 0.8) - Style.spacing.md - Math.round(window.rowHeight * 0.6)
          spacing: 2

          Text {
            width: parent.width
            textFormat: Text.StyledText
            wrapMode: guardCard.quiet ? Text.Wrap : Text.NoWrap
            maximumLineCount: guardCard.quiet ? 3 : 1
            elide: Text.ElideRight
            color: Commons.Color.popups.text
            font.family: window.uiFont
            font.pixelSize: Style.font.body
            text: {
              var c = guardCard.c
              if (!c) return ""
              var esc = function(s) { return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;") }
              var dim = "<font color='" + Commons.Color.muted + "'>"
              if (c.kind === "suggest") return "<b>" + esc(c.s.text) + "</b>"
              if (c.kind === "done") return "<b>" + esc(c.title) + "</b>"
              if (c.kind === "summary") return "<b>Last week</b>" + dim + " · " + esc(guardCard.range) + "</font>"
              if (c.kind === "update") return "<b>Petal updated to " + esc(c.version) + "</b>"
              if (c.kind === "kept") return "<b>Petal " + esc(c.version) + " couldn't take your changes</b>"
              if (c.kind === "held") return "<b>" + esc(c.n.summary) + "</b>" + dim + " · " + esc(c.n.app) + (c.allowedHere ? "" : " · held for " + esc(guardCard.target ? guardCard.target.name : "later")) + "</font>"
              if (c.kind === "guard") return "<b>" + esc(c.title) + "</b> belongs to " + esc(guardCard.target ? guardCard.target.name : "another mode") + "."
              if (c.kind === "fit") return "<b>" + esc(c.title) + "</b>" + dim + " · fits " + esc(guardCard.target ? guardCard.target.name : "") + "</font>"
              return "<b>" + esc(c.title) + "</b>" + dim + " · not in any mode</font>"
            }
          }

          Text {
            width: parent.width
            visible: text !== ""
            wrapMode: Text.Wrap
            maximumLineCount: guardCard.c && guardCard.c.kind === "summary" ? 6 : 3
            elide: Text.ElideRight
            textFormat: Text.PlainText
            color: Commons.Color.popups.text
            font.family: window.uiFont
            font.pixelSize: Style.font.body
            lineHeight: guardCard.c && guardCard.c.kind === "summary" ? 1.15 : 1
            text: {
              var c = guardCard.c
              if (!c) return ""
              if (c.kind === "held") return String(c.n.body || "")
              if (c.kind === "done") return String(c.body || "")
              if (c.kind === "summary") return window.dock.listOf(c.data.lines).slice(0, 6).join("\n")
              if (c.kind === "suggest" && c.busy) return "Making it…"
              if (c.kind === "guard") return "This workspace is in " + (guardCard.here ? guardCard.here.name : "another") + " mode. Go back to what you were doing, or switch the workspace to " + (guardCard.target ? guardCard.target.name : "that mode") + "."
              if (c.kind === "update") return "Restart the shell to finish (a second or two)."
              if (c.kind === "kept") return "You still have your own Petal, with your changes. " + String(c.message || "").split("\n")[0]
              return ""
            }
          }

          Text {
            width: parent.width
            visible: !!guardCard.c && !!guardCard.c.reason
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            color: guardCard.hue
            font.family: window.uiFont
            font.pixelSize: Style.font.caption
            text: guardCard.c && guardCard.c.reason ? "✦ " + (guardCard.c.kind === "held" && !guardCard.c.allowedHere ? "Time-sensitive · " : "") + guardCard.c.reason : ""
          }
        }
      }

      Row {
        anchors.right: parent.right
        spacing: Style.spacing.sm

        CardButton {
          visible: !(guardCard.c && guardCard.c.kind === "suggest" && guardCard.c.busy)
          text: {
            var c = guardCard.c
            if (!c) return ""
            if (c.kind === "update" || c.kind === "kept") return "Later"
            if (c.kind === "held") return c.allowedHere ? "OK" : "Later"
            if (c.kind === "suggest") return "Not now"
            if (c.kind === "done" || c.kind === "summary") return "OK"
            return "Go back"
          }
          onClicked: window.dock.cardStay()
        }
        CardButton {
          visible: !!guardCard.c && (guardCard.c.kind === "suggest" || guardCard.c.kind === "summary")
          primary: true
          text: {
            var c = guardCard.c
            if (!c) return ""
            if (c.kind === "summary") return "More"
            if (c.kind !== "suggest") return ""
            return c.busy ? "Making it…" : c.s && c.s.kind === "add" ? "Keep it" : "Make it"
          }
          onClicked: window.dock.cardGo()
        }
        CardButton {
          // Asks the person's AI to explain it and offer to report it (petal report shows the report first).
          visible: !!guardCard.c && guardCard.c.kind === "kept" && !!window.dock.chatProvider
          primary: true
          text: "Ask " + window.dock.chatName
          onClicked: {
            var v = guardCard.c.version
            window.dock.card = null
            window.dock.openAsk("")
            window.dock.chat.send("Petal " + v + " couldn't take my own changes to Petal's code. Run `petal personal status`, tell me in plain words what happened, and offer to report it with `petal report` (show me the report first).")
          }
        }
        CardButton {
          visible: !!guardCard.c && guardCard.c.kind === "update"
          primary: true
          text: "Restart now"
          onClicked: { window.dock.card = null; window.dock.restartShell() }
        }
        CardButton {
          visible: !!guardCard.c && (guardCard.c.kind === "guard" || guardCard.c.kind === "held") && !!guardCard.target
          primary: true
          hue: guardCard.hue
          text: guardCard.target ? "Switch to " + guardCard.target.name + (guardCard.wait > 0 ? " (" + guardCard.wait + "s)" : "") : ""
          onClicked: window.dock.cardGo()
        }
      }
    }
  }

  component CardButton: Rectangle {
    id: button
    property string text: ""
    property bool primary: false
    property color hue: window.accent
    signal clicked()
    height: Math.round(window.rowHeight * 0.9)
    width: buttonText.implicitWidth + Style.spacing.lg * 2
    radius: Style.cornerRadius
    color: primary ? (buttonMouse.containsMouse ? Qt.lighter(hue, 1.12) : hue) : (buttonMouse.containsMouse ? Style.hoverFill : Qt.rgba(1, 1, 1, 0.06))
    border.width: primary ? 0 : 1
    border.color: Qt.rgba(1, 1, 1, 0.16)

    Text {
      id: buttonText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: button.text
      color: button.primary ? "white" : Commons.Color.popups.text
      font.family: window.uiFont
      font.pixelSize: Style.font.body
      font.bold: button.primary
    }

    MouseArea {
      id: buttonMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: button.clicked()
    }
  }

  // ── Toast: a notification the current mode let through ────────────────
  Glass {
    id: toastCard
    readonly property var t: window.dock ? window.dock.toast : null

    visible: !!t && window.isFocusedScreen && window.shown && !guardCard.visible
    width: Math.round(340 * Style.fontScale) + padding * 2
    height: toastRow.implicitHeight + padding * 2
    x: window.popupX(null, toastCard)
    y: window.popupY(null, toastCard)
    radius: window.popRadius
    color: window.glassFill
    padding: Style.spacing.lg

    Row {
      id: toastRow
      x: toastCard.contentLeftInset
      y: toastCard.contentTopInset
      width: toastCard.width - toastCard.contentLeftInset - toastCard.contentRightInset
      spacing: Style.spacing.md

      Image {
        width: Math.round(window.iconSize * 0.8)
        height: width
        sourceSize: Qt.size(width * 2, height * 2)
        source: toastCard.t && toastCard.t.key && window.dock ? window.dock.iconFor({ key: toastCard.t.key }) : Quickshell.iconPath("dialog-information", true)
        asynchronous: true
      }

      Column {
        width: parent.width - Math.round(window.iconSize * 0.8) - Style.spacing.md
        spacing: 2
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: toastCard.t ? toastCard.t.summary + "  ·  " + toastCard.t.app : ""
          color: Commons.Color.popups.text
          font.family: window.uiFont
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: toastCard.t ? toastCard.t.body : ""
          color: Commons.Color.popups.text
          font.family: window.uiFont
          font.pixelSize: Style.font.body
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        var t = toastCard.t
        window.dock.toast = null
        if (t && t.key) window.dock.activate(window.itemFor(t.key) || { key: t.key, windows: [] })
      }
    }
  }

  // ── Window previews ───────────────────────────────────────────────────
  Glass {
    id: previewCard

    readonly property var item: window.previewItem
    readonly property var windows: item ? item.windows.slice(0, 6) : []

    visible: window.contentShown && window.opt("previews") && windows.length > 0 && !window.menuOpen && !window.stackOpen && !window.dragging && !guardCard.visible
    width: previewRow.implicitWidth + padding * 2
    height: previewRow.implicitHeight + padding * 2
    x: window.popupX(window.previewSlot, previewCard)
    y: window.popupY(window.previewSlot, previewCard)
    radius: window.popRadius
    color: window.glassFill
    padding: Style.spacing.md

    HoverHandler {
      id: previewHover
      onHoveredChanged: if (!hovered) previewHideTimer.restart()
    }

    Row {
      id: previewRow
      x: previewCard.contentLeftInset
      y: previewCard.contentTopInset
      spacing: Style.spacing.md

      Repeater {
        model: previewCard.windows

        delegate: Item {
          id: tile
          required property var modelData

          width: window.thumbWidth
          height: window.thumbHeight + window.rowHeight

          Rectangle {
            id: frame
            width: window.thumbWidth
            height: window.thumbHeight
            radius: Style.cornerRadius
            color: Qt.rgba(0, 0, 0, 0.25)
            border.width: tileMouse.containsMouse ? 2 : 1
            border.color: tileMouse.containsMouse ? window.accent : Qt.rgba(1, 1, 1, 0.12)
            clip: true

            ScreencopyView {
              anchors.centerIn: parent
              captureSource: tile.modelData.toplevel
              live: previewCard.visible
              constraintSize: Qt.size(frame.width - 6, frame.height - 6)
            }
          }

          Text {
            y: window.thumbHeight
            width: window.thumbWidth - closeButton.width * 2 - 4
            height: window.rowHeight
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: String(tile.modelData.toplevel.title || "") + (tile.modelData.minimized ? " (minimized)" : "")
            elide: Text.ElideRight
            color: Commons.Color.popups.text
            font.family: window.uiFont
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            onClicked: function(event) {
              if (event.button === Qt.MiddleButton) {
                tile.modelData.toplevel.close()
                return
              }
              window.dock.bringForward(tile.modelData)
              window.hidePreview()
            }
          }

          // Minimize this window into the dock.
          TileButton {
            id: minButton
            visible: !tile.modelData.minimized
            anchors.right: closeButton.left
            anchors.rightMargin: 4
            glyph: "–"
            onClicked: window.dock.minimize(tile.modelData)
          }

          TileButton {
            id: closeButton
            anchors.right: parent.right
            glyph: "×"
            onClicked: tile.modelData.toplevel.close()
          }
        }
      }
    }
  }

  component TileButton: Rectangle {
    id: tileButton
    property string glyph: ""
    signal clicked()
    y: window.thumbHeight + (window.rowHeight - height) / 2
    width: Math.round(window.rowHeight * 0.75)
    height: width
    radius: width / 2
    color: tbMouse.containsMouse ? window.accent : Qt.rgba(1, 1, 1, 0.1)

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tileButton.glyph
      color: Commons.Color.popups.text
      font.pixelSize: Style.font.title
    }

    MouseArea {
      id: tbMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tileButton.clicked()
    }
  }

  // ── Folder stack ──────────────────────────────────────────────────────
  Glass {
    id: stackCard

    readonly property int maxFiles: 12

    visible: window.contentShown && window.stackOpen
    width: Math.round(300 * Style.fontScale) + padding * 2
    height: stackColumn.implicitHeight + padding * 2
    x: window.popupX(window.stackSlot, stackCard)
    y: window.popupY(window.stackSlot, stackCard)
    radius: window.popRadius
    color: window.glassFill
    padding: Style.spacing.md

    FolderListModel {
      id: stackModel
      folder: window.stackPath ? "file://" + window.stackPath : ""
      showDirs: true
      showDirsFirst: false
      showDotAndDotDot: false
      showHidden: false
      sortField: FolderListModel.Time
    }

    Column {
      id: stackColumn
      x: stackCard.contentLeftInset
      y: stackCard.contentTopInset
      width: stackCard.width - stackCard.contentLeftInset - stackCard.contentRightInset

      Text {
        width: parent.width
        height: window.rowHeight
        verticalAlignment: Text.AlignVCenter
        leftPadding: Style.spacing.md
        textFormat: Text.PlainText
        text: window.baseName(window.stackPath)
        color: window.accent
        font.family: window.uiFont
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Repeater {
        model: stackModel

        delegate: Rectangle {
          id: fileRow
          required property int index
          required property string fileName
          required property string filePath
          required property string fileSuffix
          required property bool fileIsDir

          readonly property bool isImage: ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg"].indexOf(String(fileSuffix).toLowerCase()) >= 0

          visible: index < stackCard.maxFiles
          width: parent.width
          height: visible ? Math.round(window.rowHeight * 1.3) : 0
          radius: Style.cornerRadius
          color: fileMouse.containsMouse ? Style.hoverFill : "transparent"

          Image {
            id: fileIcon
            anchors.verticalCenter: parent.verticalCenter
            x: Style.spacing.md
            width: Math.round(fileRow.height * 0.75)
            height: width
            sourceSize: Qt.size(width * 2, height * 2)
            source: fileRow.isImage ? "file://" + fileRow.filePath
              : Quickshell.iconPath(fileRow.fileIsDir ? "folder" : "text-x-generic", "text-x-generic")
            fillMode: fileRow.isImage ? Image.PreserveAspectCrop : Image.PreserveAspectFit
            asynchronous: true
            clip: true
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: fileIcon.right
            anchors.leftMargin: Style.spacing.md
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.md
            textFormat: Text.PlainText
            text: fileRow.fileName
            elide: Text.ElideMiddle
            color: Commons.Color.popups.text
            font.family: window.uiFont
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: fileMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              window.dock.openPath(fileRow.filePath)
              window.closeStack()
            }
          }
        }
      }

      Text {
        visible: stackModel.count === 0
        width: parent.width
        height: window.rowHeight
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: "Empty"
        color: Commons.Color.muted
        font.family: window.uiFont
        font.pixelSize: Style.font.body
      }

      MenuRow {
        text: "Open in Files  →"
        onTriggered: {
          window.dock.openPath(window.stackPath)
          window.closeStack()
        }
      }
    }
  }

  // ── Settings: every feature switch, in three columns ──────────────────
  // Settings: only what you'd reach for. Everything else (bounce, badges,
  // glow, previews, …) is one sentence to Claude away.
  Glass {
    id: settingsCard

    visible: window.contentShown && window.settingsMenu
    width: Math.round(250 * Style.fontScale) + padding * 2
    height: settingsColumn.implicitHeight + padding * 2
    x: window.popupX(window.menuSlot, settingsCard)
    y: window.popupY(window.menuSlot, settingsCard)
    radius: window.popRadius
    padding: Math.round(6 * Style.fontScale)

    Column {
      id: settingsColumn
      x: settingsCard.contentLeftInset
      y: settingsCard.contentTopInset
      width: settingsCard.width - settingsCard.padding * 2

      MenuHeader { text: "Position" }
      MenuChips {
        options: [["left", "Left"], ["bottom", "Bottom"], ["right", "Right"], ["top", "Top"]]
        current: window.position
        onPicked: value => Util.execDetached("omarchy-dock position " + value)
      }
      MenuRow {
        text: Commons.I18n.t("dock.autoHide")
        toggle: true
        checked: window.autohide
        keepOpen: true
        onTriggered: Util.execDetached("omarchy-dock autohide " + (window.autohide ? "off" : "on"))
      }
      MenuRow {
        text: "Focus cards"
        toggle: true
        checked: window.opt("focusGuard")
        keepOpen: true
        onTriggered: window.dock.toggleSetting("focusGuard")
      }
      MenuRow {
        text: "Hold notifications"
        toggle: true
        checked: window.opt("holdNotifications")
        keepOpen: true
        onTriggered: window.dock.toggleSetting("holdNotifications")
      }
      MenuSeparator {}
      MenuRow {
        visible: !!window.dock && window.dock.providers.length > 0
        text: "Anything else? Ask " + (window.dock ? window.dock.chatName : "Claude") + "…"
        onTriggered: window.dock.openAsk("")
      }
      Text {
        width: parent.width
        leftPadding: Math.round(10 * Style.fontScale)
        rightPadding: Math.round(10 * Style.fontScale)
        bottomPadding: Math.round(6 * Style.fontScale)
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: "Like “stop the icons bouncing” or “turn off the app glow”."
        color: window.soft
        font.family: window.uiFont
        font.pixelSize: Math.round(11.5 * Style.fontScale)
      }
    }
  }

  // ── Menus (app, mode, media, trash, folder) ───────────────────────────
  Glass {
    id: menu

    readonly property var item: window.menuItem
    readonly property var entry: item && window.dock ? window.dock.entryFor(item) : null
    readonly property bool hasEntry: !!entry
    readonly property bool running: !!item && item.windows.length > 0
    readonly property var actions: menu.hasEntry && window.opt("quickActions") ? menu.entry.actions : []
    readonly property var recent: menu.hasEntry && window.dock ? window.dock.recentFilesFor(item.key) : []
    readonly property var m: window.modeMenu

    visible: window.contentShown && window.menuOpen && !window.settingsMenu
    width: Math.round(230 * Style.fontScale) + padding * 2
    height: menuColumn.implicitHeight + padding * 2
    x: window.popupX(window.menuSlot, menu)
    y: window.popupY(window.menuSlot, menu)
    radius: window.popRadius
    color: window.glassFill
    padding: Style.spacing.sm

    Column {
      id: menuColumn
      x: menu.contentLeftInset
      y: menu.contentTopInset
      width: menu.width - menu.contentLeftInset - menu.contentRightInset

      // ── App ──
      MenuHeader { visible: menu.actions.length > 0; text: "Quick actions" }
      Repeater {
        model: menu.actions
        delegate: MenuRow {
          required property var modelData
          text: modelData.name
          onTriggered: modelData.execute()
        }
      }

      MenuHeader { visible: menu.recent.length > 0; text: "Recent" }
      Repeater {
        model: menu.recent
        delegate: MenuRow {
          required property var modelData
          text: decodeURIComponent(String(modelData).split("/").pop())
          onTriggered: window.dock.launchWithFiles(menu.entry, [modelData])
        }
      }

      MenuHeader { visible: menu.hasEntry && (menu.actions.length > 0 || menu.recent.length > 0); text: menu.entry ? menu.entry.name : "" }

      MenuRow {
        visible: menu.hasEntry && menu.running
        text: Commons.I18n.t("dock.newWindow")
        onTriggered: window.dock.launch(menu.item)
      }

      MenuRow {
        visible: menu.hasEntry
        text: !menu.item ? "" : (window.dock.isPinned(menu.item.key, window.modeId) ? "Remove from " : "Keep in ") + (window.mode ? window.mode.name : "dock")
        onTriggered: window.dock.setPinned(menu.item.key, !window.dock.isPinned(menu.item.key, window.modeId), window.modeId)
      }

      MenuHeader { visible: menu.hasEntry && window.opt("modes") && window.dock.modes.length > 1; text: "In modes" }
      Repeater {
        model: menu.hasEntry && window.opt("modes") && window.dock.modes.length > 1 ? window.dock.modes : []
        delegate: MenuRow {
          required property var modelData
          text: (modelData.icon ? modelData.icon + "  " : "") + modelData.name
          glyphs: true
          toggle: true
          checked: !!menu.item && (modelData.apps || []).indexOf(menu.item.key) >= 0
          keepOpen: true
          onTriggered: window.dock.setPinned(menu.item.key, !checked, modelData.id)
        }
      }

      MenuRow {
        visible: menu.running && !!menu.item && menu.item.windows.some(function(w) { return !w.minimized })
        text: "Minimize"
        onTriggered: menu.item.windows.forEach(function(w) { if (!w.minimized && w.workspaceId === window.workspaceId) window.dock.minimize(w) })
      }

      MenuRow {
        visible: menu.running
        text: Commons.I18n.t("dock.quit")
        onTriggered: window.dock.quit(menu.item)
      }

      // ── Mode ──
      MenuHeader { visible: !!menu.m; text: menu.m ? menu.m.name : "" }
      MenuRow {
        visible: !!menu.m && menu.m.id !== window.modeId
        text: "Use on this workspace"
        onTriggered: window.dock.requestMode(window.workspaceId, menu.m.id)
      }
      MenuRow {
        visible: !!menu.m
        text: "Hold notifications"
        toggle: true
        checked: !!menu.m && menu.m.hold === true
        keepOpen: true
        onTriggered: {
          window.dock.setModeField(menu.m.id, "hold", !(menu.m.hold === true))
          window.modeMenu = window.dock.modeById(menu.m.id)
        }
      }
      MenuRow {
        visible: !!menu.m
        text: "Default mode"
        toggle: true
        checked: !!menu.m && window.dock.modesData.defaultMode === menu.m.id
        keepOpen: true
        onTriggered: {
          var data = window.dock.cloneModes()
          data.defaultMode = menu.m.id
          window.dock.saveModes(data)
        }
      }
      MenuHeader { visible: !!menu.m && window.opt("countdown"); text: "Countdown to leave" }
      MenuChips {
        visible: !!menu.m && window.opt("countdown")
        options: [[0, "Off"], [15, "15s"], [30, "30s"], [60, "1m"]]
        current: menu.m ? Number(menu.m.focusDelay || 0) : 0
        onPicked: value => {
          window.dock.setModeField(menu.m.id, "focusDelay", value)
          window.modeMenu = window.dock.modeById(menu.m.id)
        }
      }
      MenuSeparator { visible: !!menu.m }
      MenuRow {
        visible: !!menu.m && window.dock.heldCount(menu.m.id) > 0
        text: "Show " + (menu.m ? window.dock.heldCount(menu.m.id) : 0) + " held…"
        onTriggered: window.dock.openPanel("held:" + menu.m.id)
      }
      MenuRow {
        visible: !!menu.m && window.dock.heldCount(menu.m.id) > 0
        text: "Clear " + (menu.m ? window.dock.heldCount(menu.m.id) : 0) + " held"
        onTriggered: window.dock.clearHeld(menu.m.id)
      }
      MenuRow {
        visible: !!menu.m && window.dock.providers.length > 0
        text: "Change with " + window.dock.chatName + "…"
        onTriggered: window.dock.openAsk(menu.m ? "Change my " + menu.m.name + " mode: " : "")
      }
      MenuRow {
        visible: !!menu.m && window.dock.modes.length > 1
        text: window.confirmDelete ? "Click again to delete" : "Delete mode"
        keepOpen: !window.confirmDelete
        danger: true
        onTriggered: {
          if (!window.confirmDelete) {
            window.confirmDelete = true
            return
          }
          window.dock.deleteMode(menu.m.id)
        }
      }

      // ── Media ──
      MenuHeader { visible: window.mediaMenu; text: window.player ? String(window.player.identity || "Media") : "" }
      MenuRow { visible: window.mediaMenu && !!window.player && window.player.canGoPrevious; text: "Previous"; onTriggered: window.player.previous() }
      MenuRow { visible: window.mediaMenu && !!window.player && window.player.canGoNext; text: "Next"; onTriggered: window.player.next() }
      MenuRow { visible: window.mediaMenu && !!window.player && window.player.canRaise; text: "Show player"; onTriggered: window.player.raise() }

      // ── Trash ──
      MenuRow {
        visible: window.trashMenu
        text: "Open Trash"
        onTriggered: window.dock.openTrash()
      }

      MenuRow {
        visible: window.trashMenu
        text: window.confirmEmpty ? "Click again to empty" : "Empty Trash…"
        keepOpen: !window.confirmEmpty
        danger: window.confirmEmpty
        onTriggered: {
          if (!window.confirmEmpty) {
            window.confirmEmpty = true
            return
          }
          window.dock.emptyTrash()
        }
      }

      // ── Folder ──
      MenuRow {
        visible: window.stackMenuPath !== ""
        text: "Open in Files"
        onTriggered: window.dock.openPath(window.stackMenuPath)
      }

      MenuRow {
        visible: window.stackMenuPath !== ""
        text: Commons.I18n.t("dock.removeFromDock")
        onTriggered: window.dock.removeStack(window.stackMenuPath)
      }
    }
  }

  component Glass: Rectangle {
    property int padding: 0
    readonly property int contentLeftInset: padding
    readonly property int contentRightInset: padding
    readonly property int contentTopInset: padding
    color: window.glassFill
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.1)
  }

  component MenuHeader: Text {
    width: parent ? parent.width : 0
    height: visible ? Math.round(28 * Style.fontScale) : 0
    verticalAlignment: Text.AlignBottom
    leftPadding: Math.round(10 * Style.fontScale)
    bottomPadding: Math.round(5 * Style.fontScale)
    textFormat: Text.PlainText
    color: window.soft
    font.family: window.uiFont
    font.pixelSize: Math.round(11 * Style.fontScale)
    font.weight: Font.DemiBold
    font.letterSpacing: 0.4
  }

  component MenuSeparator: Item {
    width: parent ? parent.width : 0
    height: visible ? Math.round(9 * Style.fontScale) : 0
    Rectangle {
      anchors.centerIn: parent
      width: parent.width - Math.round(16 * Style.fontScale)
      height: 1
      color: Qt.rgba(1, 1, 1, 0.08)
    }
  }

  // A row of small choices (position, countdown, …).
  component MenuChips: Item {
    id: chips
    property var options: []
    property var current
    signal picked(var value)
    width: parent ? parent.width : 0
    height: visible ? Math.round(34 * Style.fontScale) : 0

    Row {
      anchors.verticalCenter: parent.verticalCenter
      x: Math.round(6 * Style.fontScale)
      spacing: Math.round(3 * Style.fontScale)
      Repeater {
        model: chips.options
        delegate: Rectangle {
          id: chip
          required property var modelData
          readonly property bool on: chips.current === modelData[0]
          width: chipLabel.implicitWidth + Math.round(13 * Style.fontScale)
          height: Math.round(24 * Style.fontScale)
          radius: height / 2
          color: on ? Qt.rgba(window.accent.r, window.accent.g, window.accent.b, 0.85) : (chipMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05))
          Text {
            id: chipLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: chip.modelData[1]
            color: chip.on ? "white" : window.ink
            font.family: window.uiFont
            font.pixelSize: Math.round(12 * Style.fontScale)
          }
          MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chips.picked(chip.modelData[0])
          }
        }
      }
    }
  }

  component MenuRow: Rectangle {
    id: row

    property string text: ""
    property bool checked: false
    property bool toggle: false
    property bool keepOpen: false
    property bool danger: false
    property bool glyphs: false
    signal triggered()

    width: parent ? parent.width : 0
    height: visible ? Math.round(32 * Style.fontScale) : 0
    radius: Math.round(9 * Style.fontScale)
    color: rowMouse.containsMouse ? (row.danger ? Qt.rgba(1, 0.3, 0.45, 0.18) : Qt.rgba(1, 1, 1, 0.07)) : "transparent"

    Text {
      id: rowText
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Math.round(10 * Style.fontScale)
      anchors.right: mark.left
      anchors.rightMargin: Math.round(8 * Style.fontScale)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: row.text
      color: row.danger ? "#ff6b8a" : window.ink
      font.family: row.glyphs ? window.glyphFont : window.uiFont
      font.pixelSize: Math.round(13 * Style.fontScale)
    }

    // A switch for on/off rows, a check for picked ones.
    Item {
      id: mark
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Math.round(10 * Style.fontScale)
      width: row.toggle ? Math.round(28 * Style.fontScale) : (row.checked ? checkText.implicitWidth : 0)
      height: Math.round(16 * Style.fontScale)

      Rectangle {
        visible: row.toggle
        anchors.fill: parent
        radius: height / 2
        color: row.checked ? window.accent : Qt.rgba(1, 1, 1, 0.14)
        Behavior on color { ColorAnimation { duration: 140 } }
        Rectangle {
          width: parent.height - 4
          height: width
          radius: width / 2
          y: 2
          x: row.checked ? parent.width - width - 2 : 2
          color: "white"
          Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
      }

      Text {
        id: checkText
        visible: !row.toggle && row.checked
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "✓"
        color: window.accent
        font.family: window.uiFont
        font.pixelSize: Math.round(13 * Style.fontScale)
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        // Decide before triggering: a two-step row (confirm) flips keepOpen.
        var keep = row.keepOpen
        row.triggered()
        if (!keep) window.closeMenu()
      }
    }
  }
}
