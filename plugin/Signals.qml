import QtQuick
import Quickshell
import Quickshell.Io

// Listens on the session bus, without taking anything over: notifications
// on their way to Omarchy's notification center (for unread badges and
// holding), and the launcher-entry signals apps send for download/progress
// rings and their own badge counts.
Item {
  id: signals

  property var dock: null

  // key -> unread notification count
  property var unread: ({})
  // key -> { progress: 0..1 } while an app reports progress
  property var progress: ({})
  // key -> count an app asked to show on its icon
  property var counts: ({})

  signal notified(var n)

  function keyFor(desktopEntry, appName) {
    var id = String(desktopEntry || "")
    if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
    var entry = id ? (DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id)) : null
    if (!entry && appName) entry = DesktopEntries.heuristicLookup(String(appName))
    if (entry && signals.dock) entry = signals.dock.visibleTwin(entry)
    return entry ? entry.id : ""
  }

  function badgeFor(key) {
    var c = signals.counts[key]
    if (c !== undefined && c > 0) return c
    return signals.unread[key] || 0
  }

  function clear(key) {
    if (!key || !signals.unread[key]) return
    var next = Object.assign({}, signals.unread)
    delete next[key]
    signals.unread = next
  }

  function hint(hints, name) {
    var h = hints ? hints[name] : undefined
    return h && h.data !== undefined ? h.data : undefined
  }

  function handle(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (!msg || !msg.payload) return
    var data = msg.payload.data || []

    if (msg.member === "Notify" && msg.interface === "org.freedesktop.Notifications") {
      var hints = data[6] || {}
      var n = {
        app: String(data[0] || ""),
        summary: String(data[3] || ""),
        body: String(data[4] || "").replace(/<[^>]+>/g, ""),
        icon: String(data[2] || ""),
        urgency: Number(signals.hint(hints, "urgency") || 1),
        key: signals.keyFor(signals.hint(hints, "desktop-entry"), data[0]),
        at: Date.now()
      }
      // Updates to a running notification (progress, players) are not news.
      if (Number(data[1] || 0) !== 0 || signals.hint(hints, "transient") === true) return
      if (n.key && !(signals.dock && signals.dock.isFocusedKey(n.key))) {
        var next = Object.assign({}, signals.unread)
        next[n.key] = (next[n.key] || 0) + 1
        signals.unread = next
      }
      signals.notified(n)
      return
    }

    if (msg.member === "Update" && msg.interface === "com.canonical.Unity.LauncherEntry") {
      var uri = String(data[0] || "").replace(/^application:\/\//, "")
      var key = signals.keyFor(uri, "")
      if (!key) return
      var props = data[1] || {}
      var p = signals.hint(props, "progress"), pv = signals.hint(props, "progress-visible")
      if (pv !== undefined || p !== undefined) {
        var prog = Object.assign({}, signals.progress)
        if (pv === false) delete prog[key]
        else if (p !== undefined) prog[key] = Math.max(0, Math.min(1, Number(p)))
        signals.progress = prog
      }
      var c = signals.hint(props, "count"), cv = signals.hint(props, "count-visible")
      if (cv !== undefined || c !== undefined) {
        var counts = Object.assign({}, signals.counts)
        if (cv === false) delete counts[key]
        else if (c !== undefined) counts[key] = Number(c)
        signals.counts = counts
      }
      if (signals.hint(props, "urgent") === true && signals.dock) signals.dock.bounce(key)
    }
  }

  Process {
    id: monitor
    running: true
    command: ["busctl", "--user", "monitor", "--json=short",
      "--match", "type='method_call',interface='org.freedesktop.Notifications',member='Notify'",
      "--match", "type='signal',interface='com.canonical.Unity.LauncherEntry'"]
    stdout: SplitParser { onRead: line => signals.handle(line) }
    // Comes back if the bus drops it.
    onExited: restart.start()
  }

  Timer {
    id: restart
    interval: 3000
    onTriggered: monitor.running = true
  }
}
