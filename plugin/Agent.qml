import QtQuick
import Quickshell
import Quickshell.Io

// The chat panel: a real Claude Code or Codex session (the user's own local
// CLI, streaming JSON), working in your home folder. In auto mode, Claude
// Code approves safe actions itself; anything it won't approve comes back as
// an "Allow?" request, and allowing it re-runs the turn with exactly that
// permitted (for the rest of the chat). Codex can't ask mid-turn: it works in
// its sandbox. Full access skips all checks for either.
Item {
  id: agent

  property var dock: null
  readonly property string provider: dock ? dock.chatProvider : ""
  readonly property string cliPath: dock ? dock.providerPath(provider) : ""
  readonly property bool running: proc.running
  // The session belongs to the AI that started it; switching starts afresh.
  property string sessionProvider: ""

  // Chat log: { kind: "user"|"claude"|"step"|"ask"|"error"|"done", text, detail }
  property alias messages: messages
  ListModel { id: messages }

  property string sessionId: ""
  // Permission rules granted in this chat, e.g. "Bash(hyprctl reload)".
  property var allowed: []
  // The latest request for permission: [{ tool, label, rules: [...] }]
  property var pendingAsk: []

  // Petal's MCP server, started by Claude Code for every turn.
  readonly property string mcpServer: String(Qt.resolvedUrl("mcp/petal-mcp.py")).replace(/^file:\/\//, "")
  readonly property string mcpConfig: JSON.stringify({ mcpServers: { petal: { command: "python3", args: [agent.mcpServer] } } })

  // The user's own standing instructions for Claude, if they wrote any.
  FileView {
    id: instructionsFile
    path: Quickshell.env("HOME") + "/.config/petal/instructions.md"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }

  readonly property string systemPrompt: "You are " + (dock ? dock.chatName : "Claude") + ", running inside Petal, the user's dock on Omarchy "
    + "(Arch Linux with Hyprland; Hyprland config lives in ~/.config/hypr/; validate config changes with "
    + "`hyprctl reload && hyprctl configerrors`; Omarchy has an `omarchy` CLI). Your replies show in a small panel "
    + "above the dock: be brief and friendly, short paragraphs, no big headings. You work in the user's home folder.\n\n"
    + "Everything about the dock is customizable through you. Use the petal MCP tools: call petal_get_state first, "
    + "then petal_set_settings (appearance: dockColor, dockOpacity, iconSize, accentColor, font, …; feature switches: "
    + "bounce, badges, previews, …), petal_set_dock (position, auto-hide), petal_save_mode / petal_delete_mode "
    + "(focus modes and their apps; get desktop ids from petal_list_apps). Changes apply instantly. "
    + "If a request can't be done with settings, you may edit Petal's QML source (path in petal_get_state) and then "
    + "call petal_reload; mention that a Petal update could replace source edits. "
    + "You can also help with anything else on the computer: Omarchy, Hyprland, apps, files. "
    + "If something needs the user's approval, say in one line what it would do; they can allow it from the panel. "
    + "If something about Petal itself is broken, run `petal doctor` (and `petal doctor --fix`); the petal skill says more."

  function fullPrompt() {
    var mine = String(instructionsFile.text() || "").trim()
    return agent.systemPrompt + (mine ? "\n\nThe user's own instructions:\n" + mine : "")
  }

  function reset() {
    agent.stop()
    messages.clear()
    agent.sessionId = ""
    agent.allowed = []
    agent.pendingAsk = []
  }

  function stop() {
    if (proc.running) proc.signal(15)
  }

  function send(text) {
    var t = String(text || "").trim()
    if (!t || proc.running) return
    agent.pendingAsk = []
    messages.append({ kind: "user", text: t, detail: "" })
    agent.run(t)
  }

  function allow() {
    var asks = agent.pendingAsk
    if (asks.length === 0 || proc.running) return
    var next = agent.allowed.slice()
    asks.forEach(function(a) { a.rules.forEach(function(r) { if (next.indexOf(r) < 0) next.push(r) }) })
    agent.allowed = next
    agent.pendingAsk = []
    messages.append({ kind: "step", text: "Allowed", detail: "" })
    agent.run("I approved that. Go ahead and run it, then continue.")
  }

  function deny() {
    agent.pendingAsk = []
    messages.append({ kind: "step", text: "Not allowed", detail: "" })
  }

  function toml(text) {
    return "\"" + String(text).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n") + "\""
  }

  function run(prompt) {
    var s = agent.dock.settings
    if (!agent.provider || !agent.cliPath) {
      messages.append({ kind: "error", text: agent.provider ? agent.dock.chatName + " isn't installed (see claudePath and codexPath in settings)." : "No AI is chosen in Petal's settings.", detail: "" })
      return
    }
    if (agent.sessionProvider !== agent.provider) {
      agent.sessionId = ""
      agent.allowed = []
      agent.sessionProvider = agent.provider
    }
    if (agent.provider === "codex") {
      var cx = [agent.cliPath, "exec", "--json", "--skip-git-repo-check", "-C", Quickshell.env("HOME")]
      cx = cx.concat(s.claudeAccess === "full" ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--sandbox", "workspace-write"])
      if (s.codexModel) cx.push("-m", s.codexModel)
      cx.push("-c", "model_reasoning_effort=" + agent.toml(s.codexEffort || "medium"),
        "-c", "developer_instructions=" + agent.toml(agent.fullPrompt()),
        "-c", "mcp_servers.petal.command=\"python3\"",
        "-c", "mcp_servers.petal.args=[" + agent.toml(agent.mcpServer) + "]",
        // codex exec can't ask, so Petal's own tools are approved ahead.
        "-c", "mcp_servers.petal.default_tools_approval_mode=\"approve\"")
      if (agent.sessionId) cx.push("resume", agent.sessionId)
      cx.push("-")
      proc.command = ["bash", "-c", "p=\"$1\"; shift; printf '%s' \"$p\" | \"$@\"", "petal", prompt].concat(cx)
      proc.running = true
      return
    }
    var args = [agent.cliPath, "-p",
      "--model", s.chatModel || "sonnet",
      "--effort", s.chatEffort || "medium",
      "--output-format", "stream-json", "--verbose",
      "--permission-mode", s.claudeAccess === "full" ? "bypassPermissions" : "auto",
      "--append-system-prompt", agent.fullPrompt()]
    args.push("--mcp-config", agent.mcpConfig)
    if (agent.sessionId) args.push("--resume", agent.sessionId)
    // Petal's own tools never need asking.
    args = args.concat(["--allowedTools", "mcp__petal"]).concat(agent.allowed)
    proc.command = ["bash", "-c", "p=\"$1\"; shift; printf '%s' \"$p\" | \"$@\"", "petal", prompt].concat(args)
    proc.running = true
  }

  function shortPath(p) {
    var home = Quickshell.env("HOME")
    p = String(p || "")
    return p.indexOf(home) === 0 ? "~" + p.slice(home.length) : p
  }

  function describe(tool, input) {
    input = input || {}
    switch (tool) {
    case "Bash": return "Running  " + String(input.command || "").split("\n")[0]
    case "Read": return "Reading  " + agent.shortPath(input.file_path)
    case "Edit": case "MultiEdit": return "Editing  " + agent.shortPath(input.file_path)
    case "Write": return "Writing  " + agent.shortPath(input.file_path)
    case "Glob": case "Grep": return "Searching  " + String(input.pattern || "")
    case "WebSearch": return "Searching the web  " + String(input.query || "")
    case "WebFetch": return "Reading  " + String(input.url || "")
    case "TodoWrite": return "Planning"
    case "mcp__petal__petal_get_state": return "Looking at your dock"
    case "mcp__petal__petal_set_settings": return "Changing  " + Object.keys(input.settings || {}).join(", ")
    case "mcp__petal__petal_reset_settings": return "Resetting settings"
    case "mcp__petal__petal_set_dock": return "Moving the dock"
    case "mcp__petal__petal_save_mode": return "Saving mode  " + String((input.mode || {}).name || (input.mode || {}).id || "")
    case "mcp__petal__petal_delete_mode": return "Deleting mode  " + String(input.id || "")
    case "mcp__petal__petal_list_apps": return "Looking up apps"
    case "mcp__petal__petal_switch_mode": return "Switching to  " + String(input.id || "")
    case "mcp__petal__petal_reload": return "Reloading Petal"
    default: return tool
    }
  }

  // The rules that let a denied call through: each part of a shell command
  // on its own (Claude Code checks them one by one), or the tool itself.
  function rulesFor(denial) {
    var tool = String(denial.tool_name || "")
    var input = denial.tool_input || {}
    if (tool === "Bash") {
      return String(input.command || "").split(/\s*(?:\|\||&&|\||;|\n)\s*/).map(function(part) { return part.trim() })
        .filter(function(part) { return part.length > 0 }).map(function(part) { return "Bash(" + part + ")" })
    }
    return [tool]
  }

  // Codex's events: thread.started, item.started/completed, turn.completed/failed.
  function handleCodex(m) {
    var item = m.item || {}
    if (m.type === "thread.started" && m.thread_id) agent.sessionId = m.thread_id
    else if (m.type === "item.completed" && item.type === "agent_message" && String(item.text || "").trim())
      messages.append({ kind: "claude", text: String(item.text).trim(), detail: "" })
    else if (m.type === "item.started" && item.type === "command_execution")
      messages.append({ kind: "step", text: "Running  " + String(item.command || "").split("\n")[0], detail: "" })
    else if (m.type === "item.started" && item.type === "mcp_tool_call")
      messages.append({ kind: "step", text: agent.describe("mcp__petal__" + item.tool, item.arguments), detail: "" })
    else if (m.type === "item.started" && item.type === "file_change")
      messages.append({ kind: "step", text: "Editing  " + agent.shortPath(((item.changes || [])[0] || {}).path), detail: "" })
    else if (m.type === "item.started" && item.type === "web_search")
      messages.append({ kind: "step", text: "Searching the web  " + String(item.query || ""), detail: "" })
    else if (m.type === "turn.failed")
      messages.append({ kind: "error", text: String((m.error || {}).message || "Something went wrong"), detail: "" })
    if ((m.type === "turn.completed" || m.type === "turn.failed") && agent.dock) agent.dock.refreshUsage()
  }

  function handle(line) {
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    if (agent.provider === "codex") { agent.handleCodex(m); return }
    if (m.session_id) agent.sessionId = m.session_id
    if (m.type === "assistant" && m.message && m.message.content) {
      m.message.content.forEach(function(c) {
        if (c.type === "text" && String(c.text).trim()) messages.append({ kind: "claude", text: String(c.text).trim(), detail: "" })
        else if (c.type === "tool_use" && c.name !== "ToolSearch") messages.append({ kind: "step", text: agent.describe(c.name, c.input), detail: "" })
      })
    } else if (m.type === "result") {
      var denials = m.permission_denials || []
      if (denials.length) {
        var seen = {}
        var asks = []
        denials.forEach(function(d) {
          var label = d.tool_name === "Bash" ? String((d.tool_input || {}).command || "") : agent.describe(d.tool_name, d.tool_input)
          if (seen[label]) return
          seen[label] = true
          asks.push({ tool: d.tool_name, label: label, rules: agent.rulesFor(d) })
        })
        agent.pendingAsk = asks
        messages.append({ kind: "ask", text: asks.map(function(a) { return a.label }).join("\n"), detail: "" })
      }
      if (m.is_error) messages.append({ kind: "error", text: String(m.result || "Something went wrong"), detail: "" })
      // Usage moved; show it.
      if (agent.dock) agent.dock.refreshUsage()
    }
  }

  Process {
    id: proc
    workingDirectory: Quickshell.env("HOME")
    stdout: SplitParser { onRead: line => agent.handle(line) }
    stderr: StdioCollector { id: err }
    onExited: function(code) {
      if (code !== 0 && code !== 143 && String(err.text).trim())
        messages.append({ kind: "error", text: String(err.text).trim().slice(0, 300), detail: "" })
    }
  }
}
