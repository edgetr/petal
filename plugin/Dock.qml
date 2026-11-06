import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "DockModel.js" as DockModel

// Petal: an AI-native dock with focus modes. Each workspace remembers its
// mode (Building, Writing, Social, ...), and each mode has its own apps,
// notification rules and a countdown before you can leave it. Claude sorts
// unfamiliar windows and notifications into modes.
//
// Files:  ~/.config/petal/modes.json     modes, their apps, workspace -> mode
//         ~/.config/petal/settings.json  feature switches (dock's right-click menu)
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/petal"

  // ── Position and auto-hide (Omarchy's shell.json, via omarchy-dock) ────
  readonly property var dockConfig: root.readDock(userConfigFile.loadedText)
  function readDock(text) {
    try {
      var parsed = JSON.parse(text || "{}")
      return parsed && parsed.dock ? parsed.dock : ({})
    } catch (e) {
      return ({})
    }
  }

  FileView {
    id: userConfigFile
    property string loadedText: ""
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: loadedText = text()
  }

  // Whether Petal's mode indicator sits in Omarchy's bar (BarWidget.qml).
  readonly property bool inBar: {
    try {
      var layout = (JSON.parse(userConfigFile.loadedText || "{}").bar || {}).layout || {}
      for (var section in layout) {
        var list = layout[section] || []
        for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === "egesuren.petal") return true
      }
    } catch (e) {}
    return false
  }

  function setInBar(on) {
    if (on) {
      Util.execDetached("omarchy bar put egesuren.petal --after omarchy.workspaces")
      return
    }
    // Off the bar only: Petal itself stays on (its plugins[] entry).
    Quickshell.execDetached(["python3", "-c", "import json, os, sys\n"
      + "p = os.path.expanduser('~/.config/omarchy/shell.json')\n"
      + "d = json.load(open(p))\n"
      + "layout = (d.get('bar') or {}).get('layout') or {}\n"
      + "for k, v in layout.items():\n"
      + "    if isinstance(v, list): layout[k] = [e for e in v if not (isinstance(e, dict) and e.get('id') == 'egesuren.petal')]\n"
      + "json.dump(d, open(p + '.tmp', 'w'), indent=2)\n"
      + "os.replace(p + '.tmp', p)\n"])
  }

  readonly property string position: DockModel.normalizePosition(dockConfig.position)
  readonly property bool vertical: DockModel.isVertical(position)
  readonly property bool autohide: dockConfig.autohide === true
  // How far the dock reaches up from the screen's bottom (DockWindow's gap + slot + padding), so the chat and the
  // "+" search open just above it, out of the dock rather than floating over it. 0 for a side dock.
  readonly property int dockReach: {
    if (vertical || position === "top") return 0
    var s = root.settings
    var margin = s && s.dockMargin >= 0 ? s.dockMargin * Style.fontScale : Style.spacing.xs
    var icon = Math.max(16, s && s.iconSize ? s.iconSize : 36) * Style.fontScale
    var inset = s && s.iconPadding >= 0 ? s.iconPadding * Style.fontScale : Style.spacing.md
    return Math.round(margin + icon + inset * 2 + Style.spacing.xs * 2)
  }

  // ── Settings ──────────────────────────────────────────────────────────
  property alias settings: settingsAdapter

  FileView {
    id: settingsFile
    path: root.configDir + "/settings.json"
    watchChanges: true
    onFileChanged: reload()
    onAdapterUpdated: writeAdapter()
    onLoadFailed: error => { if (error === FileViewError.FileNotFound) writeAdapter() }

    JsonAdapter {
      id: settingsAdapter
      // Looks
      property bool tooltips: true
      property bool hoverLift: true
      property bool appGlow: true
      // Apps
      property bool thisWorkspaceOnly: true
      property bool previews: true
      property bool minimized: true
      property bool badges: true
      property bool bounce: true
      property bool progress: true
      property bool quickActions: true
      property bool recentFiles: true
      property bool dropToOpen: true
      // Extras
      property bool nowPlaying: true
      property bool stacks: true
      property list<string> stackFolders: ["~/Downloads", "~/Pictures/Screenshots"]
      property bool trash: true
      // Appearance. Colors are "#rrggbb" ("" follows the Omarchy theme);
      // sizes are in points (scaled with the display).
      property string dockColor: ""
      property real dockOpacity: 0.45
      property string dockBorderColor: "#ffffff"
      property real dockBorderOpacity: 0.28
      property int dockRadius: -1
      property bool dockSheen: true
      property int dockMargin: -1
      property int iconSize: 36
      property int iconPadding: -1
      property real idleOpacity: 0.7
      property bool separators: true
      property real hoverLiftAmount: 0.05
      property real glowStrength: 1.0
      property string accentColor: ""
      property string popupColor: ""
      property real popupOpacity: 0.74
      property string font: "Adwaita Sans"
      // Modes and AI
      property bool modes: true
      property bool focusGuard: false
      property bool countdown: false
      property bool holdNotifications: true
      property bool ai: true
      property bool claudeUsage: true
      property bool autoUpdate: true
      property string claudePath: ""
      // The Claude panel's chat (Claude Code CLI): model alias, effort
      // (low … max), and access: "auto" (Claude Code's auto mode: safe actions
      // run on their own, risky ones ask) or "full" (bypass permissions).
      property string chatModel: "sonnet"
      property string chatEffort: "medium"
      property string claudeAccess: "auto"
      // Which AI apps Petal uses ("claude", "codex"; [] = none: the dock works
      // whole without AI), and which one the chat, usage ring and sorting use.
      property list<string> aiProviders: ["claude"]
      property bool otherAgents: true
      // Shortcuts, schedules, the private activity history behind suggestions
      // and the weekly summary; magnification and the menu bar icon are macOS's.
      property bool shortcuts: true
      property var schedule: []
      property bool activityLog: true
      property bool suggestModes: true
      property bool summary: true
      property bool magnification: false
      property real magnificationAmount: 0.5
      property bool menuBarIcon: true
      property string chatProvider: "claude"
      property string codexModel: ""
      property string codexEffort: "medium"
      property string codexPath: ""
    }
  }

  // The look every Petal surface shares, from the settings above.
  readonly property color accent: settingsAdapter.accentColor ? Qt.color(settingsAdapter.accentColor) : Commons.Color.accent
  readonly property string uiFont: settingsAdapter.font || "Adwaita Sans"
  readonly property color popupFill: {
    var base = settingsAdapter.popupColor ? Qt.color(settingsAdapter.popupColor) : Commons.Color.popups.background
    return Qt.rgba(base.r, base.g, base.b, settingsAdapter.popupOpacity)
  }

  function toggleSetting(name) {
    settingsAdapter[name] = !settingsAdapter[name]
  }

  function listOf(values) {
    var out = []
    for (var i = 0; i < (values ? values.length : 0); i++) out.push(String(values[i]))
    return out
  }

  // ── Modes ─────────────────────────────────────────────────────────────
  property var modesData: ({ defaultMode: "", workspaces: {}, modes: [] })
  readonly property var modes: modesData.modes || []

  FileView {
    id: modesFileView
    path: root.configDir + "/modes.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && Array.isArray(parsed.modes)) {
          parsed.workspaces = parsed.workspaces || {}
          root.modesData = parsed
        }
      } catch (e) {
        console.warn("petal: modes.json is not valid JSON:", e)
      }
    }
  }

  function modesFile() {
    return root.modesData
  }

  function saveModes(data) {
    root.modesData = data
    modesFileView.setText(JSON.stringify(data, null, 2) + "\n")
  }

  function cloneModes() {
    return JSON.parse(JSON.stringify(root.modesData))
  }

  function modeById(id) {
    for (var i = 0; i < root.modes.length; i++) if (root.modes[i].id === id) return root.modes[i]
    return null
  }

  function modeIdForWorkspace(wsId) {
    var ws = root.modesData.workspaces || {}
    var id = ws[String(wsId)] || root.modesData.defaultMode || (root.modes.length ? root.modes[0].id : "")
    return root.modeById(id) ? id : (root.modes.length ? root.modes[0].id : "")
  }

  function modeForWorkspace(wsId) {
    return root.modeById(root.modeIdForWorkspace(wsId))
  }

  function modeColor(mode) {
    return mode && mode.color ? mode.color : "#ff5fae"
  }

  // The mode a desktop id belongs to, other than `except`.
  function modeOwning(key, except) {
    for (var i = 0; i < root.modes.length; i++) {
      var m = root.modes[i]
      if (m.id !== except && (m.apps || []).indexOf(key) >= 0) return m
    }
    return null
  }

  readonly property var focusedMonitor: Hyprland.focusedMonitor
  readonly property int focusedWorkspaceId: focusedMonitor && focusedMonitor.activeWorkspace ? focusedMonitor.activeWorkspace.id : -1
  readonly property var focusedMode: root.modeForWorkspace(focusedWorkspaceId)
  readonly property string focusedModeId: focusedMode ? focusedMode.id : ""

  // A switch away from a focus mode waits out that mode's countdown.
  // pending: { ws, mode, deadline, total } or null
  property var pending: null
  property double now: Date.now()

  Timer {
    interval: 250
    repeat: true
    running: root.pending !== null || root.toast !== null
    onTriggered: {
      root.now = Date.now()
      if (root.pending && root.now >= root.pending.deadline) {
        var p = root.pending
        root.pending = null
        root.applyMode(p.ws, p.mode)
      }
    }
  }

  function pendingSecondsLeft() {
    return root.pending ? Math.max(0, Math.ceil((root.pending.deadline - root.now) / 1000)) : 0
  }

  function requestMode(wsId, modeId) {
    if (!(wsId >= 1) || !root.modeById(modeId)) return
    var current = root.modeForWorkspace(wsId)
    if (current && current.id === modeId) {
      root.pending = null
      return
    }
    var delay = current && root.settings.countdown ? Number(current.focusDelay || 0) : 0
    if (delay <= 0) {
      root.applyMode(wsId, modeId)
      return
    }
    var now = Date.now()
    root.now = now
    if (root.pending && root.pending.ws === wsId && root.pending.mode === modeId) {
      // Each extra press cuts the wait in half.
      var left = root.pending.deadline - now
      root.pending = Object.assign({}, root.pending, { deadline: now + left / 2 })
      if (left / 2 < 1500) {
        root.pending = null
        root.applyMode(wsId, modeId)
      }
      return
    }
    root.pending = { ws: wsId, mode: modeId, deadline: now + delay * 1000, total: delay * 1000 }
  }

  function stay() {
    root.pending = null
  }

  function applyMode(wsId, modeId) {
    var data = root.cloneModes()
    data.workspaces = data.workspaces || {}
    data.workspaces[String(wsId)] = modeId
    root.saveModes(data)
    root.clearHeld(modeId)
    if (root.card && root.card.target === modeId) root.card = null
  }

  function setModeApps(modeId, apps) {
    var data = root.cloneModes()
    for (var i = 0; i < data.modes.length; i++) {
      if (data.modes[i].id === modeId) data.modes[i].apps = apps
    }
    root.saveModes(data)
  }

  function modeApps(modeId) {
    var m = root.modeById(modeId)
    return m ? root.listOf(m.apps) : []
  }

  function isPinned(key, modeId) {
    return root.modeApps(modeId || root.focusedModeId).indexOf(key) >= 0
  }

  function setPinned(key, pinned, modeId) {
    var id = modeId || root.focusedModeId
    if (!key || !id) return
    var apps = root.modeApps(id).filter(function(k) { return k !== key })
    if (pinned) apps.push(key)
    root.setModeApps(id, apps)
  }

  function setModeField(modeId, field, value) {
    var data = root.cloneModes()
    for (var i = 0; i < data.modes.length; i++) {
      if (data.modes[i].id === modeId) data.modes[i][field] = value
    }
    root.saveModes(data)
  }

  function deleteMode(modeId) {
    var data = root.cloneModes()
    if (data.modes.length <= 1) return
    data.modes = data.modes.filter(function(m) { return m.id !== modeId })
    for (var ws in data.workspaces) if (data.workspaces[ws] === modeId) delete data.workspaces[ws]
    if (data.defaultMode === modeId) data.defaultMode = data.modes[0].id
    root.saveModes(data)
  }

  function openModesFile() {
    Util.execDetached("xdg-open " + Util.shellQuote(root.configDir + "/modes.json"))
  }

  // ── Apps and windows ──────────────────────────────────────────────────
  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.runInTerminal || String(entry.execString || "").indexOf("--app-id=") >= 0)
        out.push({ id: entry.id, execString: entry.execString, command: entry.command, runInTerminal: entry.runInTerminal })
    }
    return out
  }

  function installedApps() {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      if (!values[i].noDisplay) out.push({ id: values[i].id, name: values[i].name })
    }
    return out
  }

  // The program an entry runs, to tell when two entries launch the same app.
  function execKey(entry) {
    var exec = String(entry && entry.execString || "").trim()
    var m = exec.match(/^"([^"]+)"|^(\S+)/)
    return m ? (m[1] || m[2]) : ""
  }

  // A window can claim a hidden helper entry (T3 Code claims the NoDisplay
  // com.t3tools.T3Code); prefer the visible entry that runs the same program.
  function visibleTwin(entry) {
    if (!entry || !entry.noDisplay) return entry
    var key = root.execKey(entry)
    if (!key) return entry
    var values = DesktopEntries.applications.values
    for (var i = 0; i < values.length; i++) {
      if (!values[i].noDisplay && root.execKey(values[i]) === key) return values[i]
    }
    return entry
  }

  function entryForAppId(appId) {
    var entry = root.visibleTwin(DesktopEntries.heuristicLookup(appId))
    if (entry) return entry
    var id = DockModel.claimingEntryId(appId, root.terminalEntries)
    return id ? DesktopEntries.byId(id) : null
  }

  function isBrowser(entry) {
    if (!entry) return false
    var cats = root.listOf(entry.categories)
    return cats.indexOf("WebBrowser") >= 0
  }

  // Every app window, once, with the desktop id that claims it.
  readonly property var allWindows: {
    var appsRevision = DesktopEntries.applications.values.length
    var out = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i].wayland
      if (!toplevel || !toplevel.appId || toplevel.parent) continue
      var entry = root.entryForAppId(toplevel.appId)
      var workspace = toplevels[i].workspace
      out.push({
        key: entry ? entry.id : toplevel.appId,
        hasEntry: !!entry && !entry.noDisplay,
        workspaceId: workspace ? workspace.id : -1,
        minimized: !!workspace && DockModel.isMinimizedWorkspace(workspace.name),
        address: toplevels[i].address,
        toplevel: toplevel
      })
    }
    return out
  }

  readonly property var minimizedWindows: root.allWindows.filter(function(w) { return w.minimized })

  // The dock's apps on one workspace: its mode's apps in order, then other
  // apps with a window open (on this workspace only, if so set).
  function itemsFor(modeId, wsId) {
    var appsRevision = DesktopEntries.applications.values.length
    var pinned = root.modeApps(modeId).filter(function(id) { return !!DesktopEntries.byId(id) })
    var items = []
    var byKey = {}
    for (var i = 0; i < pinned.length; i++) {
      if (byKey[pinned[i]]) continue
      byKey[pinned[i]] = { key: pinned[i], pinned: true, windows: [], here: 0 }
      items.push(byKey[pinned[i]])
    }
    var separateMinimized = root.settings.minimized
    var windows = root.allWindows
    for (var j = 0; j < windows.length; j++) {
      var w = windows[j]
      if (!DockModel.isDockWindow(w)) continue
      var item = byKey[w.key]
      if (!item) {
        if (w.minimized && separateMinimized) continue
        // An app that belongs to another mode only shows in its own mode.
        if (root.settings.modes && root.modeOwning(w.key, modeId)) continue
        if (root.settings.thisWorkspaceOnly && !w.minimized && w.workspaceId !== wsId) continue
        item = byKey[w.key] = { key: w.key, pinned: false, windows: [], here: 0 }
        items.push(item)
      }
      item.windows.push(w)
      if (w.workspaceId === wsId) item.here++
    }
    return items
  }

  function entryFor(item) {
    return item ? DesktopEntries.byId(item.key) : null
  }

  function iconFor(item) {
    var entry = root.entryFor(item)
    var icon = entry && entry.icon ? entry.icon : (item ? item.key : "")
    return Quickshell.iconPath(icon, true) || Quickshell.iconPath("application-x-executable", true)
  }

  readonly property var activeKey: {
    var t = Hyprland.activeToplevel
    if (!t || !t.wayland) return ""
    var entry = root.entryForAppId(t.wayland.appId)
    return entry ? entry.id : String(t.wayland.appId || "")
  }

  function isFocusedKey(key) {
    return key !== "" && key === root.activeKey
  }

  onActiveKeyChanged: signalsWatch.clear(root.activeKey)

  // An app launched from the dock pulses until its window shows up.
  property var launches: ({})

  function isLaunching(key) {
    return root.launches[key] !== undefined
  }

  function windowCount(key) {
    var n = 0
    for (var i = 0; i < root.allWindows.length; i++) if (root.allWindows[i].key === key) n++
    return n
  }

  onAllWindowsChanged: root.settleLaunches()

  function settleLaunches() {
    var next = {}
    var changed = false
    var now = Date.now()
    for (var key in root.launches) {
      var launch = root.launches[key]
      if (root.windowCount(key) > launch.windows || now - launch.at > 10000) changed = true
      else next[key] = launch
    }
    if (changed) root.launches = next
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.launches).length > 0
    onTriggered: root.settleLaunches()
  }

  function launch(item) {
    var entry = root.entryFor(item)
    if (!entry) return
    var next = Object.assign({}, root.launches)
    next[item.key] = { at: Date.now(), windows: root.windowCount(item.key) }
    root.launches = next
    root.launchEntry(entry)
  }

  // As its own session unit, the way Omarchy launches apps.
  function launchEntry(entry) {
    if (!entry) return
    root.withoutWarp("uwsm-app -- " + Util.shellQuote(entry.id + ".desktop"))
  }

  // Opens files with an app: its Exec line with the files in place of the
  // field codes (or after it, if it has none).
  function launchWithFiles(entry, urls) {
    if (!entry || !urls || urls.length === 0) return
    var files = root.listOf(urls)
    var paths = files.map(function(u) { return decodeURIComponent(u.replace(/^file:\/\//, "")) })
    var args = []
    var placed = false
    var command = root.listOf(entry.command)
    for (var i = 0; i < command.length; i++) {
      var a = command[i]
      if (a === "%f" || a === "%u") { if (!placed) args.push(a === "%u" ? files[0] : paths[0]); placed = true }
      else if (a === "%F" || a === "%U") { args = args.concat(a === "%U" ? files : paths); placed = true }
      else if (/^%[ickvmdDnN]$/.test(a)) continue
      else args.push(a)
    }
    if (!placed) args = args.concat(paths)
    if (args.length === 0) return
    root.withoutWarp(["uwsm-app", "--"].concat(args).map(function(a) { return Util.shellQuote(a) }).join(" "))
  }

  function activate(item) {
    if (!item) return
    if (item.windows.length === 0) {
      root.launch(item)
      return
    }
    var monitor = Hyprland.focusedMonitor
    var workspaceId = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    var index = DockModel.pickWindow(item.windows.map(function(window) {
      return { workspaceId: window.workspaceId, minimized: window.minimized, activated: window.toplevel.activated }
    }), workspaceId)
    root.bringForward(item.windows[index])
  }

  function dispatchFor(address) {
    var a = String(address || "")
    if (a && a.indexOf("0x") !== 0) a = "0x" + a
    return a ? "window = \"address:" + a + "\"" : ""
  }

  // A window the dock brings forward lands on top, focused; a minimized one
  // first comes back to the workspace in front of the user.
  function bringForward(window) {
    var target = root.dispatchFor(window.address)
    if (!target) {
      window.toplevel.activate()
      return
    }
    var steps = []
    var after = []
    if (window.minimized) {
      var monitor = Hyprland.focusedMonitor
      var workspace = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
      if (!(workspace >= 1)) return
      steps.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", " + target + " })")
      steps.push("hl.dsp.window.move({ workspace = \"" + workspace + "\", " + target + " })")
      after.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", " + target + " })")
    }
    steps.push("hl.dsp.focus({ " + target + " })")
    steps.push("hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })")
    var dispatch = function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }
    var command = steps.map(dispatch).join(" && ")
    if (after.length > 0) command += "; sleep 0.4; " + after.map(dispatch).join("; ")
    root.withoutWarp(command)
  }

  function minimize(window) {
    var a = String(window.address || "")
    if (a.indexOf("0x") !== 0) a = "0x" + a
    Util.execDetached("omarchy-hyprland-window-minimize " + Util.shellQuote(a))
  }

  function focusAddress(address) {
    var target = root.dispatchFor(address)
    if (target) root.withoutWarp("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ " + target + " })"))
  }

  // Hyprland moves the pointer onto a window it focuses (and to the middle
  // of a workspace it switches to). Clicking the dock shouldn't move your
  // pointer, so Petal turns those warps off while it focuses or opens an
  // app, then puts your own settings back.
  property bool warpOff: false
  property string warpRestore: ""

  function withoutWarp(command) {
    if (root.warpOff) {
      Util.execDetached(command)
    } else {
      root.warpOff = true
      warpProc.command = ["bash", "-c",
        "nw=$(hyprctl getoption cursor:no_warps -j | jq -r .bool); "
        + "wc=$(hyprctl getoption cursor:warp_on_change_workspace -j | jq -r .int); "
        + "echo \"$nw $wc\"; "
        + "hyprctl eval 'hl.config({ cursor = { no_warps = true, warp_on_change_workspace = 0 } })' >/dev/null; "
        + command]
      warpProc.running = true
    }
    // A new app's window can take a moment to appear and take focus.
    warpTimer.restart()
  }

  Process {
    id: warpProc
    stdout: SplitParser {
      onRead: line => {
        var parts = String(line).trim().split(/\s+/)
        if (parts.length === 2 && /^(true|false)$/.test(parts[0]) && /^-?\d+$/.test(parts[1]))
          root.warpRestore = "hl.config({ cursor = { no_warps = " + parts[0] + ", warp_on_change_workspace = " + parts[1] + " } })"
      }
    }
  }

  Timer {
    id: warpTimer
    interval: 2500
    onTriggered: {
      root.warpOff = false
      // If the old values couldn't be read, fall back to Omarchy's defaults
      // rather than leaving warps off.
      var restore = root.warpRestore || "hl.config({ cursor = { no_warps = false, warp_on_change_workspace = 1 } })"
      Util.execDetached("hyprctl eval " + Util.shellQuote(restore) + " >/dev/null")
      root.warpRestore = ""
    }
  }


  function quit(item) {
    if (!item) return
    var windows = item.windows.slice()
    for (var i = 0; i < windows.length; i++) windows[i].toplevel.close()
  }

  // ── Bounce ────────────────────────────────────────────────────────────
  // key -> time of the last bounce request; each dock icon watches its own.
  property var bounces: ({})

  function bounce(key) {
    if (!key || !root.settings.bounce || root.isFocusedKey(key)) return
    var next = Object.assign({}, root.bounces)
    next[key] = Date.now()
    root.bounces = next
  }

  function keyForAddress(address) {
    var a = String(address || "").replace(/^0x/, "")
    for (var i = 0; i < root.allWindows.length; i++) {
      if (String(root.allWindows[i].address).replace(/^0x/, "") === a) return root.allWindows[i].key
    }
    return ""
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "urgent") root.bounce(root.keyForAddress(event.data))
      else if (name === "activewindowv2" || name === "windowtitlev2") guardTimer.restart()
      else if (name === "fullscreen") {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
      }
    }
  }

  // ── Notifications: badges, holding, time-sensitive ones ───────────────

  Signals {
    id: signalsWatch
    dock: root
    onNotified: n => root.handleNotification(n)
  }

  function badgeFor(key) {
    return root.settings.badges ? signalsWatch.badgeFor(key) : 0
  }

  function progressFor(key) {
    var p = signalsWatch.progress[key]
    return root.settings.progress && p !== undefined ? p : -1
  }

  // modeId -> notifications held for it
  property var held: ({})
  property int heldSeq: 0

  function heldCount(modeId) {
    return (root.held[modeId] || []).length
  }

  readonly property int heldTotal: {
    var n = 0
    for (var id in root.held) n += (root.held[id] || []).length
    return n
  }

  // Every held notification, newest first: [{ mode, n }]
  function heldList(modeId) {
    var out = []
    for (var id in root.held) {
      if (modeId && id !== modeId) continue
      var list = root.held[id] || []
      for (var i = 0; i < list.length; i++) out.push({ mode: id, n: list[i] })
    }
    out.sort(function(a, b) { return (b.n.at || 0) - (a.n.at || 0) })
    return out
  }

  function dismissHeld(modeId, hid) {
    var next = Object.assign({}, root.held)
    next[modeId] = (next[modeId] || []).filter(function(x) { return x.hid !== hid })
    if (next[modeId].length === 0) delete next[modeId]
    root.held = next
  }

  // Opens the app a held notification came from (its own buttons went with
  // it off Omarchy's screen), and lets it go.
  function openHeld(modeId, n) {
    root.dismissHeld(modeId, n.hid)
    if (!n.key) return
    var windows = root.allWindows.filter(function(w) { return w.key === n.key })
    root.activate({ key: n.key, windows: windows })
  }

  function clearAllHeld() {
    root.held = ({})
  }

  function clearHeld(modeId) {
    if (!root.held[modeId]) return
    var next = Object.assign({}, root.held)
    delete next[modeId]
    root.held = next
  }

  function holdFor(modeId, n) {
    if (!n.hid) n.hid = ++root.heldSeq
    var next = Object.assign({}, root.held)
    next[modeId] = (next[modeId] || []).concat([n]).slice(-50)
    root.held = next
  }

  readonly property bool holding: root.settings.modes && root.settings.holdNotifications && !!root.focusedMode && root.focusedMode.hold === true

  // Held notifications are taken off Omarchy's screen as they arrive (they
  // stay in its notification history). Everything the mode allows shows as
  // usual, buttons and all ("Allow this?" prompts keep working).
  function dismissFromOmarchy(n) {
    var summary = String(n.summary || "").slice(0, 60)
    if (!summary) return
    var q = Util.shellQuote(summary)
    Util.execDetached("sleep 0.12; omarchy-shell notifications dismiss " + q + " >/dev/null; sleep 0.5; omarchy-shell notifications dismiss " + q + " >/dev/null")
  }

  // A notification Petal itself shows while Omarchy is quiet.
  property var toast: null

  function showToast(n) {
    root.toast = Object.assign({}, n, { until: Date.now() + 6000 })
    root.now = Date.now()
  }

  onNowChanged: if (root.toast && root.now > root.toast.until) root.toast = null

  function handleNotification(n) {
    if (n.key) root.bounce(n.key)
    if (!root.holding) return
    var mode = root.focusedMode
    var allowed = root.listOf(mode.apps).concat(root.listOf(mode.allow))
    if (n.urgency >= 2 || (n.key && allowed.indexOf(n.key) >= 0)) return
    var owner = n.key ? root.modeOwning(n.key, mode.id) : null
    var target = owner ? owner.id : "other"
    root.holdFor(target, n)
    root.dismissFromOmarchy(n)
    if (!brain.enabled) return
    brain.classifyNotification(n, function(r) {
      if (!r) return
      var to = r.mode && root.modeById(r.mode) ? r.mode : target
      if (r.mode === mode.id) {
        // Claude thinks it belongs here after all: show it as a card.
        root.card = { kind: "held", n: n, target: "", reason: String(r.reason || ""), allowedHere: true }
        return
      }
      if (to !== target) {
        // Move it to the mode Claude picked.
        var next = Object.assign({}, root.held)
        next[target] = (next[target] || []).filter(function(x) { return x !== n })
        root.held = next
        root.holdFor(to, n)
      }
      if (r.urgent === true) {
        root.card = { kind: "held", n: n, target: to, reason: String(r.reason || "") }
      }
    })
  }

  // ── Focus guard ───────────────────────────────────────────────────────
  // When the focused window doesn't belong to its workspace's focus mode,
  // a card above the dock asks: stay focused, or switch?
  //   card: { kind: "guard"|"fit"|"none"|"held", ... } or null
  property var card: null
  property string lastOkAddress: ""
  property var snoozed: ({})

  Timer {
    id: guardTimer
    interval: 1200
    onTriggered: root.guardCheck()
  }

  Timer {
    id: cardTimeout
    interval: 6000
    onTriggered: {
      if (!root.card || !root.card.autoClose) return
      if (root.cardHovered) restart()
      else root.card = null
    }
  }

  // A focus card that pushes out a suggestion or the summary gives it back:
  // it can show again later, instead of being lost for the day or the week.
  property var shownCard: null
  onCardChanged: {
    var before = root.shownCard
    root.shownCard = root.card
    if (root.card && root.card.autoClose) cardTimeout.restart()
    if (before && root.isFocusCard(root.card)) {
      if (before.kind === "suggest" && !before.busy) activityItem.saved.suggestedOn = ""
      if (before.kind === "summary") activityItem.saved.summaryWeek = ""
    }
  }

  function snooze(key, minutes) {
    var next = Object.assign({}, root.snoozed)
    next[key] = Date.now() + minutes * 60000
    root.snoozed = next
  }

  function siteMode(title, preferId) {
    var t = String(title || "").toLowerCase()
    var found = null
    for (var i = 0; i < root.modes.length; i++) {
      var sites = root.listOf(root.modes[i].sites)
      for (var j = 0; j < sites.length; j++) {
        if (sites[j] && t.indexOf(String(sites[j]).toLowerCase()) >= 0) {
          if (root.modes[i].id === preferId) return root.modes[i]
          if (!found) found = root.modes[i]
        }
      }
    }
    return found
  }

  function cleanTitle(title, entry) {
    var t = String(title || "")
    var name = entry ? String(entry.name || "") : ""
    // "Page — Helium" → "Page"
    t = t.replace(/\s+[-—–]\s+[^-—–]+$/, "")
    return t || name
  }

  // A card with buttons stays until it's answered (or closed with ×).
  property bool cardHovered: false

  // Focus cards replace each other and Petal's quieter cards (a suggestion,
  // the summary), never a held notification or an update.
  function isFocusCard(c) {
    return !!c && ["guard", "fit", "none"].indexOf(c.kind) >= 0
  }

  function clearFocusCard() {
    if (root.isFocusCard(root.card)) root.card = null
  }

  function guardCheck() {
    if (!root.settings.modes || !root.settings.focusGuard) return
    if (root.card && ["fit", "suggest", "summary", "done"].indexOf(root.card.kind) < 0) return
    var t = Hyprland.activeToplevel
    if (!t || !t.wayland || !t.workspace) return
    var wsId = t.workspace.id
    if (!(wsId >= 1)) return
    var mode = root.modeForWorkspace(wsId)
    if (!mode || !(Number(mode.focusDelay || 0) > 0)) {
      root.clearFocusCard()
      return
    }
    var entry = root.entryForAppId(t.wayland.appId)
    var key = entry ? entry.id : String(t.wayland.appId)
    var name = entry ? String(entry.name || key) : key
    var browser = root.isBrowser(entry)
    var rawTitle = String(t.title || "")
    var title = browser ? root.cleanTitle(rawTitle, entry) : name
    var address = String(t.address)
    var snoozeKey = address + "|" + (browser ? title : "")

    var ok = function() {
      root.lastOkAddress = address
      root.clearFocusCard()
    }

    if (browser && /^(new tab|untitled|about:blank|)$/i.test(title)) return ok()
    if ((root.snoozed[snoozeKey] || 0) > Date.now()) return

    var owner = null
    if (browser) {
      owner = root.siteMode(rawTitle, mode.id)
      if (!owner && root.listOf(mode.sites).length === 0 && root.listOf(mode.apps).indexOf(key) >= 0) return ok()
    } else {
      if (root.listOf(mode.apps).concat(root.listOf(mode.allow)).indexOf(key) >= 0) return ok()
      owner = root.modeOwning(key, "")
    }

    var icon = root.iconFor({ key: key })
    if (owner && owner.id === mode.id) return ok()
    if (owner) {
      root.card = { kind: "guard", title: title, icon: icon, app: key, target: owner.id, ws: wsId, mode: mode.id, snoozeKey: snoozeKey, address: address }
      return
    }
    if (!brain.enabled) return
    var subject = browser ? name + " tab" : name
    brain.classifyWindow(subject, browser ? title : (name + " — " + rawTitle), function(r) {
      // Only if that window is still in front.
      var now = Hyprland.activeToplevel
      if (!r || !now || String(now.address) !== address) return
      // Only speak up when it clearly belongs to another mode.
      if (r.mode && r.mode !== mode.id && root.modeById(r.mode)) {
        root.card = { kind: "guard", title: title, icon: icon, app: key, target: r.mode, ws: wsId, mode: mode.id, reason: String(r.reason || ""), snoozeKey: snoozeKey, address: address }
      } else {
        root.lastOkAddress = address
      }
    })
  }

  // Card buttons
  function cardClose() {
    var c = root.card
    root.card = null
    if (c && c.snoozeKey) root.snooze(c.snoozeKey, 10)
    activityItem.cardAnswer("close", c)
  }

  // The quiet button: "Go back", "Later", "Not now", "OK".
  function cardStay() {
    var c = root.card
    if (c && c.kind === "suggest" && c.busy) return
    root.card = null
    if (!c) return
    if (c.kind === "suggest") {
      Quickshell.execDetached(["python3", activityItem.mcp, "--cli", "dismiss", String(c.s.key)])
      return
    }
    if (c.snoozeKey) root.snooze(c.snoozeKey, 10)
    if (c.kind === "guard") activityItem.cardAnswer("back", c)
    if (c.kind === "guard" || c.kind === "none") {
      if (root.lastOkAddress && root.lastOkAddress !== c.address) root.focusAddress(root.lastOkAddress)
    }
  }

  // The colored button: "Switch to …", "Make it", "Keep it", "More".
  function cardGo() {
    var c = root.card
    if (c && c.kind === "suggest") {
      root.acceptSuggestion(c)
      return
    }
    root.card = null
    if (c && c.kind === "summary") {
      root.openPanel("summary")
      return
    }
    if (!c || !c.target) return
    var ws = c.ws || root.focusedWorkspaceId
    if (c.snoozeKey) root.snooze(c.snoozeKey, 10)
    if (c.kind === "guard") activityItem.cardAnswer("switch", c)
    root.requestMode(ws, c.target)
  }

  // ── Suggested modes ───────────────────────────────────────────────────
  function namesText(names) {
    var n = root.listOf(names)
    return n.length <= 1 ? (n[0] || "") : n.slice(0, -1).join(", ") + " and " + n[n.length - 1]
  }

  function acceptSuggestion(c) {
    var s = c.s
    if (c.busy) return
    if (s.kind === "add") {
      root.setPinned(s.app, true, s.mode)
      root.card = { kind: "done", icon: c.icon, title: s.name + " is in " + s.modeName + " now.", body: "", autoClose: true }
      return
    }
    var apps = root.listOf(s.apps).filter(function(a) { return !!DesktopEntries.byId(a) })
    var fallback = { name: String(s.name || "") || "New mode", icon: "●", color: "#ff5fae", about: "" }
    if (!brain.enabled) {
      root.makeMode(fallback, apps, c)
      return
    }
    root.card = Object.assign({}, c, { busy: true })
    brain.nameMode(root.listOf(s.names), function(r) {
      var m = Object.assign({}, fallback)
      if (r) {
        if (r.name && String(r.name).trim()) m.name = String(r.name).trim().slice(0, 24)
        var icon = String(r.icon || "").trim()
        if (icon && icon.length <= 2 && /[^\x00-\x7f]/.test(icon)) m.icon = icon
        if (/^#[0-9a-fA-F]{6}$/.test(String(r.color || ""))) m.color = String(r.color)
        if (r.about) m.about = String(r.about).slice(0, 120)
      }
      root.makeMode(m, apps, c)
    })
  }

  function makeMode(m, apps, c) {
    var data = root.cloneModes()
    var base = String(m.name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "mode"
    var id = base
    var taken = data.modes.map(function(x) { return x.id })
    for (var n = 2; taken.indexOf(id) >= 0; n++) id = base + "-" + n
    data.modes.push({ id: id, name: m.name, icon: m.icon, color: m.color, about: m.about, apps: apps, sites: [], focusDelay: 0, hold: false, allow: [] })
    root.saveModes(data)
    if (!root.card || root.card.kind === "suggest")
      root.card = { kind: "done", icon: c.icon, title: "Made " + m.name + ".", body: "With " + root.namesText(c.s.names) + ". Right-click it in the dock to change it.", autoClose: true }
  }

  function cardAllow() {
    var c = root.card
    root.card = null
    if (!c) return
    if (c.key && c.mode) root.setPinned(c.key, true, c.mode)
    else if (c.snoozeKey) root.snooze(c.snoozeKey, 60)
  }

  // ── AI apps: the user's own Claude Code and Codex installs ────────────
  readonly property var providers: {
    var list = settingsAdapter.aiProviders || []
    var out = []
    for (var i = 0; i < list.length; i++)
      if ((list[i] === "claude" || list[i] === "codex") && out.indexOf(list[i]) < 0) out.push(list[i])
    return out
  }
  readonly property string chatProvider: providers.indexOf(settingsAdapter.chatProvider) >= 0 ? settingsAdapter.chatProvider : (providers.length ? providers[0] : "")
  readonly property string chatName: providerName(chatProvider)
  function providerName(p) { return p === "codex" ? "Codex" : p === "claude" ? "Claude" : "AI" }
  function providerPath(p) { return p === "codex" ? settingsAdapter.codexPath : p === "claude" ? settingsAdapter.claudePath : "" }
  function providerMark(p) { return Qt.resolvedUrl(p === "codex" ? "assets/openai.svg" : "assets/claude.svg") }
  onChatProviderChanged: root.refreshUsage(root.chatProvider)
  onProvidersChanged: { root.refreshUsage(); root.loadCodexModels() }

  // ── Usage (Omarchy's collectors read each CLI's own login) ─────────────
  // Kept per AI, so switching shows the right one straight away; the checks
  // run one at a time, each for the AI it was started for.
  property var usageBy: ({})
  readonly property var usage: root.usageBy[root.chatProvider] || null
  property string usageFor: ""
  property var usageQueue: []
  readonly property real usageWorst: {
    var limits = root.usage && root.usage.limits ? root.usage.limits : []
    var worst = -1
    for (var i = 0; i < limits.length; i++) worst = Math.max(worst, Number(limits[i].percent))
    return worst
  }

  // refreshUsage(): every chosen AI, the chat's first; refreshUsage(p): just p.
  function refreshUsage(p) {
    if (!root.settings.claudeUsage || !root.chatProvider) return
    var want = p ? [p] : [root.chatProvider].concat(root.providers.filter(function(x) { return x !== root.chatProvider }))
    var queue = root.usageQueue.slice()
    want.forEach(function(x) {
      if (x && queue.indexOf(x) < 0 && !(usageProc.running && root.usageFor === x)) queue.push(x)
    })
    root.usageQueue = queue
    root.nextUsage()
  }

  function nextUsage() {
    if (usageProc.running || root.usageQueue.length === 0) return
    var queue = root.usageQueue.slice()
    root.usageFor = queue.shift()
    root.usageQueue = queue
    usageProc.command = ["omarchy-agent-usage-" + root.usageFor, "--limits-only"]
    usageProc.running = true
  }

  Process {
    id: usageProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var u = JSON.parse(text)
          if (u && u.ready !== false) {
            var next = Object.assign({}, root.usageBy)
            next[root.usageFor] = u
            root.usageBy = next
          }
        } catch (e) {}
      }
    }
    onExited: Qt.callLater(root.nextUsage)
  }

  // Which model Codex uses when Petal names none: its own config's `model`
  // (~/.codex/config.toml, top level), else the first model it lists.
  property string codexConfigText: ""
  FileView {
    path: root.home + "/.codex/config.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.codexConfigText = text()
  }
  readonly property string codexDefault: {
    var top = root.codexConfigText.split(/^\s*\[/m)[0]
    var m = /^\s*model\s*=\s*"([^"]+)"/m.exec(top)
    return m ? m[1] : (root.codexModels.length ? root.codexModels[0].id : "")
  }

  // ── Codex's models, from Codex itself (`codex debug models`) ───────────
  // [{ id, name, efforts: [...] }], in Codex's own order, listed ones only.
  property var codexModels: []

  function loadCodexModels() {
    if (root.providers.indexOf("codex") < 0 || !settingsAdapter.codexPath || codexModelsProc.running) return
    codexModelsProc.running = true
  }

  Process {
    id: codexModelsProc
    command: [settingsAdapter.codexPath, "debug", "models"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var list = (JSON.parse(text).models || []).filter(function(m) { return m.visibility === "list" })
          list.sort(function(a, b) { return (a.priority || 0) - (b.priority || 0) })
          root.codexModels = list.map(function(m) {
            return { id: m.slug, name: m.display_name || m.slug,
                     efforts: (m.supported_reasoning_levels || []).map(function(l) { return l.effort }) }
          })
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: root.loadCodexModels()
  }

  Timer {
    interval: 5 * 60 * 1000
    repeat: true
    running: root.settings.claudeUsage && root.chatProvider !== ""
    triggeredOnStart: true
    onTriggered: root.refreshUsage()
  }

  // "2026-11-02" -> "Nov 2", in the language Omarchy is set to.
  function shortDay(iso) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ""))
    if (!m) return ""
    var locale = Commons.I18n.formatLocale ? Qt.locale(Commons.I18n.formatLocale) : Qt.locale()
    return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])).toLocaleDateString(locale, "MMM d")
  }

  function untilText(iso) {
    var t = Date.parse(iso)
    if (!(t > 0)) return ""
    var mins = Math.max(0, Math.round((t - Date.now()) / 60000))
    if (mins < 60) return mins + "m"
    var h = Math.floor(mins / 60)
    if (h < 48) return h + "h " + (mins % 60) + "m"
    return Math.round(h / 24) + "d"
  }

  // ── Updates (GitHub Releases) ──────────────────────────────────────────
  // A little after start and every 6 hours, `petal update --auto` installs a
  // newer release if there is one (source checkouts are left alone); a card
  // then offers to restart the shell to load it.
  Process {
    id: updateProc
    command: [root.home + "/.local/bin/petal", "update", "--auto"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(String(text).trim().split("\n").pop())
          if (r.status === "updated") root.card = { kind: "update", title: "Petal " + r.version, version: r.version, icon: Qt.resolvedUrl("assets/petal.svg") }
          // A release that couldn't take the person's own changes to Petal's code: they keep theirs (petal personal).
          else if (r.status === "kept" && !r.again) root.personalNotice(r.version, r.message || "")
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 6 * 60 * 60 * 1000
    repeat: true
    running: settingsAdapter.autoUpdate
    onTriggered: if (!updateProc.running) updateProc.running = true
  }

  Timer {
    interval: 2 * 60 * 1000
    running: settingsAdapter.autoUpdate
    onTriggered: if (!updateProc.running) updateProc.running = true
  }

  function restartShell() {
    // `petal restart`, which also checks the dock comes back when the person has changed Petal's code.
    Util.execDetached(Util.shellQuote(root.home + "/.local/bin/petal") + " restart")
  }

  function personalNotice(version, message) {
    root.card = { kind: "kept", title: "Petal " + version, version: version, message: message, icon: Qt.resolvedUrl("assets/petal.svg") }
  }

  // ── Claude chat (the Claude panel) ─────────────────────────────────────
  property alias chat: agent

  Agent {
    id: agent
    dock: root
  }

  // ── Recent files per app (from ~/.local/share/recently-used.xbel) ─────
  property var recentByApp: ({})

  FileView {
    id: recentFile
    path: root.home + "/.local/share/recently-used.xbel"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseRecent(text())
  }

  function decodeXml(s) {
    return String(s).replace(/&quot;/g, "\"").replace(/&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
  }

  function parseRecent(xml) {
    var out = {}
    var re = /<bookmark\s[^>]*href="([^"]+)"[\s\S]*?<\/bookmark>/g
    var m
    while ((m = re.exec(String(xml || ""))) !== null) {
      var href = root.decodeXml(m[1])
      if (href.indexOf("file://") !== 0) continue
      var appRe = /<bookmark:application\s+name="([^"]*)"\s+exec="([^"]*)"\s+modified="([^"]*)"/g
      var a
      while ((a = appRe.exec(m[0])) !== null) {
        var exec = root.decodeXml(a[2]).replace(/^'|'$/g, "").split(/\s+/)[0]
        var names = [a[1].toLowerCase(), exec.slice(exec.lastIndexOf("/") + 1).toLowerCase()]
        names.forEach(function(nm) {
          if (!nm) return
          ;(out[nm] = out[nm] || []).push({ url: href, at: a[3] })
        })
      }
    }
    for (var k in out) out[k].sort(function(x, y) { return x.at < y.at ? 1 : -1 })
    root.recentByApp = out
  }

  function recentFilesFor(key) {
    if (!root.settings.recentFiles) return []
    var entry = DesktopEntries.byId(key)
    if (!entry) return []
    var program = root.execKey(entry)
    var names = [String(entry.name || "").toLowerCase(), program.slice(program.lastIndexOf("/") + 1).toLowerCase(), String(key).toLowerCase()]
    var seen = {}
    var out = []
    names.forEach(function(nm) {
      (root.recentByApp[nm] || []).forEach(function(r) {
        if (seen[r.url] || out.length >= 6) return
        seen[r.url] = true
        out.push(r.url)
      })
    })
    return out
  }

  // ── Folders, trash, search ────────────────────────────────────────────
  function expandPath(path) {
    var p = String(path || "")
    return p.indexOf("~/") === 0 ? root.home + p.slice(1) : p
  }

  function tildePath(path) {
    var p = String(path || "")
    return p.indexOf(root.home + "/") === 0 ? "~" + p.slice(root.home.length) : p
  }

  function openPath(path) {
    Util.execDetached("xdg-open " + Util.shellQuote(root.expandPath(path)))
  }

  function hasStack(path) {
    return root.listOf(settingsAdapter.stackFolders).indexOf(root.tildePath(root.expandPath(path))) >= 0
  }

  function addStack(path) {
    var p = root.tildePath(root.expandPath(path))
    if (!root.hasStack(p)) settingsAdapter.stackFolders = root.listOf(settingsAdapter.stackFolders).concat([p])
  }

  function removeStack(path) {
    var p = root.tildePath(root.expandPath(path))
    settingsAdapter.stackFolders = root.listOf(settingsAdapter.stackFolders).filter(function(x) { return x !== p })
  }

  function openTrash() {
    Util.execDetached("gio open trash:///")
  }

  function emptyTrash() {
    Util.execDetached("gio trash --empty")
  }

  function trashUrls(urls) {
    var paths = root.listOf(urls).map(function(u) { return decodeURIComponent(u.replace(/^file:\/\//, "")) })
    if (paths.length) Quickshell.execDetached(["gio", "trash"].concat(paths))
  }

  readonly property bool searchOpen: appSearch.open || askBox.open || petalPanel.open

  function openSearch() {
    appSearch.open = true
  }

  function openAsk(prefill) {
    petalPanel.open = false
    root.refreshUsage()
    askBox.describing = false
    askBox.prefill = prefill || ""
    askBox.open = true
  }

  // "Describe your day": the chat builds the modes from a few words.
  function openDescribe() {
    if (!root.chatProvider) {
      root.openPanel("")
      return
    }
    root.openAsk("")
    askBox.describing = true
  }

  // The Petal menu (from Omarchy's bar, Omarchy's menu or `petal panel`).
  function openPanel(page) {
    appSearch.open = false
    askBox.open = false
    petalPanel.page = page === "home" ? "" : (page || "")
    petalPanel.open = true
  }

  AppSearch {
    id: appSearch
    dock: root
  }

  AskBox {
    id: askBox
    dock: root
  }

  Brain {
    id: brain
    dock: root
  }

  PetalPanel {
    id: petalPanel
    dock: root
  }

  // The activity history, suggestions, the weekly summary, schedules.
  property alias activity: activityItem

  Activity {
    id: activityItem
    dock: root
  }

  // Shortcuts and each mode's Hyprland look.
  Hypr {
    id: hyprItem
    dock: root
  }


  Variants {
    id: docks
    model: Quickshell.screens

    delegate: Component {
      DockWindow {
        required property var modelData
        screen: modelData
        dock: root
      }
    }
  }

  function withDock(fn) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) fn(windows[i])
  }

  // ── Remote control:  omarchy-shell petal <method> [arg] ───────────────
  ShellIpc {
    target: "petal"

    function search(): void { root.openSearch() }
    function ask(): void { root.openAsk("") }
    function settings(): void { root.withDock(function(w) { w.revealed = true; w.openSettingsMenu(null) }) }
    function mode(id: string): void { root.requestMode(root.focusedWorkspaceId, id) }
    function stay(): void { root.stay() }
    function current(): string { return root.focusedModeId }
    function stack(index: int): void { root.withDock(function(w) { w.revealed = true; w.toggleStack(root.expandPath(settingsAdapter.stackFolders[index]), null) }) }
    function reveal(): void { root.withDock(function(w) { w.revealed = true }) }
    function check(): void { root.guardCheck() }
    function testCard(kind: string): void {
      root.card = { kind: kind || "guard", title: "x.com", icon: root.iconFor({ key: "X" }), target: "social", ws: root.focusedWorkspaceId, mode: root.focusedModeId,
        reason: "Social feed, not work", n: { app: "Slack", summary: "Maya Chen", body: "can you sign off on the launch post?" } }
    }
    function testAi(title: string): void {
      brain.classifyWindow("Helium tab", title, function(r, error) {
        console.log("petal testAi", JSON.stringify(r), error)
        if (r) root.card = { kind: r.mode && r.mode !== root.focusedModeId ? "guard" : (r.mode ? "fit" : "none"), title: title, icon: root.iconFor({ key: "helium" }),
          target: r.mode || "", ws: root.focusedWorkspaceId, mode: root.focusedModeId, reason: String(r.reason || "") }
      })
    }
    function chat(text: string): void { root.openAsk(""); agent.send(text) }
    function modeAt(n: int): void { var m = root.modes[n - 1]; if (m) root.requestMode(root.focusedWorkspaceId, m.id) }
    function panel(page: string): void { root.openPanel(page) }
    function describe(): void { root.openDescribe() }
    function held(): void { root.openPanel("held") }
    function summary(): void { root.openPanel("summary") }
    function testSuggest(): void {
      activityItem.tool("petal_suggestions", {}, function(r) {
        var s = r && r.suggestions && r.suggestions.length ? r.suggestions[0]
          : { kind: "new", key: "test", apps: ["com.mitchellh.ghostty"], names: ["Ghostty", "Linear"], name: "Design", text: "You often use Ghostty and Linear together. Make a Design mode?" }
        root.card = { kind: "suggest", s: s, icon: root.iconFor({ key: s.kind === "add" ? s.app : s.apps[0] }) }
      })
    }
    function testSummary(): void {
      activityItem.tool("petal_summary", {}, function(r) { if (r && !r.error) root.card = { kind: "summary", data: r, icon: Qt.resolvedUrl("assets/petal.svg") } })
    }
    function personalNotice(version: string, message: string): void { root.personalNotice(version, message) }
    function allow(): void { agent.allow() }
    function testNoWarp(): void { root.withoutWarp("true") }
    function options(): void { root.openAsk(""); askBox.optionsOpen = true }
    function newChat(): void { agent.reset() }
    function emptyTrash(): void { root.emptyTrash() }
    function testToast(): void { root.showToast({ app: "Petal", summary: "Hello", body: "This came through your mode", key: "", icon: "" }) }
    function testBounce(key: string): void { var next = Object.assign({}, root.bounces); next[key] = Date.now(); root.bounces = next }
    function close(): void {
      appSearch.open = false
      askBox.open = false
      petalPanel.open = false
      root.card = null
      root.withDock(function(w) { w.closeMenu(); w.closeStack(); w.hidePreview() })
    }
  }
}
