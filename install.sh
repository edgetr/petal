#!/usr/bin/env bash
# Installs Petal for this user: links the plugin into Omarchy, puts the
# `petal` command on PATH, seeds ~/.config/petal, and enables the plugin.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
config="$HOME/.config/petal"
plugins="$HOME/.config/omarchy/plugins"

mkdir -p "$config" "$plugins" "$HOME/.local/bin"
ln -sfn "$here/plugin" "$plugins/egesuren.petal"
ln -sfn "$here/bin/petal" "$HOME/.local/bin/petal"

[[ -f $config/modes.json ]] || cp "$here/defaults/modes.json" "$config/modes.json"

# Settings: carry over the old dock's choices, and find the Claude and Codex
# CLIs (the shell's PATH doesn't include mise shims).
python3 - "$config/settings.json" <<'PY'
import json, os, shutil, sys
path = sys.argv[1]
s = {}
if os.path.exists(path):
    s = json.load(open(path))
old = os.path.expanduser("~/.config/omarchy/egesuren-dock.json")
if not s and os.path.exists(old):
    o = json.load(open(old))
    for k in ("tooltips", "previews", "stacks", "stackFolders", "trash"):
        if k in o: s[k] = o[k]
def find(name, places):
    found = shutil.which(name) or ""
    for p in places:
        p = os.path.expanduser(p)
        if not found and os.access(p, os.X_OK): found = p
    return found
if not s.get("claudePath"):
    s["claudePath"] = find("claude", ("~/.local/share/mise/command-wrappers/bin/claude", "~/.local/bin/claude", "~/.claude/local/claude"))
if not s.get("codexPath"):
    s["codexPath"] = find("codex", ("~/.local/share/mise/command-wrappers/bin/codex", "~/.local/bin/codex"))
# AI is optional: a new install starts with whichever of them is installed.
if "aiProviders" not in s:
    s["aiProviders"] = [p for p in ("claude", "codex") if s[p + "Path"]]
json.dump(s, open(path, "w"), indent=4)
print("claude:", s["claudePath"] or "not found")
print("codex:", s["codexPath"] or "not found")
if not s["aiProviders"]: print("No AI app found: Petal works as a dock; install Claude Code or Codex for its AI features.")
PY

# Petal's MCP server for the user's other AI sessions (T3 Code, Claude Code or
# Codex in a terminal), through each CLI's own `mcp add`, unless otherAgents is
# off. It points at the plugin link, which stays put across updates.
if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("otherAgents", True) else 1)' "$config/settings.json" 2>/dev/null; then
  server="$HOME/.config/omarchy/plugins/egesuren.petal/mcp/petal-mcp.py"
  for cli in claude codex; do
    path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2] + "Path", ""))' "$config/settings.json" "$cli")"
    [[ -x $path ]] || continue
    if ! "$path" mcp get petal 2>/dev/null | grep -q "$server"; then
      if [[ $cli == claude ]]; then
        "$path" mcp remove -s user petal >/dev/null 2>&1 || true
        "$path" mcp add -s user petal -- python3 "$server" >/dev/null 2>&1 && echo "$cli: Petal's tools added"
      else
        "$path" mcp remove petal >/dev/null 2>&1 || true
        "$path" mcp add petal -- python3 "$server" >/dev/null 2>&1 && echo "$cli: Petal's tools added"
      fi
    fi
  done
fi

# Petal's skill, so Claude Code and Codex know Petal in any session (linked, so
# updates bring the new one along).
for agent_home in "$HOME/.claude" "$HOME/.codex"; do
  if [[ -d $agent_home ]]; then
    mkdir -p "$agent_home/skills"
    ln -sfn "$here/plugin/skill" "$agent_home/skills/petal"
  fi
done

# Enable it in Omarchy's shell config instead of the old dock plugin.
python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.config/omarchy/shell.json")
try:
    d = json.load(open(path))
except (OSError, ValueError):
    d = {}
plugins = [p for p in d.get("plugins", []) if p.get("id") not in ("egesuren.dock", "egesuren.petal")]
plugins.append({"id": "egesuren.petal"})
d["plugins"] = plugins
json.dump(d, open(path, "w"), indent=2)
PY

# Petal in Omarchy's menu (Super+Space > Petal): a block in the user's menu
# extension, between markers Petal keeps current. Added once; if it's taken
# out, it stays out.
state="${XDG_STATE_HOME:-$HOME/.local/state}/petal"
mkdir -p "$state"
python3 - "$state" <<'PY'
import json, os, sys
state = sys.argv[1]
path = os.path.expanduser("~/.config/omarchy/extensions/omarchy-menu.jsonc")
begin, end = "  // petal:begin (Petal keeps these entries current)", "  // petal:end"
rows = [
    ("petal", {"icon": "󰉊", "label": "Petal", "description": "Your dock: modes, held notifications, schedule, settings"}),
    ("petal.menu", {"icon": "", "label": "Petal Menu", "action": "omarchy-shell petal panel home"}),
    ("petal.held", {"icon": "", "label": "Held Notifications", "action": "omarchy-shell petal panel held"}),
    ("petal.schedule", {"icon": "", "label": "Schedule", "action": "omarchy-shell petal panel schedule"}),
    ("petal.summary", {"icon": "", "label": "Last Week", "action": "omarchy-shell petal panel summary"}),
    ("petal.describe", {"icon": "", "label": "Build My Modes with AI", "action": "omarchy-shell petal describe"}),
    ("petal.recipes", {"icon": "", "label": "Share or Add a Dock", "action": "omarchy-shell petal panel recipes"}),
    ("petal.doctor", {"icon": "", "label": "Check Petal", "action": "omarchy-shell petal panel doctor"}),
]
block = [begin] + ['  "%s": %s,' % (k, json.dumps(v, ensure_ascii=False)) for k, v in rows] + [end]
try:
    lines = open(path).read().split("\n")
except OSError:
    lines = ["{", "}", ""]
added = os.path.join(state, "omarchy-menu-added")
start = next((i for i, l in enumerate(lines) if l.strip().startswith("// petal:begin")), None)
if start is not None:
    stop = next((i for i, l in enumerate(lines) if i > start and l.strip() == "// petal:end"), start)
    lines[start:stop + 1] = block
elif not os.path.exists(added):
    at = next((i for i, l in enumerate(lines) if l.strip().startswith("{")), None)
    if at is None:
        lines = ["{"] + block + ["}", ""]
    else:
        lines[at + 1:at + 1] = block
else:
    sys.exit(0)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".tmp", "w") as f:
    f.write("\n".join(lines))
os.replace(path + ".tmp", path)
open(added, "w").close()
PY

# Petal's mode indicator in Omarchy's bar, beside the workspaces: placed once
# (the Petal menu's "Mode in the top bar" takes it out and puts it back).
if [[ ! -e $state/bar-placed ]] && command -v omarchy >/dev/null; then
  omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
  if omarchy bar put egesuren.petal --after omarchy.workspaces >/dev/null 2>&1; then touch "$state/bar-placed"; fi
fi

echo "Petal installed. Restart the shell with: omarchy restart shell"
