import QtQuick
import Quickshell
import Quickshell.Io

// Petal's quick AI: one small call at a time through the chosen AI's local
// CLI (`claude -p` at Haiku, or `codex exec` at low effort), always answering
// in JSON, to sort windows and notifications into modes. Quick and cheap: it
// runs often.
// (The Claude panel's chat is Agent.qml.) Used to sort windows and notifications into
// modes and to edit the modes file from a plain-language request.
Item {
  id: brain

  property var dock: null
  readonly property string provider: dock ? dock.chatProvider : ""
  // Absolute path, since the shell's PATH does not include mise's shims.
  readonly property string cliPath: dock ? dock.providerPath(provider) : ""
  readonly property bool enabled: !!dock && dock.settings.ai && cliPath !== ""
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
    if (!brain.cliPath) {
      done(null, "No AI app found")
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
    brain.current.provider = brain.provider
    if (brain.provider === "codex") {
      // Codex: a throwaway, read-only run at low effort; the reply is its last message.
      proc.command = ["bash", "-c",
        "printf '%s' \"$1\" | \"$0\" exec --json --skip-git-repo-check --ephemeral --sandbox read-only -C /tmp -c 'model_reasoning_effort=\"low\"' -",
        brain.cliPath, brain.current.prompt]
    } else {
      proc.command = ["bash", "-c",
        "printf '%s' \"$1\" | \"$0\" -p --model \"$2\" ${3:+--effort \"$3\"} --no-session-persistence --setting-sources '' --strict-mcp-config --tools ''",
        brain.cliPath, brain.current.prompt, brain.current.model, brain.current.effort]
    }
    proc.running = true
  }

  // Codex prints events, one JSON object per line; its answer is the last agent message.
  function codexReply(text) {
    var reply = ""
    String(text || "").split("\n").forEach(function(line) {
      try {
        var m = JSON.parse(line)
        if (m.item && m.item.type === "agent_message") reply = String(m.item.text || "")
      } catch (e) {}
    })
    return reply
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
        var result = code === 0 ? brain.parse(job.provider === "codex" ? brain.codexReply(out.text) : out.text) : null
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

  // A name, icon, color and about for a new mode made of apps used together.
  // done({ name, icon, color, about })
  function nameMode(appNames, done) {
    var taken = brain.dock.modes.map(function(m) { return m.name + " " + (m.color || "") }).join(", ")
    var prompt = "You name a focus mode in a dock: a set of apps a person uses together for one kind of work.\n"
      + "Apps: " + appNames.join(", ") + "\n"
      + "Modes they already have (use a different name and color): " + taken + "\n"
      + "Reply with ONLY JSON: {\"name\": \"<one or two plain words, like Design or Studying>\", "
      + "\"icon\": \"<one Nerd Font Material Design glyph, as the character itself>\", "
      + "\"color\": \"#rrggbb (soft and bright, readable on dark glass)\", "
      + "\"about\": \"<what the mode is for, under 12 words>\"}"
    brain.ask(prompt, done, "haiku", "low")
  }

}
