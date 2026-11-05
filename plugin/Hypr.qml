import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// What Petal does to Hyprland itself, always at runtime (`hyprctl eval`) and
// never in the user's config files, so a config reload or a restart undoes it:
//
//  - Keyboard shortcuts (setting `shortcuts`): Super+Ctrl+Alt+1…9 puts the
//    focused workspace in mode 1…9, +Space opens the AI panel, += the "+"
//    search. Only combinations nothing else uses are bound; they go away when
//    the setting turns off.
//  - A mode's look (its `hyprland` field: borderColor, gapsIn, gapsOut,
//    wallpaper) follows the workspace in front: Hyprland's border color and
//    gaps, and Omarchy's wallpaper, are set while a workspace in that mode is
//    focused, and the user's own come back when one without a look is.
Item {
  id: hypr

  property var dock: null
  readonly property bool wantShortcuts: !!dock && dock.settings.shortcuts

  // ── Shortcuts ─────────────────────────────────────────────────────────
  readonly property int modmask: 64 + 4 + 8   // SUPER + CTRL + ALT
  readonly property var combos: {
    var out = []
    for (var n = 1; n <= 9; n++)
      out.push({ key: "code:" + (n + 9), names: [String(n), "code:" + (n + 9)], code: n + 9,
        action: "omarchy-shell petal modeAt " + n, name: "Petal: mode " + n })
    out.push({ key: "space", names: ["space", "code:65"], code: 65, action: "omarchy-shell petal ask", name: "Petal: AI panel" })
    out.push({ key: "equal", names: ["equal", "code:21"], code: 21, action: "omarchy-shell petal search", name: "Petal: add apps" })
    return out
  }

  onWantShortcutsChanged: hypr.syncShortcuts()
  Component.onCompleted: startTimer.start()

  Timer {
    id: startTimer
    interval: 3000
    onTriggered: {
      hypr.syncShortcuts()
      hypr.readOriginals()
    }
  }

  // A config reload (a theme switch, an edit) drops runtime binds and puts the
  // config's own look back: bind again, and learn the user's look again.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      // Not an echo of Petal's own change a moment ago.
      if (event && String(event.name) === "configreloaded" && Date.now() - hypr.lastEval > 1500) reloadTimer.restart()
    }
  }

  Timer {
    id: reloadTimer
    interval: 600
    onTriggered: {
      hypr.dock.activity.state.lookApplied = false
      hypr.applied = null
      hypr.syncShortcuts()
      hypr.readOriginals()
    }
  }

  property bool syncAgain: false

  function syncShortcuts() {
    if (bindsProc.running) {
      hypr.syncAgain = true
      return
    }
    bindsProc.running = true
  }

  function luaString(s) {
    return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""
  }

  property double lastEval: 0

  function hyprEval(lua) {
    hypr.lastEval = Date.now()
    Quickshell.execDetached(["hyprctl", "eval", lua])
  }

  // `hyprctl binds` in plain text: Hyprland 0.56 writes invalid JSON for binds
  // (Omarchy's keybindings menu reads the plain output for the same reason).
  function parseBinds(text) {
    var binds = []
    var cur = null
    String(text || "").split("\n").forEach(function(line) {
      if (/^bind/.test(line)) {
        cur = {}
        binds.push(cur)
        return
      }
      var m = /^\t([a-z_]+): ?(.*)$/.exec(line)
      if (cur && m) cur[m[1]] = m[2]
    })
    return binds
  }

  function bindFor(binds, combo) {
    for (var i = 0; i < binds.length; i++) {
      var b = binds[i]
      if (Number(b.modmask) !== hypr.modmask || String(b.submap || "") !== "") continue
      var key = String(b.key || "").split(" + ").pop().toLowerCase()
      if (combo.names.indexOf(key) >= 0 || Number(b.keycode) === combo.code) return b
    }
    return null
  }

  Process {
    id: bindsProc
    command: ["hyprctl", "binds"]
    stdout: StdioCollector { id: bindsOut }
    onExited: function(code) {
      if (code === 0) {
        var binds = hypr.parseBinds(bindsOut.text)
        for (var i = 0; i < hypr.combos.length; i++) {
          var c = hypr.combos[i]
          var b = hypr.bindFor(binds, c)
          var ours = !!b && String(b.description || "").indexOf("Petal") === 0
          var keys = "SUPER + CTRL + ALT + " + c.key
          if (hypr.wantShortcuts && !b)
            hypr.hyprEval("hl.bind(" + hypr.luaString(keys) + ", hl.dsp.exec_cmd(" + hypr.luaString(c.action) + "), { description = " + hypr.luaString(c.name) + " })")
          else if (!hypr.wantShortcuts && ours)
            hypr.hyprEval("hl.unbind(" + hypr.luaString(keys) + ")")
        }
      }
      if (hypr.syncAgain) {
        hypr.syncAgain = false
        Qt.callLater(hypr.syncShortcuts)
      }
    }
  }

  // ── A mode's look ─────────────────────────────────────────────────────
  // The look the workspace in front asks for, or null.
  readonly property var look: {
    var m = dock ? dock.focusedMode : null
    var h = m && m.hyprland && typeof m.hyprland === "object" ? m.hyprland : null
    if (!h) return null
    var out = {}
    var color = h.borderColor === "mode" ? m.color : h.borderColor
    if (/^#[0-9a-fA-F]{6}$/.test(String(color || ""))) out.borderColor = String(color)
    if (isFinite(h.gapsIn) && h.gapsIn !== null && h.gapsIn !== "") out.gapsIn = Math.max(0, Math.min(100, Math.round(Number(h.gapsIn))))
    if (isFinite(h.gapsOut) && h.gapsOut !== null && h.gapsOut !== "") out.gapsOut = Math.max(0, Math.min(200, Math.round(Number(h.gapsOut))))
    if (h.wallpaper) out.wallpaper = dock.expandPath(String(h.wallpaper))
    return Object.keys(out).length ? out : null
  }
  readonly property string lookKey: JSON.stringify(look)
  onLookKeyChanged: lookTimer.restart()

  // The look last applied: null while the user's own is in place.
  property var applied: null
  // The wallpaper a look put up, until the theme's own is back.
  property string wallpaperSet: ""
  // The user's own values, as Lua: { gapsIn, gapsOut, border }; "" where
  // Hyprland didn't say (Petal then leaves that one alone).
  property var originals: null

  Timer {
    id: lookTimer
    interval: 250
    onTriggered: hypr.applyLook()
  }

  // While a look is applied, Hyprland's current values are Petal's, so the
  // user's own are kept in Petal's state (a restart of the shell then still
  // knows them).
  function readOriginals() {
    var saved = hypr.dock.activity.state
    if (saved.lookApplied && saved.lookOriginals) {
      hypr.originals = saved.lookOriginals
      hypr.applied = {}
      lookTimer.restart()
      return
    }
    if (!originalsProc.running) originalsProc.running = true
  }

  Process {
    id: originalsProc
    command: ["bash", "-c", "for o in general:gaps_in general:gaps_out general:col.active_border; do hyprctl getoption \"$o\" -j | jq -c .; done"]
    stdout: StdioCollector { id: originalsOut }
    onExited: function(code) {
      var lines = String(originalsOut.text || "").trim().split("\n")
      var parsed = []
      for (var i = 0; i < lines.length; i++) {
        try { parsed.push(JSON.parse(lines[i])) } catch (e) { parsed.push(null) }
      }
      if (parsed.length < 3) return
      hypr.originals = {
        gapsIn: parsed[0] ? hypr.gapsLua(parsed[0].custom) : "",
        gapsOut: parsed[1] ? hypr.gapsLua(parsed[1].custom) : "",
        border: parsed[2] ? hypr.gradientLua(parsed[2].custom) : ""
      }
      lookTimer.restart()
    }
  }

  // "5 5 5 5" -> 5; uneven sides stay as Hyprland wrote them.
  function gapsLua(custom) {
    var parts = String(custom || "").trim().split(/\s+/).filter(function(p) { return p !== "" })
    if (parts.length === 0 || !parts.every(function(p) { return /^-?\d+$/.test(p) })) return ""
    if (parts.every(function(p) { return p === parts[0] })) return parts[0]
    return hypr.luaString(parts.join(" "))
  }

  // "ee33ccff ee00ff99 45deg" (AARRGGBB) -> { colors = { "rgba(33ccffee)", … }, angle = 45 }
  function gradientLua(custom) {
    var colors = []
    var angle = null
    String(custom || "").trim().split(/\s+/).forEach(function(p) {
      if (/deg$/.test(p)) angle = Math.round(parseFloat(p))
      else if (/^[0-9a-fA-F]{1,8}$/.test(p)) {
        var h = ("00000000" + p).slice(-8)
        colors.push("\"rgba(" + h.slice(2) + h.slice(0, 2) + ")\"")
      }
    })
    if (colors.length === 0) return ""
    if (colors.length === 1 && angle === null) return colors[0]
    return "{ colors = { " + colors.join(", ") + " }" + (angle !== null && isFinite(angle) ? ", angle = " + angle : "") + " }"
  }

  // The Lua that sets what a look asks for, and puts back the rest; only
  // values whose originals are known are ever touched.
  function lookLua(want) {
    var o = hypr.originals
    var parts = []
    if (o.gapsIn) parts.push("gaps_in = " + (want.gapsIn !== undefined ? want.gapsIn : o.gapsIn))
    if (o.gapsOut) parts.push("gaps_out = " + (want.gapsOut !== undefined ? want.gapsOut : o.gapsOut))
    if (o.border) parts.push("col = { active_border = " + (want.borderColor ? "\"rgba(" + want.borderColor.slice(1) + "ff)\"" : o.border) + " }")
    return parts.length ? "hl.config({ general = { " + parts.join(", ") + " } })" : ""
  }

  function applyLook() {
    if (!hypr.dock) return
    var look = hypr.look
    var want = look || {}

    if (want.wallpaper && want.wallpaper !== hypr.wallpaperSet) {
      hypr.setWallpaper(want.wallpaper)
      hypr.wallpaperSet = want.wallpaper
    } else if (!want.wallpaper && hypr.wallpaperSet) {
      hypr.restoreWallpaper()
      hypr.wallpaperSet = ""
    }

    if (!hypr.originals || (!look && !hypr.applied)) return
    var lua = hypr.lookLua(want)
    if (lua) hypr.hyprEval(lua)
    hypr.applied = look
    var state = hypr.dock.activity.state
    state.lookOriginals = hypr.originals
    state.lookApplied = !!look
  }

  // Omarchy's wallpaper, for now: the theme's own (its current/background
  // link) is left alone, so it comes back as it was.
  function setWallpaper(path) {
    Quickshell.execDetached(["omarchy-shell", "-q", "background", "set", path])
  }

  function restoreWallpaper() {
    Quickshell.execDetached(["bash", "-c", "omarchy-shell -q background set \"$(readlink -f \"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/background\")\""])
  }

  // Leaving (the shell restarting): put the user's own look back.
  Component.onDestruction: {
    if (hypr.wallpaperSet) hypr.restoreWallpaper()
    if (!hypr.applied || !hypr.originals) return
    var lua = hypr.lookLua({})
    if (lua) hypr.hyprEval(lua)
  }
}
