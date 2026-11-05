#!/usr/bin/env bash
# Removes Petal: unlinks the plugin and the `petal` command and disables the
# plugin in Omarchy's shell config. Your ~/.config/petal is kept (delete it
# yourself if you want it gone).
set -euo pipefail
rm -f "$HOME/.config/omarchy/plugins/egesuren.petal" "$HOME/.local/bin/petal"
python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.config/omarchy/shell.json")
if os.path.exists(path):
    d = json.load(open(path))
    d["plugins"] = [p for p in d.get("plugins", []) if p.get("id") != "egesuren.petal"]
    json.dump(d, open(path, "w"), indent=2)
PY
echo "Petal removed. Run: omarchy restart shell   (Omarchy's own dock can be turned back on from its settings)"
