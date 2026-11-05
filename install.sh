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

echo "Petal installed. Restart the shell with: omarchy restart shell"
