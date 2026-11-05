import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
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

  readonly property string position: DockModel.normalizePosition(dockConfig.position)
  readonly property bool vertical: DockModel.isVertical(position)
  readonly property bool autohide: dockConfig.autohide === true

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
      // Modes and AI
      property bool modes: true
      property bool focusGuard: true
      property bool countdown: false
      property bool holdNotifications: true
      property bool ai: true
      property bool claudeUsage: true
      property string claudePath: ""
      // The Claude panel's chat (Claude Code CLI): model alias, effort
      // (low … max), and access: "auto" (Claude Code's auto mode: safe actions
      // run on their own, risky ones ask) or "full" (bypass permissions).
      property string chatModel: "sonnet"
      property string chatEffort: "medium"
      property string claudeAccess: "auto"
    }
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
    Util.execDetached("uwsm-app -- " + Util.shellQuote(entry.id + ".desktop"))
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
    Quickshell.execDetached(["uwsm-app", "--"].concat(args))
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
    Util.execDetached(command)
  }

  function minimize(window) {
    var a = String(window.address || "")
    if (a.indexOf("0x") !== 0) a = "0x" + a
    Util.execDetached("omarchy-hyprland-window-minimize " + Util.shellQuote(a))
  }

  function focusAddress(address) {
    var target = root.dispatchFor(address)
    if (target) Util.execDetached("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ " + target + " })"))
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

  function heldCount(modeId) {
    return (root.held[modeId] || []).length
  }

  function clearHeld(modeId) {
    if (!root.held[modeId]) return
    var next = Object.assign({}, root.held)
    delete next[modeId]
    root.held = next
  }

  function holdFor(modeId, n) {
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

  onCardChanged: if (root.card && root.card.autoClose) cardTimeout.restart()

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

  function guardCheck() {
    if (!root.settings.modes || !root.settings.focusGuard) return
    if (root.card && root.card.kind !== "fit") return
    var t = Hyprland.activeToplevel
    if (!t || !t.wayland || !t.workspace) return
    var wsId = t.workspace.id
    if (!(wsId >= 1)) return
    var mode = root.modeForWorkspace(wsId)
    if (!mode || !(Number(mode.focusDelay || 0) > 0)) {
      if (root.card && root.card.kind !== "held") root.card = null
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
      if (root.card && root.card.kind !== "held") root.card = null
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
      root.card = { kind: "guard", title: title, icon: icon, target: owner.id, ws: wsId, mode: mode.id, snoozeKey: snoozeKey, address: address }
      return
    }
    if (!brain.enabled) return
    var subject = browser ? name + " tab" : name
    brain.classifyWindow(subject, browser ? title : (name + " — " + rawTitle), function(r) {
      // Only if that window is still in front.
      var now = Hyprland.activeToplevel
      if (!r || !now || String(now.address) !== address) return
      if (r.mode === mode.id) {
        root.lastOkAddress = address
        root.card = { kind: "fit", title: title, icon: icon, target: mode.id, mode: mode.id, reason: String(r.reason || ""), key: browser ? "" : key, autoClose: browser }
      } else if (r.mode && root.modeById(r.mode)) {
        root.card = { kind: "guard", title: title, icon: icon, target: r.mode, ws: wsId, mode: mode.id, reason: String(r.reason || ""), snoozeKey: snoozeKey, address: address }
      } else {
        root.card = { kind: "none", title: title, icon: icon, ws: wsId, mode: mode.id, reason: String(r.reason || ""), snoozeKey: snoozeKey, address: address, key: browser ? "" : key }
      }
    })
  }

  // Card buttons
  function cardClose() {
    var c = root.card
    root.card = null
    if (c && c.snoozeKey) root.snooze(c.snoozeKey, 10)
  }

  function cardStay() {
    var c = root.card
    root.card = null
    if (!c) return
    if (c.snoozeKey) root.snooze(c.snoozeKey, 10)
    if (c.kind === "guard" || c.kind === "none") {
      if (root.lastOkAddress && root.lastOkAddress !== c.address) root.focusAddress(root.lastOkAddress)
    }
  }

  function cardGo() {
    var c = root.card
    root.card = null
    if (!c || !c.target) return
    var ws = c.ws || root.focusedWorkspaceId
    if (c.snoozeKey) root.snooze(c.snoozeKey, 10)
    root.requestMode(ws, c.target)
  }

  function cardAllow() {
    var c = root.card
    root.card = null
    if (!c) return
    if (c.key && c.mode) root.setPinned(c.key, true, c.mode)
    else if (c.snoozeKey) root.snooze(c.snoozeKey, 60)
  }

  // ── Claude Code usage (Omarchy's collector reads the CLI's own login) ──
  property var usage: null
  readonly property real usageWorst: {
    var limits = root.usage && root.usage.limits ? root.usage.limits : []
    var worst = -1
    for (var i = 0; i < limits.length; i++) worst = Math.max(worst, Number(limits[i].percent))
    return worst
  }

  function refreshUsage() {
    if (!root.settings.claudeUsage || usageProc.running) return
    usageProc.running = true
  }

  Process {
    id: usageProc
    command: ["omarchy-agent-usage-claude", "--limits-only"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var u = JSON.parse(text)
          if (u && u.ready !== false) root.usage = u
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 5 * 60 * 1000
    repeat: true
    running: root.settings.claudeUsage
    triggeredOnStart: true
    onTriggered: root.refreshUsage()
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

  // ── Claude chat (the Claude panel) ─────────────────────────────────────
  property alias chat: agent

  Agent {
    id: agent
    dock: root
    claudePath: settingsAdapter.claudePath
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

  readonly property bool searchOpen: appSearch.open || askBox.open

  function openSearch() {
    appSearch.open = true
  }

  function openAsk(prefill) {
    root.refreshUsage()
    askBox.prefill = prefill || ""
    askBox.open = true
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
    claudePath: settingsAdapter.claudePath
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
    function allow(): void { agent.allow() }
    function options(): void { root.openAsk(""); askBox.optionsOpen = true }
    function newChat(): void { agent.reset() }
    function emptyTrash(): void { root.emptyTrash() }
    function testToast(): void { root.showToast({ app: "Petal", summary: "Hello", body: "This came through your mode", key: "", icon: "" }) }
    function testBounce(key: string): void { var next = Object.assign({}, root.bounces); next[key] = Date.now(); root.bounces = next }
    function close(): void {
      appSearch.open = false
      askBox.open = false
      root.card = null
      root.withDock(function(w) { w.closeMenu(); w.closeStack(); w.hidePreview() })
    }
  }
}
