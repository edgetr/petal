import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

// Petal's private, local history, and what it does with it: suggested modes,
// the weekly summary and schedules. Once a minute while you're at the
// computer it notes which app is in front, in which mode and workspace (never
// window titles, URLs or file names), in ~/.local/state/petal/activity.jsonl.
// 30 days are kept; nothing leaves the machine. petal-mcp.py reads it back
// (petal_suggestions, petal_summary), so Claude, `petal` and the dock agree.
Item {
  id: activity

  property var dock: null
  readonly property var settings: dock ? dock.settings : null
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/petal"
  readonly property string logFile: stateDir + "/activity.jsonl"
  readonly property string mcp: String(Qt.resolvedUrl("mcp/petal-mcp.py")).replace(/^file:\/\//, "")
  readonly property string petalBin: home + "/.local/bin/petal"
  readonly property bool logging: !!settings && settings.activityLog
  // Input in the last two minutes.
  readonly property bool present: !idle.isIdle
  property alias saved: petalState
  // Petal's state file has been read (or found missing): until then, what
  // already happened (a schedule block applied today) isn't known.
  property bool savedLoaded: false

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", activity.stateDir])
    if (activity.logging) Quickshell.execDetached(["python3", activity.mcp, "--cli", "prune"])
  }

  // What Petal remembers between runs: when it last showed a suggestion and
  // the summary, which schedule blocks it already applied, and the Hyprland
  // values a mode's look replaced (Hypr.qml).
  FileView {
    id: stateFile
    path: activity.stateDir + "/state.json"
    printErrors: false
    onAdapterUpdated: writeAdapter()
    onLoaded: activity.savedLoaded = true
    onLoadFailed: activity.savedLoaded = true

    JsonAdapter {
      id: petalState
      property string suggestedOn: ""
      property string summaryWeek: ""
      property var scheduleFired: []
      property var lookOriginals: null
      property bool lookApplied: false
    }
  }

  IdleMonitor {
    id: idle
    enabled: activity.logging
    timeout: 120
    respectInhibitors: false
  }

  function today() {
    return Qt.formatDate(new Date(), "yyyy-MM-dd")
  }

  function nowSeconds() {
    return Math.floor(Date.now() / 1000)
  }

  function append(row) {
    if (!activity.logging) return
    Quickshell.execDetached(["bash", "-c", "mkdir -p \"$(dirname \"$2\")\" && printf '%s\\n' \"$1\" >> \"$2\"",
      "petal", JSON.stringify(row), activity.logFile])
  }

  // ── The history ───────────────────────────────────────────────────────
  Timer {
    interval: 60 * 1000
    repeat: true
    running: activity.logging
    onTriggered: activity.tick()
  }

  function tick() {
    if (!activity.dock || idle.isIdle) return
    var t = Hyprland.activeToplevel
    if (!t || !t.wayland || !t.workspace || !(t.workspace.id >= 1)) return
    var key = activity.dock.activeKey
    if (!key) return
    activity.append({ t: activity.nowSeconds(), app: key, mode: activity.dock.modeIdForWorkspace(t.workspace.id), ws: t.workspace.id })
  }

  // A focus card's answer: "back", "switch" or "close".
  function cardAnswer(answer, c) {
    if (!c || c.kind !== "guard") return
    activity.append({ t: activity.nowSeconds(), card: answer, app: String(c.app || ""), mode: String(c.mode || "") })
  }

  // ── Running Petal's own tools (petal-mcp.py, petal doctor) ─────────────
  property var jobs: []
  property var job: null

  // run(command, done): done(stdout, exitCode)
  function run(command, done) {
    activity.jobs.push({ command: command, done: done })
    activity.next()
  }

  // tool(name, args, done): done(result | null), the tool's JSON answer.
  function tool(name, args, done) {
    activity.run(["python3", activity.mcp, "--tool", name, JSON.stringify(args || {})], function(text) {
      var r = null
      try { r = JSON.parse(String(text || "").trim().split("\n").pop()) } catch (e) {}
      done(r)
    })
  }

  function next() {
    if (jobProc.running || activity.jobs.length === 0) return
    activity.job = activity.jobs.shift()
    jobProc.command = activity.job.command
    jobProc.running = true
  }

  Process {
    id: jobProc
    stdout: StdioCollector { id: jobOut }
    onExited: function(code) {
      var j = activity.job
      activity.job = null
      if (j && j.done) {
        try { j.done(String(jobOut.text || ""), code) } catch (e) { console.warn("petal tool:", e) }
      }
      Qt.callLater(activity.next)
    }
  }

  // ── Suggested modes: at most one card a day ────────────────────────────
  readonly property bool cardFree: !!dock && !dock.card && !dock.pending && !dock.searchOpen

  Timer {
    interval: 20 * 60 * 1000
    repeat: true
    running: activity.logging && !!activity.settings && activity.settings.suggestModes
    onTriggered: activity.maybeSuggest()
  }

  Timer {
    interval: 3 * 60 * 1000
    running: activity.logging
    onTriggered: {
      activity.maybeSuggest()
      activity.maybeSummary()
    }
  }

  function maybeSuggest() {
    if (!activity.logging || !activity.settings.suggestModes || !activity.settings.modes) return
    if (!activity.cardFree || idle.isIdle || petalState.suggestedOn === activity.today()) return
    activity.tool("petal_suggestions", {}, function(r) {
      var list = r && r.suggestions ? r.suggestions : []
      if (list.length === 0 || !activity.cardFree) return
      var s = list[0]
      petalState.suggestedOn = activity.today()
      activity.dock.card = { kind: "suggest", s: s, icon: activity.dock.iconFor({ key: s.kind === "add" ? s.app : s.apps[0] }) }
    })
  }

  // ── The weekly summary: the first time you're here after 9:00 on Monday ─
  Timer {
    interval: 10 * 60 * 1000
    repeat: true
    running: activity.logging && !!activity.settings && activity.settings.summary
    onTriggered: activity.maybeSummary()
  }

  function mondayKey() {
    var now = new Date()
    var back = (now.getDay() + 6) % 7
    var monday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - back, 9, 0, 0)
    return now < monday ? "" : Qt.formatDate(monday, "yyyy-MM-dd")
  }

  function maybeSummary() {
    if (!activity.logging || !activity.settings.summary || !activity.cardFree || idle.isIdle) return
    var week = activity.mondayKey()
    if (!week || petalState.summaryWeek === week) return
    activity.tool("petal_summary", {}, function(r) {
      if (!r || r.error) return
      if (!(r.minutes > 0)) {
        petalState.summaryWeek = week
        return
      }
      if (!activity.cardFree) return
      petalState.summaryWeek = week
      activity.dock.card = { kind: "summary", data: r, icon: Qt.resolvedUrl("assets/petal.svg") }
    })
  }

  // ── Schedules: when a block starts, the focused workspace takes its mode ─
  Timer {
    interval: 30 * 1000
    repeat: true
    triggeredOnStart: true
    running: activity.savedLoaded && !!activity.settings && activity.scheduleBlocks().length > 0
    onTriggered: activity.checkSchedule()
  }

  function scheduleBlocks() {
    var s = activity.settings ? activity.settings.schedule : null
    var out = []
    for (var i = 0; i < (s ? s.length : 0); i++) if (s[i] && s[i].mode) out.push(s[i])
    return out
  }

  function minutesOf(hhmm) {
    var m = /^(\d{1,2}):(\d{2})$/.exec(String(hhmm || "").trim())
    return m && Number(m[1]) < 24 && Number(m[2]) < 60 ? Number(m[1]) * 60 + Number(m[2]) : -1
  }

  function hasDay(days, day) {
    if (!days || days.length === 0) return true
    for (var i = 0; i < days.length; i++) if (Number(days[i]) === day) return true
    return false
  }

  // The date a block that's running now started on, or "".
  function blockStart(b, now) {
    var from = activity.minutesOf(b.from), to = activity.minutesOf(b.to)
    if (from < 0 || to < 0 || from === to) return ""
    var mins = now.getHours() * 60 + now.getMinutes()
    var day = now.getDay() === 0 ? 7 : now.getDay()
    if (to > from) return activity.hasDay(b.days, day) && mins >= from && mins < to ? Qt.formatDate(now, "yyyy-MM-dd") : ""
    // Past midnight: it began today, or yesterday.
    if (activity.hasDay(b.days, day) && mins >= from) return Qt.formatDate(now, "yyyy-MM-dd")
    var yesterday = day === 1 ? 7 : day - 1
    if (activity.hasDay(b.days, yesterday) && mins < to)
      return Qt.formatDate(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1), "yyyy-MM-dd")
    return ""
  }

  function checkSchedule() {
    if (!activity.dock) return
    var blocks = activity.scheduleBlocks()
    var now = new Date()
    var fired = activity.dock.listOf(petalState.scheduleFired)
    for (var i = 0; i < blocks.length; i++) {
      var b = blocks[i]
      if (!activity.dock.modeById(b.mode)) continue
      var start = activity.blockStart(b, now)
      if (!start) continue
      var key = start + "|" + b.from + "|" + b.to + "|" + b.mode
      if (fired.indexOf(key) >= 0) continue
      // No workspace in front yet (the shell is starting): next time.
      var ws = activity.dock.focusedWorkspaceId
      if (!(ws >= 1)) return
      fired.push(key)
      petalState.scheduleFired = fired.slice(-30)
      activity.dock.applyMode(ws, b.mode)
    }
  }

  // "Mon–Fri 09:00–12:00", for the Petal menu.
  function describeBlock(b) {
    var names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    var days = []
    for (var i = 0; i < (b.days ? b.days.length : 0); i++) {
      var d = Number(b.days[i])
      if (d >= 1 && d <= 7 && days.indexOf(d) < 0) days.push(d)
    }
    days.sort()
    var text
    if (days.length === 0 || days.length === 7) text = "Every day"
    else if (days.join() === "1,2,3,4,5") text = "Weekdays"
    else if (days.join() === "6,7") text = "Weekends"
    else {
      var run = days.length > 2 && days[days.length - 1] - days[0] === days.length - 1
      text = run ? names[days[0] - 1] + "–" + names[days[days.length - 1] - 1] : days.map(function(x) { return names[x - 1] }).join(", ")
    }
    return text + " " + String(b.from || "") + "–" + String(b.to || "")
  }
}
