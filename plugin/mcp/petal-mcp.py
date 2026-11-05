#!/usr/bin/env python3
"""Petal's MCP server: tools Claude uses to customize the Petal dock.

Speaks the Model Context Protocol (JSON-RPC 2.0, one message per line) on
stdin/stdout. No dependencies beyond the Python standard library. Petal's
Claude panel starts it automatically; it can also be added to any Claude
Code setup:  claude mcp add petal -- python3 /path/to/petal-mcp.py
"""

import glob
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
CONFIG = os.path.join(HOME, ".config", "petal")
SETTINGS = os.path.join(CONFIG, "settings.json")
MODES = os.path.join(CONFIG, "modes.json")
INSTRUCTIONS = os.path.join(CONFIG, "instructions.md")
PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))

# Every setting Petal reads, with its default and what it does. Petal
# reloads settings.json as soon as it changes.
SETTINGS_SCHEMA = {
    # Appearance
    "dockColor": ("", "Dock background color, #rrggbb. Empty = follow the Omarchy theme."),
    "dockOpacity": (0.45, "Dock background opacity, 0 to 1."),
    "dockBorderColor": ("#ffffff", "Dock rim color, #rrggbb."),
    "dockBorderOpacity": (0.28, "Dock rim opacity, 0 to 1 (0 = no rim)."),
    "dockRadius": (-1, "Dock corner radius in points; -1 = fully rounded ends."),
    "dockSheen": (True, "Soft top highlight and mode-colored wash on the dock."),
    "dockMargin": (-1, "Gap between the dock and the screen edge in points; -1 = default."),
    "iconSize": (36, "App icon size in points."),
    "iconPadding": (-1, "Space around each icon in points; -1 = default."),
    "idleOpacity": (0.7, "Opacity of pinned apps that aren't running, 0 to 1."),
    "separators": (True, "Thin dividers between the dock's sections."),
    "hoverLiftAmount": (0.05, "How much an icon grows/rises under the pointer, 0 (off) to 0.3."),
    "glowStrength": (1.0, "App-colored glow behind running apps, 0 to 1."),
    "accentColor": ("", "Accent color for dots, highlights, buttons, #rrggbb. Empty = theme accent."),
    "popupColor": ("", "Background color of menus, cards and panels, #rrggbb. Empty = theme."),
    "popupOpacity": (0.74, "Opacity of menus, cards and panels, 0 to 1."),
    "font": ("Adwaita Sans", "Font family for menus, cards and panels."),
    # Dock features
    "tooltips": (True, "Show app names on hover."),
    "hoverLift": (True, "Icons lift slightly on hover."),
    "appGlow": (True, "Running apps glow in their icon's color; their dot takes that color."),
    "thisWorkspaceOnly": (True, "Show running apps only from the current workspace."),
    "previews": (True, "Live window previews when hovering a running app."),
    "minimized": (True, "Minimized windows (Super+M) appear as thumbnails in the dock."),
    "badges": (True, "Unread notification counts on app icons."),
    "bounce": (True, "An icon bounces once when its app wants attention."),
    "progress": (True, "Progress rings around icons (downloads etc.)."),
    "quickActions": (True, "An app's own actions in its right-click menu."),
    "recentFiles": (True, "Recent files in an app's right-click menu."),
    "dropToOpen": (True, "Drop files on an app icon to open them in it."),
    "nowPlaying": (True, "A now-playing tile with album art."),
    "stacks": (True, "Folder stacks in the dock."),
    "stackFolders": (["~/Downloads", "~/Pictures/Screenshots"], "Folders shown as stacks."),
    "trash": (True, "Trash in the dock."),
    # Modes and AI
    "modes": (True, "Focus modes (the mode switcher and per-mode apps)."),
    "countdown": (False, "Wait out a mode's focusDelay before leaving it."),
    "focusGuard": (False, "Focus cards: ask when the window in front belongs to another mode."),
    "holdNotifications": (True, "In modes with hold=true, hold notifications from other apps."),
    "ai": (True, "Use Claude Haiku to sort unknown windows and notifications into modes."),
    "claudeUsage": (True, "Claude usage ring around the Claude button."),
    "autoUpdate": (True, "Install new Petal releases automatically (then offer a restart)."),
    "chatModel": ("sonnet", "Claude panel model: haiku, sonnet, opus or fable."),
    "chatEffort": ("medium", "Claude panel effort: low, medium, high, xhigh or max."),
    "claudeAccess": ("auto", "Claude panel permissions: auto (safe actions run, risky ones ask) or full."),
}

MODE_FIELDS = {
    "id": "unique id, lowercase",
    "name": "display name",
    "icon": "one Nerd Font glyph or emoji",
    "color": "#rrggbb",
    "about": "what the mode is for (used to sort activity into it)",
    "apps": "desktop ids, in dock order",
    "sites": "words or domains found in browser tab titles that belong to this mode",
    "focusDelay": "seconds of countdown before leaving (if countdowns are on)",
    "hold": "hold notifications from apps outside the mode",
    "allow": "desktop ids whose notifications always come through",
}


def read_json(path, fallback):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return fallback


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def run(*cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return (out.stdout or out.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return str(e)


def installed_apps(query=""):
    dirs = [os.path.join(HOME, ".local/share/applications")]
    dirs += [os.path.join(d, "applications") for d in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")]
    apps, seen = [], set()
    for d in dirs:
        for path in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            app_id = os.path.basename(path)[:-8]
            if app_id in seen:
                continue
            seen.add(app_id)
            name, hidden = app_id, False
            try:
                with open(path, errors="ignore") as f:
                    in_entry = False
                    for line in f:
                        line = line.strip()
                        if line.startswith("["):
                            in_entry = line == "[Desktop Entry]"
                        elif in_entry and line.startswith("Name="):
                            name = line[5:]
                        elif in_entry and line in ("NoDisplay=true", "Hidden=true"):
                            hidden = True
            except OSError:
                continue
            if hidden:
                continue
            if query and query.lower() not in (app_id + " " + name).lower():
                continue
            apps.append({"id": app_id, "name": name})
    return apps


def dock_config():
    shell = read_json(os.path.join(HOME, ".config/omarchy/shell.json"), {})
    dock = shell.get("dock", {})
    return {"position": dock.get("position", "bottom"), "autohide": dock.get("autohide", False)}


# ── Tools ──────────────────────────────────────────────────────────────

def t_get_state(_):
    settings = read_json(SETTINGS, {})
    effective = {k: settings.get(k, v[0]) for k, v in SETTINGS_SCHEMA.items()}
    return {
        "settings": effective,
        "settings_help": {k: v[1] for k, v in SETTINGS_SCHEMA.items()},
        "modes": read_json(MODES, {}),
        "mode_fields": MODE_FIELDS,
        "current_mode": run("omarchy-shell", "petal", "current"),
        "dock": dock_config(),
        "files": {"settings": SETTINGS, "modes": MODES, "instructions": INSTRUCTIONS, "plugin_source": PLUGIN_DIR},
    }


def t_set_settings(args):
    changes = args.get("settings") or {}
    unknown = [k for k in changes if k not in SETTINGS_SCHEMA]
    if unknown:
        raise ValueError("Unknown settings: %s. Use petal_get_state to see them all." % ", ".join(unknown))
    settings = read_json(SETTINGS, {})
    settings.update(changes)
    write_json(SETTINGS, settings)
    return {"ok": True, "changed": changes}


def t_reset_settings(args):
    keys = args.get("keys") or []
    settings = read_json(SETTINGS, {})
    for k in keys or list(SETTINGS_SCHEMA):
        if k in SETTINGS_SCHEMA and k not in ("claudePath",):
            settings[k] = SETTINGS_SCHEMA[k][0]
    write_json(SETTINGS, settings)
    return {"ok": True, "reset": keys or "all"}


def t_set_dock(args):
    done = {}
    if "position" in args:
        if args["position"] not in ("bottom", "top", "left", "right"):
            raise ValueError("position must be bottom, top, left or right")
        done["position"] = run("omarchy-dock", "position", args["position"])
    if "autohide" in args:
        done["autohide"] = run("omarchy-dock", "autohide", "on" if args["autohide"] else "off")
    return done


def t_save_mode(args):
    mode = dict(args.get("mode") or {})
    mid = mode.get("id")
    if not mid:
        raise ValueError("mode.id is required")
    data = read_json(MODES, {"defaultMode": mid, "workspaces": {}, "modes": []})
    data.setdefault("modes", [])
    data.setdefault("workspaces", {})
    for m in data["modes"]:
        if m.get("id") == mid:
            m.update(mode)
            break
    else:
        new = {"name": mid.title(), "icon": "●", "color": "#ff5fae", "about": "", "apps": [], "sites": [],
               "focusDelay": 0, "hold": False, "allow": []}
        new.update(mode)
        data["modes"].append(new)
    if not data.get("defaultMode"):
        data["defaultMode"] = mid
    write_json(MODES, data)
    return {"ok": True, "mode": next(m for m in data["modes"] if m.get("id") == mid)}


def t_delete_mode(args):
    mid = args.get("id")
    data = read_json(MODES, {})
    modes = [m for m in data.get("modes", []) if m.get("id") != mid]
    if len(modes) == len(data.get("modes", [])):
        raise ValueError("No mode with id %r" % mid)
    if not modes:
        raise ValueError("Petal needs at least one mode")
    data["modes"] = modes
    data["workspaces"] = {k: v for k, v in data.get("workspaces", {}).items() if v != mid}
    if data.get("defaultMode") == mid:
        data["defaultMode"] = modes[0]["id"]
    write_json(MODES, data)
    return {"ok": True}


def t_set_default_mode(args):
    data = read_json(MODES, {})
    if not any(m.get("id") == args.get("id") for m in data.get("modes", [])):
        raise ValueError("No mode with id %r" % args.get("id"))
    data["defaultMode"] = args["id"]
    write_json(MODES, data)
    return {"ok": True}


def t_switch_mode(args):
    return {"result": run("omarchy-shell", "petal", "mode", args.get("id", "")) or "ok"}


def t_list_apps(args):
    return installed_apps(args.get("query", ""))


def t_reload(_):
    subprocess.Popen(["omarchy", "restart", "shell"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return {"ok": True, "note": "Omarchy's shell (and Petal) is restarting; the Claude panel closes."}


TOOLS = {
    "petal_get_state": (t_get_state, "Everything about the user's Petal dock: all settings (with help text and current values), modes, current mode, position/auto-hide and file paths. Call this first.", {}),
    "petal_set_settings": (t_set_settings, "Change one or more Petal settings (appearance like dockColor/dockOpacity/iconSize/accentColor, and feature switches like bounce/badges). Applies instantly.",
                           {"settings": {"type": "object", "description": "setting name -> new value"}}),
    "petal_reset_settings": (t_reset_settings, "Reset settings to their defaults (all, or just the given keys).",
                             {"keys": {"type": "array", "items": {"type": "string"}}}),
    "petal_set_dock": (t_set_dock, "Move the dock (position: bottom, top, left, right) and/or turn auto-hide on or off.",
                       {"position": {"type": "string", "enum": ["bottom", "top", "left", "right"]}, "autohide": {"type": "boolean"}}),
    "petal_save_mode": (t_save_mode, "Create a mode or update fields of an existing one (merges). Fields: " + "; ".join("%s: %s" % kv for kv in MODE_FIELDS.items()),
                        {"mode": {"type": "object", "description": "must include id"}}),
    "petal_delete_mode": (t_delete_mode, "Delete a mode.", {"id": {"type": "string"}}),
    "petal_set_default_mode": (t_set_default_mode, "Set the mode new workspaces start in.", {"id": {"type": "string"}}),
    "petal_switch_mode": (t_switch_mode, "Switch the focused workspace to a mode.", {"id": {"type": "string"}}),
    "petal_list_apps": (t_list_apps, "Installed apps (desktop id and name), optionally filtered by a search word. Use the ids in a mode's apps.",
                        {"query": {"type": "string"}}),
    "petal_reload": (t_reload, "Restart Omarchy's shell to load edits to Petal's own source code (settings and modes don't need this).", {}),
}


def tool_list():
    out = []
    for name, (_, desc, props) in TOOLS.items():
        out.append({"name": name, "description": desc,
                    "inputSchema": {"type": "object", "properties": props}})
    return out


def handle(msg):
    method = msg.get("method")
    if method == "initialize":
        return {"protocolVersion": (msg.get("params") or {}).get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "petal", "version": read_json(os.path.join(PLUGIN_DIR, "manifest.json"), {}).get("version", "")},
                "instructions": "Tools to customize the Petal dock. Call petal_get_state first."}
    if method == "tools/list":
        return {"tools": tool_list()}
    if method == "tools/call":
        params = msg.get("params") or {}
        entry = TOOLS.get(params.get("name"))
        if not entry:
            return {"content": [{"type": "text", "text": "Unknown tool"}], "isError": True}
        try:
            result = entry[0](params.get("arguments") or {})
            return {"content": [{"type": "text", "text": json.dumps(result, indent=2, ensure_ascii=False)}]}
        except Exception as e:  # report to Claude rather than crash
            return {"content": [{"type": "text", "text": "Error: %s" % e}], "isError": True}
    if method == "ping":
        return {}
    return None


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if "id" not in msg:
            continue  # notifications need no answer
        result = handle(msg)
        if result is None:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "Method not found"}}
        else:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "result": result}
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
