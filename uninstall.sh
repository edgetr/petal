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
    layout = (d.get("bar") or {}).get("layout") or {}
    for k, v in layout.items():
        if isinstance(v, list):
            layout[k] = [e for e in v if not (isinstance(e, dict) and e.get("id") == "egesuren.petal")]
    json.dump(d, open(path, "w"), indent=2)
# Petal's entries in Omarchy's menu.
menu = os.path.expanduser("~/.config/omarchy/extensions/omarchy-menu.jsonc")
if os.path.exists(menu):
    out, inside = [], False
    for line in open(menu).read().split("\n"):
        if line.strip().startswith("// petal:begin"):
            inside = True
        elif inside and line.strip() == "// petal:end":
            inside = False
        elif not inside:
            out.append(line)
    open(menu, "w").write("\n".join(out))
PY
echo "Petal removed. Run: omarchy restart shell   (Omarchy's own dock can be turned back on from its settings)"
