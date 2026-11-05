import QtQuick
import Quickshell
import Quickshell.Io

// Petal's quick AI: one small Claude call at a time through the local Claude
// Code CLI (`claude -p`), always answering in JSON, to sort windows and
// notifications into modes. Always Haiku at low effort: it runs often.
// (The Claude panel's chat is Agent.qml.) Used to sort windows and notifications into
// modes and to edit the modes file from a plain-language request.
Item {
  id: brain

  property var dock: null
  // Absolute path, since the shell's PATH does not include mise's shims.
  property string claudePath: ""
  readonly property bool enabled: !!dock && dock.settings.ai && claudePath !== ""
  readonly property bool busy: proc.running

  property var queue: []
  property var current: null
  // Answers already given, by question, so the same window or app is only
  // asked about once a session.
  property var cache: ({})

  // ask(prompt, done, model, effort[, cacheKey]): done(result|null, error)
  function ask(prompt, done, model, effort, cacheKey) {
    if (cacheKey && brain.cache[cacheKey] !== undefined) {
      done(brain.cache[cacheKey], "")
      return
    }
    if (!brain.claudePath) {
      done(null, "Claude Code CLI not found")
      return
    }
    brain.queue.push({ prompt: prompt, done: done, model: model || "haiku", effort: effort || "", cacheKey: cacheKey || "" })
    brain.next()
  }

  function next() {
    if (proc.running || brain.queue.length === 0) return
    brain.current = brain.queue.shift()
    // The Claude Code CLI in print mode, like T3 Code runs it: no tools, no
    // MCP servers, no saved session; the answer comes back on stdout.
    proc.command = ["bash", "-c",
      "printf '%s' \"$1\" | \"$0\" -p --model \"$2\" ${3:+--effort \"$3\"} --no-session-persistence --setting-sources '' --strict-mcp-config --tools ''",
      brain.claudePath, brain.current.prompt, brain.current.model, brain.current.effort]
    proc.running = true
  }

  function parse(text) {
    var s = String(text || "")
    var a = s.indexOf("{"), b = s.lastIndexOf("}")
    if (a < 0 || b <= a) return null
    try { return JSON.parse(s.slice(a, b + 1)) } catch (e) { return null }
  }

  Process {
    id: proc
    stdout: StdioCollector { id: out }
    stderr: StdioCollector { id: err }
    onExited: function(code) {
      var job = brain.current
      brain.current = null
      if (job) {
        var result = code === 0 ? brain.parse(out.text) : null
        if (result && job.cacheKey) {
          var next = Object.assign({}, brain.cache)
          next[job.cacheKey] = result
          brain.cache = next
        }
        try {
          job.done(result, result ? "" : (String(err.text || out.text).trim().slice(0, 200) || "No answer"))
        } catch (e) {
          console.warn("petal brain callback:", e)
        }
      }
      Qt.callLater(brain.next)
    }
  }

  function modesBrief() {
    return brain.dock.modes.map(function(m) {
      return "- " + m.id + " (" + m.name + "): " + (m.about || "") + (m.sites && m.sites.length ? "; sites: " + m.sites.join(", ") : "")
    }).join("\n")
  }

  // Which mode a window belongs to. done({ mode: id|null, reason })
  function classifyWindow(app, title, done) {
    var prompt = "You sort a user's desktop activity into focus modes.\n"
      + "Modes:\n" + brain.modesBrief() + "\n\n"
      + "Focused window: app=\"" + app + "\" title=\"" + title + "\"\n"
      + "Which mode does this activity belong to? Use null if none fits.\n"
      + "Reply with ONLY JSON: {\"mode\": \"<id>\"|null, \"reason\": \"<max 8 words, what it is>\"}"
    brain.ask(prompt, done, "haiku", "low", "w|" + app + "|" + title)
  }

  // Which mode a notification belongs to, and whether it can't wait.
  // done({ mode, urgent, reason })
  function classifyNotification(n, done) {
    var prompt = "You triage notifications for a user in focus modes.\n"
      + "Modes:\n" + brain.modesBrief() + "\n\n"
      + "Notification from app \"" + n.app + "\": \"" + n.summary + "\" — \"" + String(n.body).slice(0, 300) + "\"\n"
      + "Which mode does it belong to, and is it time-sensitive (needs an answer within the hour, or is an emergency)?\n"
      + "Reply with ONLY JSON: {\"mode\": \"<id>\"|null, \"urgent\": true|false, \"reason\": \"<max 8 words>\"}"
    brain.ask(prompt, done, "haiku", "low", "n|" + n.app + "|" + n.summary + "|" + n.body)
  }

}
