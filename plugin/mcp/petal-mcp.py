#!/usr/bin/env python3
"""Petal's MCP server: tools Claude uses to customize the Petal dock.

Speaks the Model Context Protocol (JSON-RPC 2.0, one message per line) on
stdin/stdout. No dependencies beyond the Python standard library. Petal's
Claude panel starts it automatically; it can also be added to any Claude
Code setup:  claude mcp add petal -- python3 /path/to/petal-mcp.py
"""

import contextlib
import fcntl
import glob
import json
import os
import plistlib
import socket
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CONFIG = os.path.join(HOME, ".config", "petal")
SETTINGS = os.path.join(CONFIG, "settings.json")
MODES = os.path.join(CONFIG, "modes.json")
INSTRUCTIONS = os.path.join(CONFIG, "instructions.md")
PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
# Petal for macOS ships this same server inside Petal.app, and keeps the dock's place in dock.json.
MAC = sys.platform == "darwin"
DOCK = os.path.join(CONFIG, "dock.json")
SOCKET = os.environ.get("PETAL_SOCKET") or os.path.join(CONFIG, "petal.sock")
# The person's own changes to Petal's code, kept through updates (bin/petal-personal, `petal personal`).
PERSONAL = os.path.join(HOME, "Library/Application Support/Petal/source") if MAC else \
    os.path.join(os.environ.get("PETAL_HOME") or os.path.join(HOME, ".local/share/petal"), "source")
PERSONAL_HOW = ("To change Petal's code so it survives updates: `petal personal init` (once), edit the files in source, then "
                "`petal personal save \"<what changed>\"`" + (", which builds it and restarts Petal into it." if MAC else
                ", then `petal restart` to load it.") + " `petal personal help` lists the rest.")

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
    "countdown": (True, "Entering a distracting mode (distracting=true, like Social) takes its focusDelay wait, with Stay; each extra press halves what's left. Other modes switch at once."),
    "focusGuard": (True, "Focus cards: when what's in front belongs to another mode, a card says so (Stay, or go there). Something no mode knows yet is checked by the AI first."),
    "blockDistractions": (True, "In other modes, apps and sites of a distracting mode don't stay open: the card offers Stay (the tab closes or the app hides) or Go to <mode> (with its wait)."),
    "peeks": (True, "A small card that fades by itself shows what the AI decided about something new (\"tidepool.dev · Fits Building · API docs for an incident tool\")."),
    "holdNotifications": (True, "In modes with hold=true, hold notifications from apps outside the mode; they wait on their mode with a count. On macOS this needs Full Disk Access (to read them) and Do Not Disturb (to keep macOS's banners away); Petal shows the mode's own ones itself."),
    "urgentNotifications": (True, "A held notification that can't wait (the AI decides) pops out of its mode's icon as a card: Later, or Go to <mode>."),
    "modeWindows": (False, "Each mode keeps its own windows and tabs, and switching mode swaps them. macOS: on one Desktop, other modes' windows wait just off-screen. Omarchy: each mode has its own workspace."),
    "tiling": (False, "macOS: Petal tiles the windows of the mode in front, like a tiling window manager (Omarchy already tiles with Hyprland)."),
    "tilingGaps": (8, "macOS: space between tiled windows and around them, in points."),
    "tilingFloat": ([], "macOS: bundle ids of apps whose windows never tile."),
    "ai": (True, "Use Claude Haiku to sort unknown windows and notifications into modes."),
    "claudeUsage": (True, "Claude usage ring around the Claude button."),
    "autoUpdate": (True, "Install new Petal releases automatically (then offer a restart)."),
    "chatModel": ("sonnet", "Claude panel model: haiku, sonnet, opus or fable."),
    "chatEffort": ("medium", "Claude panel effort: low, medium, high, xhigh or max."),
    "claudeAccess": ("auto", "Claude panel permissions: auto (safe actions run, risky ones ask) or full."),
    "aiProviders": (["claude"], "The AI apps Petal uses, each the user's own install and account: claude, codex, both, or none ([] = no AI; the dock still works)."),
    "otherAgents": (True, "Let the user's other AI sessions (T3 Code, Claude Code or Codex in a terminal) change Petal: its MCP server, skill and `petal` command are set up for them."),
    "aiMemory": (True, "Petal AI remembers what helps, everywhere or per mode: what the user asks it to, and what it notices (memory.json). petal_remember / petal_forget / petal_memories."),
    "aiLearns": (True, "Once a day Petal AI learns from how each mode is used (its apps, how long) and remembers it; a quick call to the chat AI's small model."),
    "dailySummary": ("", "A card with the day in the user's modes at this time each day (\"HH:MM\"; empty for none), with a line from Petal AI."),
    "aiNeverLook": (["com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess"], "Apps Petal AI never looks into (bundle ids): petal_look gives only their name, window lists leave out their titles, and screenshots leave them out."),
    "selectionAsk": (True, "macOS: selecting text in any app brings up a small \"Ask Petal AI\" button by it (and \"Note\", a new note on that sentence, when notes is on); clicking Ask quotes the text in the chat. (Also in every app's Services menu.) Never in apps kept private or password fields."),
    "notes": (True, "macOS: Petal Notes, the user's own notes on paper stuck to places: a sentence, a browser tab, a window, all of an app, a file in any app, a Desktop. On a window they rest as tabs on its right edge at their line's height; ⌃⌥N, \"Note\" by selected text, dragging from the AI button or Stick here on a quick question makes one. Markdown files, one per note, a folder per notebook. petal_notes / petal_note_read / petal_note_write / petal_note_move / petal_note_stick. Helpers: @Petal in a note runs only when the person presses Return on that line; its answer is ink on the note, its steps and what was allowed (stamps) on the back; things said in words (bring this back Friday, remember, put this away, check this every morning, recalculate, when @A is done, check this against @Notebook) are done there. Petal's viewer shows a document with its notes in a margin (petal_view, petal_view_versions, petal_view_pick, petal_note_pdf_comments)."),
    "notesLook": ("paper", "macOS: how notes look: paper (opaque paper tinted with the notebook's color) or glass (macOS's Liquid Glass)."),
    "notesFolder": ("", "macOS: where notes are kept (a folder path; empty: iCloud Drive's Petal Notes when iCloud Drive is on, else Petal's own folder in Application Support)."),
    "notesNotebook": ("Inbox", "macOS: the notebook new notes go to, unless one was last used on that site or app."),
    "chatWhileWorking": ("steer", "Writing in the AI chat while it works: steer (it stops where it is and carries on from the new message) or queue (sent once it's done)."),
    "finderInDock": (True, "macOS: Finder as its own button next to the AI button, the same in every mode (never among the apps, so it never appears at the end and moves the rest)."),
    "replyDrafts": (True, "Entering a mode with held messages that need an answer, Petal AI drafts replies in the user's own style (learned from the replies they edit), shown on a card; it never sends anything."),
    "aiAllowed": ([], "What Petal AI may do without asking first (the user chose Always on its card): quit, close, trash, tidy, computer:<bundle id> (using that app)."),
    "computerUse": (True, "macOS: Petal AI can use the user's apps for them (petal_ui, petal_act): it presses buttons, types and chooses menu items through Accessibility, with a pink pointer of its own; the user's pointer never moves. A sticky note works in its own window in the background (no pointer, nothing comes forward) and asks the user to bring the window forward for what can't be done there. It asks before it uses each app (once per reply), and Stop or Escape ends it. Never apps in aiNeverLook, never password fields. Off: both tools refuse."),
    "routines": (True, "macOS: run the user's routines (routines.json): what Petal does by itself when a file lands in a folder, an app opens, a mode starts or at a time. Made with petal_routine_save."),
    "shortcuts": (True, "Petal's keyboard shortcuts: switch mode (1-9), open the AI panel, open the + search. Never takes one already in use."),
    "schedule": ([], "Modes by time: [{mode, days: [1-7, 1 = Monday], from: \"HH:MM\", to: \"HH:MM\"}]. When a block starts, the focused workspace switches to that mode."),
    "activityLog": (True, "Keep a private, local history of which app is in front (never titles), for suggestions and the weekly summary."),
    "suggestModes": (True, "Suggest new modes, or apps to add to a mode, from the activity history."),
    "summary": (True, "A weekly summary card: time in each mode, top apps, focus cards."),
    "magnification": (False, "macOS: icons grow under the pointer."),
    "magnificationAmount": (0.5, "macOS: how much icons grow, 0.1 to 1 (1 = twice the size)."),
    "menuBarIcon": (True, "macOS: Petal's icon in the menu bar (mode, updates)."),
    "chatProvider": ("claude", "Which of aiProviders the chat panel, the usage ring and sorting use: claude or codex."),
    "codexModel": ("", "Codex chat model; empty = Codex's own default."),
    "codexEffort": ("medium", "Codex chat reasoning effort: low, medium, high or xhigh."),
    "claudeAuth": ("subscription", "macOS: how Petal's own Claude runs (chat, sorting) pay: subscription (the user's Claude Code sign-in) or api (an Anthropic API key the user pastes in Settings > AI; it stays in the Keychain, and only Petal's runs use it). Never ask for or handle a key yourself."),
    "codexAuth": ("subscription", "macOS: how Petal's own Codex runs pay: subscription (the user's ChatGPT sign-in) or api (an OpenAI API key the user pastes in Settings > AI; Keychain only, Petal's runs only). Never ask for or handle a key yourself."),
}

MODE_FIELDS = {
    "id": "unique id, lowercase",
    "name": "display name",
    "icon": "an SF Symbol name, like hammer" if MAC else "one Nerd Font glyph or emoji",
    "color": "#rrggbb",
    "about": "what the mode is for (used to sort activity into it)",
    "apps": ("bundle ids" if MAC else "desktop ids") + ", in dock order; an https:// address is a website shortcut (shown with a globe badge)",
    "sites": "domains (x.com) or words in tab titles that belong to this mode; the AI adds a domain when it sorts a new site here",
    "distracting": "true for modes that pull you away (Social, Gaming): entering one takes its wait, and in other modes its apps and sites are blocked. Missing = the AI decides once and saves it",
    "focusDelay": "a distracting mode's wait in seconds before you're in it (30 if 0 or missing); ignored for other modes",
    "hold": "hold notifications from apps outside the mode",
    "allow": "apps (" + ("bundle ids" if MAC else "desktop ids") + ") and sites (domains or title words) that are fine in this mode without being in its dock; \"Keep it here\" on a card adds one, and their notifications come through",
    "shortcut": "macOS: the name of a Shortcut (Shortcuts app) to run when a Desktop enters this mode, e.g. one that turns on a Focus",
    "hyprland": "Omarchy: this mode's look for its workspaces: {borderColor: \"#rrggbb\" or \"mode\", gapsIn, gapsOut, wallpaper}",
}
WORKSPACE = "Desktop" if MAC else "workspace"


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


def petal(*args, timeout=5):
    """Asks the running Petal for macOS, over its socket, as `omarchy-shell petal` does on Omarchy. Running out of
    time (`timeout` seconds) says so; it's never "Petal isn't running"."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(SOCKET)
            conn.sendall((json.dumps(list(args)) + "\n").encode())
            reply = b""
            while not reply.endswith(b"\n"):
                chunk = conn.recv(4096)
                if not chunk:
                    break
                reply += chunk
            return reply.decode().strip()
    except socket.timeout:
        return "Petal didn't answer in time"
    except OSError as e:
        return "Petal isn't running (%s)" % e


def mac_apps(query=""):
    roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
             os.path.join(HOME, "Applications")]
    apps, seen = [], set()
    for root in roots:
        for path in sorted(glob.glob(os.path.join(root, "*.app")) + glob.glob(os.path.join(root, "*", "*.app"))):
            try:
                with open(os.path.join(path, "Contents", "Info.plist"), "rb") as f:
                    info = plistlib.load(f)
            except Exception:   # a missing or malformed Info.plist: not an app to list
                continue
            app_id = info.get("CFBundleIdentifier")
            if not app_id or app_id in seen:
                continue
            seen.add(app_id)
            name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or os.path.basename(path)[:-4]
            if query and query.lower() not in (app_id + " " + name).lower():
                continue
            apps.append({"id": app_id, "name": name})
    return sorted(apps, key=lambda a: a["name"].lower())


def installed_apps(query="", categories=False):
    """Installed apps as [{id, name}]; with categories, also each desktop entry's Categories (Omarchy)."""
    if MAC:
        return mac_apps(query)
    dirs = [os.path.join(HOME, ".local/share/applications")]
    dirs += [os.path.join(d, "applications") for d in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")]
    apps, seen = [], set()
    for d in dirs:
        for path in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            app_id = os.path.basename(path)[:-8]
            if app_id in seen:
                continue
            seen.add(app_id)
            name, hidden, cats = app_id, False, []
            try:
                with open(path, errors="ignore") as f:
                    in_entry = False
                    for line in f:
                        line = line.strip()
                        if line.startswith("["):
                            in_entry = line == "[Desktop Entry]"
                        elif in_entry and line.startswith("Name="):
                            name = line[5:]
                        elif in_entry and line.startswith("Categories="):
                            cats = [c for c in line[11:].split(";") if c]
                        elif in_entry and line in ("NoDisplay=true", "Hidden=true"):
                            hidden = True
            except OSError:
                continue
            if hidden:
                continue
            if query and query.lower() not in (app_id + " " + name).lower():
                continue
            apps.append({"id": app_id, "name": name, **({"categories": cats} if categories else {})})
    return apps


def dock_config():
    if MAC:
        dock = read_json(DOCK, {})
        return {"position": dock.get("position", "bottom"), "autohide": dock.get("autoHide", False),
                "dock": dock.get("dock", "petal")}
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
        "current_mode": petal("current") if MAC else run("omarchy-shell", "petal", "current"),
        "dock": dock_config(),
        "files": {"settings": SETTINGS, "modes": MODES, "instructions": INSTRUCTIONS,
                  "plugin_source": (os.path.join(PERSONAL, "macos") if os.path.exists(os.path.join(PERSONAL, "macos", "Package.swift"))
                                    else os.environ.get("PETAL_SOURCE", "")) if MAC else PLUGIN_DIR,
                  **({"app": os.environ.get("PETAL_APP", "")} if MAC else {})},
        "personal": {"source": PERSONAL, "set_up": os.path.exists(os.path.join(PERSONAL, ".git", "petal-personal.json")), "how": PERSONAL_HOW},
    }


def t_set_settings(args):
    changes = args.get("settings") or {}
    unknown = [k for k in changes if k not in SETTINGS_SCHEMA]
    if unknown:
        raise ValueError("Unknown settings: %s. Use petal_get_state to see them all." % ", ".join(unknown))
    settings = read_json(SETTINGS, {})
    # What Petal AI may do unasked, and what it may look at, are the person's to widen, never the AI's.
    if "aiAllowed" in changes and not set(changes["aiAllowed"] or []) <= set(settings.get("aiAllowed", [])):
        raise ValueError("Only the person can allow more, with Always on Petal's card or in its settings.")
    if changes.get("claudeAccess") == "full" and settings.get("claudeAccess") != "full":
        raise ValueError("Only the person can turn on Full access, in the chat's options or Petal's settings.")
    # Using the person's apps: the AI may turn it off, never back on.
    if "computerUse" in changes and changes["computerUse"] is not False and not computer_use_on(settings):
        raise ValueError("Only the person can turn on using apps (computerUse), in Petal's settings.")
    for key in ("aiNeverLook", "aiAllowed"):
        if key in changes and not (isinstance(changes[key], list) and all(isinstance(v, str) for v in changes[key])):
            raise ValueError("%s is a list." % key)
    if "aiNeverLook" in changes and not set(settings.get("aiNeverLook", SETTINGS_SCHEMA["aiNeverLook"][0])) <= set(changes["aiNeverLook"] or []):
        raise ValueError("Only the person can take an app off the private list, in Petal's settings.")
    settings.update(changes)
    write_json(SETTINGS, settings)
    return {"ok": True, "changed": changes}


def computer_use_on(settings):
    """Using apps is on in these settings (missing: its default, on)."""
    return settings.get("computerUse", SETTINGS_SCHEMA["computerUse"][0]) is True


def t_reset_settings(args):
    keys = args.get("keys") or []
    settings = read_json(SETTINGS, {})
    # Never the private list, which only the person shortens, nor using apps once it's off, which only they turn on.
    kept = {"claudePath", "aiNeverLook"} | (set() if computer_use_on(settings) else {"computerUse"})
    for k in keys or list(SETTINGS_SCHEMA):
        if k in SETTINGS_SCHEMA and k not in kept:
            settings[k] = SETTINGS_SCHEMA[k][0]
    write_json(SETTINGS, settings)
    return {"ok": True, "reset": keys or "all"}


def t_set_dock(args):
    if MAC:
        return mac_set_dock(args)
    done = {}
    if "position" in args:
        if args["position"] not in ("bottom", "top", "left", "right"):
            raise ValueError("position must be bottom, top, left or right")
        done["position"] = run("omarchy-dock", "position", args["position"])
    if "autohide" in args:
        done["autohide"] = run("omarchy-dock", "autohide", "on" if args["autohide"] else "off")
    return done


def mac_set_dock(args):
    dock, done = read_json(DOCK, {}), {}
    if "position" in args:
        if args["position"] not in ("bottom", "left", "right"):
            raise ValueError("position must be bottom, left or right (the menu bar holds the top)")
        dock["position"] = done["position"] = args["position"]
    if "autohide" in args:
        dock["autoHide"] = done["autohide"] = bool(args["autohide"])
    write_json(DOCK, dock)
    if "use" in args:
        if args["use"] not in ("petal", "macos"):
            raise ValueError("use must be petal or macos")
        done["use"] = petal("dock", args["use"])
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
               "focusDelay": 0, "distracting": False, "hold": False, "allow": []}
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
    if MAC:
        return {"result": petal("mode", args.get("id", ""))}
    return {"result": run("omarchy-shell", "petal", "mode", args.get("id", "")) or "ok"}


def t_list_apps(args):
    return installed_apps(args.get("query", ""))


def t_reload(_):
    if MAC:
        return {"ok": True, "note": petal("restart") + "; the Claude panel closes."}
    # `petal restart` also checks the dock comes back when the user has changed Petal's code (petal personal).
    cli = os.path.join(HOME, ".local/bin/petal")
    command = [cli, "restart"] if os.access(cli, os.X_OK) else ["omarchy", "restart", "shell"]
    subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return {"ok": True, "note": "Omarchy's shell (and Petal) is restarting; the Claude panel closes."}


# ── Activity, suggestions, summary (from Petal's private, local history) ──
# Petal writes one line a minute while the person is at the computer:
#   {"t": <unix seconds>, "app": "<desktop or bundle id>", "mode": "<mode id>", "ws": <workspace>}
# and one per focus card answer: {"t", "card": "back" | "switch" | "close", "app", "mode"}.
# Never titles, URLs or file names; 30 days kept; nothing leaves the machine.

STATE = (os.path.join(HOME, "Library", "Application Support", "Petal") if MAC
         else os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "petal"))
ACTIVITY = os.path.join(STATE, "activity.jsonl")
SUGGESTIONS = os.path.join(CONFIG, "suggestions.json")
KEEP_DAYS = 30
DAY = 86400


def read_activity(since=0):
    out = []
    try:
        with open(ACTIVITY, errors="ignore") as f:
            for line in f:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and isinstance(row.get("t"), (int, float)) and row["t"] >= since:
                    out.append(row)
    except OSError:
        pass
    return out


def prune_activity():
    """Keeps the last 30 days (Petal runs this when it starts)."""
    if not os.path.exists(ACTIVITY):
        return 0
    cutoff = time.time() - KEEP_DAYS * DAY
    keep = read_activity(cutoff)
    tmp = ACTIVITY + ".tmp"
    with open(tmp, "w") as f:
        for row in keep:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    os.replace(tmp, ACTIVITY)
    return len(keep)


def day_of(t):
    return time.strftime("%Y-%m-%d", time.localtime(t))


def app_names():
    return {a["id"]: a["name"] for a in installed_apps()}


def name_list(names):
    names = list(names)
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def dismissed():
    return set(read_json(SUGGESTIONS, {}).get("dismissed", []))


# A name for a set of apps, from what their desktop entries say they are (Omarchy).
CATEGORY_MODES = [
    ("Building", {"Development", "IDE", "TerminalEmulator"}),
    ("Design", {"Graphics", "2DGraphics", "3DGraphics", "RasterGraphics", "VectorGraphics", "Photography"}),
    ("Writing", {"Office", "WordProcessor", "TextEditor"}),
    ("Social", {"Chat", "InstantMessaging", "Email", "Telephony"}),
    ("Media", {"AudioVideo", "Audio", "Video", "Music", "Player"}),
    ("Play", {"Game"}),
    ("Study", {"Education", "Science"}),
]


def guess_name(app_ids, taken):
    cats = {a["id"]: set(a.get("categories", [])) for a in installed_apps(categories=True)}
    best, votes = "", 0
    for name, wanted in CATEGORY_MODES:
        n = sum(1 for a in app_ids if cats.get(a, set()) & wanted)
        if n > votes:
            best, votes = name, n
    if votes * 2 < len(app_ids) or best.lower() in taken:
        return ""
    return best


def t_suggestions(_):
    settings = read_json(SETTINGS, {})
    if not settings.get("activityLog", True) or not settings.get("suggestModes", True):
        return {"suggestions": [], "note": "Suggestions are off (activityLog or suggestModes)."}
    rows = [r for r in read_activity(time.time() - 14 * DAY) if r.get("app") and "card" not in r]
    modes = read_json(MODES, {}).get("modes", [])
    names = app_names()
    skip = dismissed()
    out = []

    # 1. Apps used together: the same 30-minute windows, on 3 or more days, for 3 hours or more.
    windows = {}
    for r in rows:
        w = windows.setdefault(int(r["t"] // 1800), {})
        w[r["app"]] = w.get(r["app"], 0) + 1
    # An app counts in a window it had at least two minutes of.
    windows = {k: {a: m for a, m in w.items() if m >= 2} for k, w in windows.items()}

    def together(apps):
        days, minutes = set(), 0
        for k, w in windows.items():
            if all(a in w for a in apps):
                days.add(day_of(k * 1800))
                minutes += sum(w[a] for a in apps)
        return days, minutes

    def strong(apps):
        days, minutes = together(apps)
        return len(days) >= 3 and minutes >= 180

    counts = {}
    for w in windows.values():
        for a in w:
            counts[a] = counts.get(a, 0) + w[a]
    pairs = []
    ranked = sorted(counts, key=lambda a: -counts[a])[:30]
    for i, a in enumerate(ranked):
        for b in ranked[i + 1:]:
            if strong([a, b]):
                pairs.append((together([a, b])[1], a, b))
    used = set()
    held = [set(m.get("apps", [])) for m in modes]
    for _, a, b in sorted(pairs, reverse=True):
        if a in used or b in used:
            continue
        group = [a, b]
        for c in ranked:
            if len(group) >= 6:
                break
            if c not in group and c not in used and strong(group + [c]):
                group.append(c)
        group.sort()
        if any(set(group) <= h for h in held):
            continue
        key = "+".join(group)
        if key in skip:
            continue
        used.update(group)
        days, minutes = together(group)
        shown = [names.get(g, g) for g in group]
        name = guess_name(group, {str(m.get("name", "")).lower() for m in modes})
        out.append({"kind": "new", "key": key, "apps": group, "names": shown, "name": name,
                    "days": len(days), "minutes": minutes,
                    "text": "You often use %s together. %s" % (name_list(shown), "Make a %s mode?" % name if name else "Make a mode for them?")})

    # 2. An app used in a mode's workspaces on 3 or more days that isn't in that mode.
    by_mode = {}
    for r in rows:
        if r.get("mode"):
            by_mode.setdefault((r["app"], r["mode"]), set()).add(day_of(r["t"]))
    for (app, mode_id), days in sorted(by_mode.items(), key=lambda kv: -len(kv[1])):
        mode = next((m for m in modes if m.get("id") == mode_id), None)
        key = "add:%s:%s" % (app, mode_id)
        if len(days) < 3 or not mode or app in used or app in mode.get("apps", []) or app in mode.get("allow", []) or key in skip:
            continue
        if app not in names:
            continue   # not an app the dock can show (a helper or an uninstalled one)
        out.append({"kind": "add", "key": key, "app": app, "name": names.get(app, app), "mode": mode_id,
                    "modeName": mode.get("name", mode_id), "days": len(days),
                    "text": "You use %s in %s most days. Keep it there?" % (names.get(app, app), mode.get("name", mode_id))})
    return {"suggestions": out}


def dismiss_suggestion(key):
    data = read_json(SUGGESTIONS, {})
    keys = [k for k in data.get("dismissed", []) if k != key] + [key]
    data["dismissed"] = keys
    write_json(SUGGESTIONS, data)
    return {"ok": True, "dismissed": key}


def duration(minutes):
    if minutes < 60:
        return "%d min" % minutes
    hours = minutes / 60
    return "%d h" % round(hours) if hours >= 10 else ("%.1f h" % hours).replace(".0 h", " h")


def t_summary(args):
    """The `days` (7 by default, up to 30) before today: time in each mode, top apps, focus cards."""
    days = max(1, min(30, int((args or {}).get("days") or 7)))
    today = time.localtime()
    end = time.mktime((today.tm_year, today.tm_mon, today.tm_mday, 0, 0, 0, 0, 0, -1))
    start = end - days * DAY
    rows = [r for r in read_activity(start) if r["t"] < end]
    modes = {m.get("id"): m for m in read_json(MODES, {}).get("modes", [])}
    names = app_names()
    per_mode = {}
    cards = {"shown": 0, "back": 0, "switch": 0, "close": 0}
    for r in rows:
        if "card" in r:
            cards["shown"] += 1
            if r["card"] in cards:
                cards[r["card"]] += 1
            continue
        if not r.get("app"):
            continue
        m = per_mode.setdefault(r.get("mode") or "", {})
        m[r["app"]] = m.get(r["app"], 0) + 1
    out = []
    for mode_id, apps in sorted(per_mode.items(), key=lambda kv: -sum(kv[1].values())):
        total = sum(apps.values())
        top = sorted(apps.items(), key=lambda kv: -kv[1])[:3]
        mode = modes.get(mode_id, {})
        out.append({"id": mode_id, "name": mode.get("name") or mode_id or "No mode", "color": mode.get("color", ""),
                    "icon": mode.get("icon", ""), "minutes": total,
                    "apps": [{"id": a, "name": names.get(a, a), "minutes": n} for a, n in top]})
    lines = []
    for m in out:
        line = "%s in %s" % (duration(m["minutes"]), m["name"])
        first = m["apps"][0] if m["apps"] else None
        if first and first["minutes"] * 2 >= m["minutes"]:
            line += ", most of it in %s" % first["name"]
        elif len(m["apps"]) >= 2:
            line += ", mostly %s and %s" % (m["apps"][0]["name"], m["apps"][1]["name"])
        lines.append(line + ".")
    if cards["shown"]:
        lines.append("%d focus card%s; you went back %d time%s." % (cards["shown"], "" if cards["shown"] == 1 else "s",
                     cards["back"], "" if cards["back"] == 1 else "s"))
    if not out:
        lines = ["Nothing recorded for these days yet." if read_json(SETTINGS, {}).get("activityLog", True)
                 else "The activity history is off (activityLog), so there's nothing to sum up."]
    return {"from": day_of(start), "to": day_of(end - 1), "minutes": sum(m["minutes"] for m in out),
            "modes": out, "cards": cards, "lines": lines}


# ── Recipes: a dock to share, as one .petal file ───────────────────────
LOOK_KEYS = ["dockColor", "dockOpacity", "dockBorderColor", "dockBorderOpacity", "dockRadius", "dockSheen", "dockMargin",
             "iconSize", "iconPadding", "idleOpacity", "separators", "hoverLiftAmount", "glowStrength", "accentColor",
             "popupColor", "popupOpacity", "font", "tooltips", "hoverLift", "appGlow", "previews", "minimized", "badges",
             "bounce", "progress", "quickActions", "recentFiles", "dropToOpen", "nowPlaying", "stacks", "trash",
             "magnification", "magnificationAmount"]
PLATFORM = "macos" if MAC else "omarchy"


def shareable_mode(mode):
    m = {k: v for k, v in mode.items() if k != "workspaces"}
    if isinstance(m.get("hyprland"), dict):   # a wallpaper is a path on this computer
        m["hyprland"] = {k: v for k, v in m["hyprland"].items() if k != "wallpaper"}
        if not m["hyprland"]:
            del m["hyprland"]
    return m


def t_export_recipe(args):
    name = str(args.get("name") or "My Petal").strip()[:60] or "My Petal"
    path = os.path.expanduser(str(args.get("path") or ""))
    if not path:
        safe = "".join(c if c.isalnum() or c in " -_" else "-" for c in name).strip() or "petal"
        path = os.path.join(HOME, safe + ".petal")
    if os.path.isdir(path):
        path = os.path.join(path, name + ".petal")
    if not path.endswith(".petal"):
        path += ".petal"
    modes = [shareable_mode(m) for m in read_json(MODES, {}).get("modes", [])]
    names = app_names()
    apps = {}
    for m in modes:
        for a in list(m.get("apps", [])) + list(m.get("allow", [])):
            apps[a] = names.get(a, a)
    settings = read_json(SETTINGS, {})
    look = {k: settings.get(k, SETTINGS_SCHEMA[k][0]) for k in LOOK_KEYS if k in SETTINGS_SCHEMA}
    dock = dock_config()
    recipe = {"petal": 1, "name": name, "from": PLATFORM, "modes": modes, "apps": apps, "settings": look,
              "dock": {"position": dock.get("position", "bottom"), "autoHide": bool(dock.get("autohide", False))}}
    write_json(path, recipe)
    return {"path": path, "modes": [m.get("name", m.get("id")) for m in modes]}


def read_recipe(path):
    path = os.path.expanduser(str(path or ""))
    if not path:
        raise ValueError("path is required")
    recipe = read_json(path, None)
    if not isinstance(recipe, dict) or recipe.get("petal") != 1 or not isinstance(recipe.get("modes"), list):
        raise ValueError("%s isn't a Petal recipe" % path)
    return recipe


def plan_import(recipe, look):
    """What importing would change: the modes as they'd be added, the apps that aren't here, the look."""
    data = read_json(MODES, {"defaultMode": "", "workspaces": {}, "modes": []})
    taken = {m.get("id") for m in data.get("modes", [])}
    taken_names = {str(m.get("name", "")).lower() for m in data.get("modes", [])}
    installed = installed_apps()
    ids = {a["id"] for a in installed}
    by_name = {}
    for a in installed:
        by_name.setdefault(a["name"].lower(), a["id"])
    names = recipe.get("apps") if isinstance(recipe.get("apps"), dict) else {}
    same = recipe.get("from") == PLATFORM
    missing, modes = [], []

    def resolve(app):
        if same and app in ids:
            return app
        found = by_name.get(str(names.get(app, "")).lower()) or (by_name.get(app.lower()) if not same else None)
        if found:
            return found
        label = names.get(app, app)
        if label not in missing:
            missing.append(label)
        return None

    for raw in recipe["modes"]:
        if not isinstance(raw, dict) or not raw.get("id"):
            continue
        m = shareable_mode(raw)
        base = "".join(c for c in str(m["id"]).lower() if c.isalnum() or c in "-_") or "mode"
        mid, n = base, 2
        while mid in taken:
            mid, n = "%s-%d" % (base, n), n + 1
        taken.add(mid)
        m["id"] = mid
        for field in ("apps", "allow"):
            resolved = [resolve(a) for a in m.get(field, []) if isinstance(a, str)]
            m[field] = list(dict.fromkeys(a for a in resolved if a))
        # Icons are Nerd Font glyphs on Omarchy and SF Symbol names on macOS.
        icon = str(m.get("icon") or "")
        glyph = len(icon) <= 2 and not icon.isascii()
        if MAC and glyph:
            m["icon"] = "circle"
        elif not MAC and not glyph:
            m["icon"] = "●"
        name, n = str(m.get("name") or mid.title()), 2
        while name.lower() in taken_names:
            name, n = "%s %d" % (str(m.get("name") or mid.title()), n), n + 1
        taken_names.add(name.lower())
        m["name"] = name
        modes.append(m)
    plan = {"modes": modes, "missing": missing, "look": False}
    if look:
        settings = read_json(SETTINGS, {})
        changes = {}
        for k, v in (recipe.get("settings") or {}).items():
            if k in LOOK_KEYS and k in SETTINGS_SCHEMA and settings.get(k, SETTINGS_SCHEMA[k][0]) != v:
                changes[k] = {"from": settings.get(k, SETTINGS_SCHEMA[k][0]), "to": v}
        plan["look"] = True
        plan["settings"] = changes
        dock, now = recipe.get("dock") or {}, dock_config()
        plan["dock"] = {k: v for k, v in (("position", dock.get("position")), ("autohide", dock.get("autoHide")))
                        if v is not None and now.get(k) != v}
    return plan


def t_import_recipe(args):
    recipe = read_recipe(args.get("path"))
    plan = plan_import(recipe, bool(args.get("look")))
    if args.get("preview"):   # used by `petal recipe import` and the Petal menu to show what will change first
        return plan
    data = read_json(MODES, {"defaultMode": "", "workspaces": {}, "modes": []})
    data.setdefault("modes", []).extend(plan["modes"])
    data.setdefault("workspaces", {})
    if not data.get("defaultMode") and data["modes"]:
        data["defaultMode"] = data["modes"][0]["id"]
    write_json(MODES, data)
    if plan.get("settings"):
        settings = read_json(SETTINGS, {})
        settings.update({k: v["to"] for k, v in plan["settings"].items()})
        write_json(SETTINGS, settings)
    if plan.get("dock"):
        position = plan["dock"].get("position")
        if position and (position in ("bottom", "left", "right") or (position == "top" and not MAC)):
            t_set_dock({"position": position})
        if "autohide" in plan["dock"]:
            t_set_dock({"autohide": plan["dock"]["autohide"]})
    return {"modes": [{"id": m["id"], "name": m.get("name", m["id"]), "apps": m.get("apps", [])} for m in plan["modes"]],
            "missing": plan["missing"], "look": plan["look"]}


_lock_depth = 0


@contextlib.contextmanager
def locked():
    """Holds ~/.config/petal/.lock (shared with Petal for macOS), so two processes changing the files take turns:
    each reads, changes and writes inside it. Nested holds (a tool calling another) don't lock again."""
    global _lock_depth
    if _lock_depth:
        _lock_depth += 1
        try:
            yield
        finally:
            _lock_depth -= 1
        return
    os.makedirs(CONFIG, exist_ok=True)
    with open(os.path.join(CONFIG, ".lock"), "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        _lock_depth = 1
        try:
            yield
        finally:
            _lock_depth = 0
            fcntl.flock(f, fcntl.LOCK_UN)


def writes(fn, name):
    """A tool that changes settings, modes or the dock. On a Mac with Petal running, Petal does it itself, in order
    with every other change (two sessions changing settings at once never undo each other); otherwise it's done
    here, under the lock."""
    def run(args):
        if MAC and not _lock_depth and not args.get("preview"):
            reply = petal("mcpCall", name, json.dumps(args), timeout=30)
            if not reply.startswith("Petal isn't running") and not reply.startswith("unknown function"):
                try:
                    out = json.loads(reply)
                except ValueError:
                    raise ValueError(reply)
                if isinstance(out, dict) and out.get("error"):
                    raise ValueError(out["error"])
                return out.get("result", {}) if isinstance(out, dict) else out
        with locked():
            return fn(args)
    return run


t_set_settings = writes(t_set_settings, "petal_set_settings")
t_reset_settings = writes(t_reset_settings, "petal_reset_settings")
t_set_dock = writes(t_set_dock, "petal_set_dock")
t_save_mode = writes(t_save_mode, "petal_save_mode")
t_delete_mode = writes(t_delete_mode, "petal_delete_mode")
t_set_default_mode = writes(t_set_default_mode, "petal_set_default_mode")
t_import_recipe = writes(t_import_recipe, "petal_import_recipe")


def not_yet(_):
    raise ValueError("This needs a newer Petal.")


def assist(name):
    """Petal AI's tools on macOS: the running Petal does them, with its own permissions (and asks first)."""
    def run(args):
        # Which chat asks: a Petal chat's note (Petal sets PETAL_NOTE for its own), answered about the note's window;
        # any other AI session is this process, so two sessions never share what they looked at or were allowed.
        caller = os.environ.get("PETAL_NOTE") or "mcp-py-%d" % os.getpid()
        # Petal answers within 150 s, or sends a space every 10 s while a card is up for the person (each wait on the
        # socket starts again), so their answer always arrives; giving up answers the card Don't.
        reply = petal("assist", name, json.dumps(args), caller, timeout=150)
        try:
            out = json.loads(reply)
        except ValueError:
            raise ValueError(reply or "Petal isn't running")
        if isinstance(out, dict) and out.get("error"):
            raise ValueError(out["error"])
        return out
    return run


# Petal AI on the Mac: seeing what's in front and acting on the Mac through Petal's permissions. (Omarchy: later.)
ASSIST_TOOLS = {
    "petal_look": (assist("petal_look"), "What the user is looking at now: the app and window in front, the browser tab's address and title, selected text, the current mode and which apps are open. In a sticky note's chat it looks at the note's own window (a note on all of an app: that app's window in front; a note on a tab: its window, with the note's tab as noteTab, only while that tab is the one showing), even after the user has moved on (front: true looks at what's in front now instead). screenshot: \"window\" (the front window, or app's) or \"screen\" saves a PNG and returns its path to read; fields that may hold a password, card number, security code or key are blacked out, and a window Petal can't check isn't shown. clipboard: true adds the clipboard's text. Use it when the user says this, here, what I'm looking at.",
                   {"screenshot": {"type": "string", "enum": ["", "window", "screen"]}, "app": {"type": "string", "description": "look at this app instead of the one in front"},
                    "clipboard": {"type": "boolean"}, "front": {"type": "boolean", "description": "in a sticky note: what's in front now, not the note's window"}}),
    "petal_apps": (assist("petal_apps"), "Open, quit, hide or bring forward an app (by name or bundle id); open with `open` set opens that address or file (in `app` if given). Quitting asks the user first.",
                   {"action": {"type": "string", "enum": ["open", "quit", "hide", "focus"]}, "app": {"type": "string"}, "open": {"type": "string", "description": "an https:// address or a file path"}}),
    "petal_windows": (assist("petal_windows"), "The user's windows: list them (id, app, title, minimized, here = on this Desktop), or focus, minimize, close (asks first) or arrange one (layout: left, right, top, bottom, full, center; the dock's room is kept). Pick a window by its id from list, or a word of its title, within `app`.",
                      {"action": {"type": "string", "enum": ["list", "focus", "minimize", "close", "arrange"]}, "app": {"type": "string"},
                       "window": {"type": "string"}, "layout": {"type": "string", "enum": ["left", "right", "top", "bottom", "full", "center"]}}),
    "petal_trash": (assist("petal_trash"), "Move files or folders to the Trash (asks the user first); never delete files any other way. undo: true puts the last ones back.",
                    {"paths": {"type": "array", "items": {"type": "string"}}, "undo": {"type": "boolean"}}),
    "petal_remember": (assist("petal_remember"), "Remember something that will help with this user later: a preference, a habit, how they like things done. mode: a mode id to keep it to that mode (\"\" for everywhere). learned: true when you noticed it yourself rather than being asked. Keep each one short.",
                       {"text": {"type": "string"}, "mode": {"type": "string"}, "learned": {"type": "boolean"}}),
    "petal_forget": (assist("petal_forget"), "Forget a memory: by its id, or every one containing `text`. Do it when the user says to, or when one turns out wrong or out of date.",
                     {"id": {"type": "string"}, "text": {"type": "string"}}),
    "petal_show": (assist("petal_show"), "Open a page in its own window, kept so it can be opened again: a summary of their month, a report, a table, a chart. markdown, or html (a whole page; charts as inline SVG, no outside scripts or images), or path to an .html file you wrote. Each call makes a new page; to change one you made, pass update: the path it returned. Say in one line what's on it.",
                   {"title": {"type": "string"}, "markdown": {"type": "string"}, "html": {"type": "string"}, "path": {"type": "string"},
                    "update": {"type": "string", "description": "the path petal_show returned for a page you made, to change that page in place"}}),
    "petal_vault": (assist("petal_vault"), "The user's vault (macOS), in their Keychain: logins, contact info (relationship: me, girlfriend, mom…), addresses (each may belong to a contact), payment info and API keys. "
                    "You see usernames, contact info and addresses in full, and a card's name, last4 and expiry; never a password, card number, security code or key: Petal fills those into fields itself. "
                    "action list (kind, site): what's saved. fill (fields {field: id from petal_ui}, item: an id from list; for a login, item may be left out and Petal finds the one saved for the page): "
                    "fields are username, password, name, email, phone, street, street2, city, region, postalCode, country (a country menu too), number, expiry, month, year, securityCode, value (an API key, or an unsorted item's secret); submit: true presses Return after the last (not with payment info: press the order button with petal_act; Return asks to use the app as petal_act does). "
                    "An item of kind unsorted was saved before the vault had kinds: you see only its title, and filling it (field value) asks the user every time; they sort it in Settings › Vault. "
                    "Petal decides from the page it reads itself: a login fills by itself only on its own site (or http://localhost) or app, an API key on its service's site, this Mac's pages or an app; elsewhere the user is asked, once for all the fields. Fill one page or app at a time. "
                    "Payment info fills only on https pages after one Buy card per checkout: pass buying (what, in a few words) and price; Buy covers that card on that exact page, in that window and tab, for the rest of the reply (another page or tab ends it, and Petal asks again); then place the order there (using the browser may ask once, as any app does); after Don't, stop. "
                    "request (kind login, contact, address, card or apiKey; fields to fill, title, why): the user types what's missing into Petal's card (never into the chat); for a login, Submit fills the page and saves it. "
                    "new_login (password_id, confirm_id, username_id, username; symbols false or allowed_symbols for sites that limit them): Petal makes a strong password, saves it for the page's site and fills it. "
                    "From a session outside Petal's own chat (T3 Code, a terminal), the first time your agent uses an item in a project (fill, or new_login for making logins) Petal asks the user (Always for this project, Allow once, Don't); they may allow it ahead in Settings › Vault › Agents. "
                    "To use an API key in a command (a test, a BYOK app on localhost), run it with the petal command: petal run --key \"<title>\" -- <command>; Petal puts the key in its service's variable (ANTHROPIC_API_KEY, OPENAI_API_KEY…; --env NAME for another, --stdin for its input) and takes it out of what the command prints. You never see a key: never try to get one out. "
                    "If the user declines, don't find another way.",
                    {"action": {"type": "string", "enum": ["list", "fill", "request", "new_login", "use"]},
                     "item": {"type": "string", "description": "an item's id from list (or its title)"},
                     "fields": {"type": "object", "additionalProperties": {"type": "string"}, "description": "fill or request: {field: id from petal_ui}, like {\"username\": \"e3\", \"password\": \"e4\"}"},
                     "field": {"type": "string"}, "id": {"type": "string", "description": "one field's id from petal_ui (with field)"},
                     "kind": {"type": "string", "enum": ["login", "contact", "address", "card", "apiKey", "unsorted"], "description": "list: unsorted too; request: not unsorted"}, "site": {"type": "string"},
                     "buying": {"type": "string", "description": "fill with payment info: what you're buying, in a few words"}, "price": {"type": "string"},
                     "yearFormat": {"type": "string", "enum": ["YYYY", "YY"], "description": "fill a card's year or expiry: how the field wants the year, when its placeholder or label doesn't say (Petal reads those itself, and a year menu's own items)"},
                     "submit": {"type": "boolean", "description": "fill: press Return after the last field (never with payment info)"}, "title": {"type": "string"}, "why": {"type": "string"}, "username": {"type": "string"},
                     "password_id": {"type": "string"}, "confirm_id": {"type": "string"}, "username_id": {"type": "string"},
                     "symbols": {"type": "boolean"}, "allowed_symbols": {"type": "string"}, "length": {"type": "integer"},
                     "name": {"type": "string", "description": "use (older sessions): an item's title; it fills like fill, into id or the field petal_ui saw with the cursor"},
                     "task": {"type": "string", "description": "sessions outside Petal's own chat: the same few words for the task's acts"}}),
    "petal_memories": (assist("petal_memories"), "What Petal AI remembers about the user (everywhere, and per mode); mode limits it to one mode's and the everywhere ones.",
                       {"mode": {"type": "string"}}),
    "petal_ui": (assist("petal_ui"), "The controls of the window in front (in a sticky note's chat, the note's own window; a note on a tab reads and acts only while its tab is the one showing), to use with petal_act: buttons, links, text fields, checkboxes, menus, tabs, rows and the like, visible ones first, up to 150. "
                 "Each has an id (e12), role, name, value (never a password field's; a secret saved in the vault shows as (hidden) wherever it appears) and frame [x, y, w, h] in screen points. The ids last until the next petal_ui or 5 minutes: call it again whenever the window changes. "
                 "app: another app's front window; front: true in a sticky note uses what's in front now; find: only controls whose name has this word (for a big window). Apps the user keeps private give only their name.",
                 {"app": {"type": "string"}, "front": {"type": "boolean"}, "find": {"type": "string", "description": "a word in the control's name or value"}}),
    "petal_act": (assist("petal_act"), "Use a control from the last petal_ui, through Accessibility, with Petal's own pink pointer (the user's pointer never moves). "
                  "In a sticky note's chat, acting on the note's own window, it works in the background while the user works elsewhere: no pointer, nothing comes forward, their keyboard untouched (only when they have that window in front does it use the pointer, and never while they're typing in it). "
                  "Some acts can't be done in the background (menus and keys while they use that app, copying and pasting, the vault, a link or file that would open in another app, an app that ignores background typing, a tab that isn't showing): then nothing is done and it says the window must be in front; ask the user in one line to bring it forward (clicking the note in the AI button's preview does), don't bring it forward yourself, then petal_ui again. "
                  "action press (id): presses a button, link, checkbox, tab or row. type (id, text): puts text in a field (replace: false inserts at the cursor instead; submit: true presses Return after). "
                  "focus (id). scroll (id; direction up, down, left or right scrolls its area by most of a page; none brings the control into view). "
                  "menu (path, like \"File > Export…\"): chooses a menu bar item. key (key, like cmd-s, cmd-shift-z, return, escape, tab, down; id focuses that control first): a shortcut its menus have is chosen there, other keys go to the app, which comes forward to take them. "
                  "menu and key go to the window the last petal_ui looked at (app, if given, must be its app), brought to the front of its app first. The first use of an app in a reply asks the user (in an AI session outside Petal's own chat, the first in a task: name it in task; a new task, two quiet minutes or a Stop asks again). Each act checks the window hasn't moved or changed since petal_ui; when it has, call petal_ui again. "
                  "What only a real click could do, it says so: ask the user to do it. Never for password fields (petal_vault fills saved passwords) or private apps.",
                  {"action": {"type": "string", "enum": ["press", "type", "focus", "scroll", "menu", "key"]}, "id": {"type": "string", "description": "a control's id from petal_ui, like e12"},
                   "text": {"type": "string"}, "replace": {"type": "boolean", "description": "type: replace what's in the field (default true)"}, "submit": {"type": "boolean", "description": "type: press Return after"},
                   "direction": {"type": "string", "enum": ["up", "down", "left", "right"]}, "path": {"type": "string", "description": "menu: like File > Export…"},
                   "key": {"type": "string", "description": "key: like cmd-s"}, "app": {"type": "string", "description": "menu or key: this app instead of the last petal_ui's"},
                   "task": {"type": "string", "description": "a few words for the task this act is part of (sessions outside Petal's own chat): keep it the same across the task's acts"}}),
    "petal_routines": (assist("petal_routines"), "The user's routines (what Petal does by itself: id, their words, trigger, actions, on, last run) and the latest of what they did (history; canPutBack).", {}),
    "petal_routine_save": (assist("petal_routine_save"),
                           "Make a routine from what the user asked, or change one (id). words: their own words. You fill trigger and actions from them, once; Petal runs it without AI except for sorting files by what they are. "
                           "trigger.on: \"file\" (a file lands in folder, e.g. ~/Downloads, ~/Desktop or screenshots; types: kinds pdf, image, video, audio, archive, installer, document, code or extensions; named: words in its name; both optional), "
                           "\"app\" (app: name or bundle id; when: \"opens\" or \"front\"), \"mode\" (mode: a mode id), \"time\" (at: \"HH:MM\"; days: 1 = Monday … 7, empty = every day). "
                           "actions, in order: {do: \"sort\", by: \"ai\" (by what each file is; the quick AI picks an existing subfolder or names a new one for similar files) or \"kind\" (Images, PDFs, …), into: where the subfolders go (the files' folder by default)}, "
                           "{do: \"move\", to: a folder (a name alone is inside the files' folder)}, {do: \"mode\", mode}, {do: \"open\", apps: names, bundle ids or https:// addresses}, {do: \"hide\", apps}, {do: \"shortcut\", name}. "
                           "sort and move act on the new file; with an app, mode or time trigger they take folder's files. Files are only moved, never deleted. It acts on new files only: when the answer says files are there now, offer petal_routine_run.",
                           {"id": {"type": "string"}, "name": {"type": "string", "description": "a short name"}, "words": {"type": "string"},
                            "trigger": {"type": "object"}, "actions": {"type": "array", "items": {"type": "object"}}, "on": {"type": "boolean"}}),
    "petal_routine_run": (assist("petal_routine_run"), "Run a routine now on the files already in its folder. dryRun: true says what it would move where, moving nothing; without it, it does it (Petal asks the user first when it's 10 files or more). A routine that moves no files just runs its actions.",
                          {"id": {"type": "string"}, "dryRun": {"type": "boolean"}}),
    "petal_routine_undo": (assist("petal_routine_undo"), "Put back the files a routine moved: the latest run that can be, or entry (a history id from petal_routines).",
                           {"entry": {"type": "string"}}),
    "petal_routine_delete": (assist("petal_routine_delete"), "Delete a routine (what it moved stays where it is, and can still be put back).", {"id": {"type": "string"}}),
    "petal_notes": (assist("petal_notes"), "The user's Petal Notes (macOS): their own notes, Markdown files on paper stuck to places (a sentence, a tab, a window, all of an app, a file, a Desktop), one notebook (folder) each; Inbox by default. "
                    "Search them (query: words, any order; notebook; here: true for the notes placed now, on the window in front or on the Desktop showing, or in the margin of Petal's viewer when it's in front; limit). Each has id (a handle for these tools: the same note keeps it when it's renamed or moved; never a file or path), title, notebook, preview, places (in words), modified and onScreen; notebooks lists the notebooks. Saved secrets are hidden as (hidden), and nothing is told while the vault can't be read. When the user asks what they noted, wrote down or saved, search here first and say which notes you used (they show as chips under your answer). A Private notebook's notes are never listed, except to a helper of a note inside it.",
                    {"query": {"type": "string"}, "notebook": {"type": "string"}, "here": {"type": "boolean"}, "limit": {"type": "integer"}}),
    "petal_note_read": (assist("petal_note_read"), "One note whole: its text (Markdown: # headings, - [ ] checkboxes, an address alone on a line is a link card, ![picture N] its Nth picture, > lines are Petal's own words), places, notebook and dates. What the note's helper answered comes as helper (marked as the helper's, not the user's words); its steps, watcher and task live in its front matter, which only Petal writes; never write an @Petal line to make something run (only the person's Return runs a helper). id: the handle from petal_notes, or its title as shown when only one note has that title (else the answer lists the notes' ids to pick from).",
                        {"id": {"type": "string"}}),
    "petal_note_write": (assist("petal_note_write"), "Write a note. No id: a new note with text in notebook (default the user's own default; a new name makes one); stick: \"here\" sticks it to what's in front (to: tab, window, app, file or desktop; else the most specific there is; with Petal's viewer in front, its file and page, or its selected passage), else it's stuck nowhere. "
                         "With id (a handle from petal_notes, or its title when only one note has it): replaces its text, or append: true adds text at its end; a ![picture N] line keeps that picture (leave them as read). A note is the user's own writing: never change their words unless they asked; add to it instead. Nothing is ever deleted.",
                         {"id": {"type": "string"}, "text": {"type": "string"}, "append": {"type": "boolean"}, "notebook": {"type": "string"},
                          "stick": {"type": "string", "enum": ["here", "none"]}, "to": {"type": "string", "enum": ["passage", "tab", "window", "app", "file", "desktop"]}}),
    "petal_note_move": (assist("petal_note_move"), "Put a note in another notebook (a new name makes the notebook). Only the note moves: its pictures stay where Petal keeps them, and its links keep working.",
                        {"id": {"type": "string"}, "notebook": {"type": "string"}}),
    "petal_note_stick": (assist("petal_note_stick"), "Stick a note to what's in front now: to tab, window, app, file or desktop (else the most specific there is: the selected sentence, its tab, its file, its window). also: true keeps its other places; remove: an index from its places takes it off that one (a note keeps at least one).",
                         {"id": {"type": "string"}, "to": {"type": "string", "enum": ["passage", "tab", "window", "app", "file", "desktop"]},
                          "also": {"type": "boolean"}, "remove": {"type": "integer"}}),
    "petal_view": (assist("petal_view"), "Open a document in Petal's viewer (macOS; part of Petal Notes): a PDF through PDFKit, or Word, PowerPoint, Keynote, Excel, Pages, Numbers, text and pictures through macOS's own Quick Look preview. "
                   "The notes on that file show in the viewer's margin, lined up with their passage, page or slide; the person selects text and presses Note for an exact spot. path: the file's full path (~/ for the home folder); only a regular file whose final destination (every link followed) is in their home folder and theirs, or on a drive or share mounted under /Volumes and readable by them; anywhere else (/tmp, /System, another user's home) is refused. page: which page or slide to show (a whole number from 1; one the document hasn't is said, and it shows where it was). "
                   "It never moves or changes the file. Says how it's shown and how many pages or slides it has; names are told with saved secrets hidden, and nothing while the vault can't be read.",
                   {"path": {"type": "string"}, "page": {"type": "integer"}}),
    "petal_view_versions": (assist("petal_view_versions"), "Try changes to a document on copies first: makes a copy of the file for each of names (\"Shorter\", \"With numbers\") in a folder of Petal's own and shows their pictures under the document in Petal's viewer, each with Use this. "
                            "Change the copies (never the file itself); their pictures follow. The answer gives set (an id for petal_view_pick) and each version's id, name and path (a version is its id; two may share a name). Picking one only tells you: change the user's own file only after they allowed it. Newer versions of the same file replace these (their copies are removed, all but a picked one; a copy you changed goes to the Trash, never deleted), and every copy is removed when the viewer closes: read the picked one while it's open.",
                            {"path": {"type": "string"}, "names": {"type": "array", "items": {"type": "string"}}}),
    "petal_view_pick": (assist("petal_view_pick"), "Which version the person picked with Use this (from your own petal_view_versions set): its id, name and copy's path, or null while they haven't. A pick is told only while the original is the very file, unchanged, the versions were made from; once it was changed, replaced, deleted or refused, the answer is null with why (\"The original changed — make versions again\"; the copies stay). Ask again right before you change the original. wait: seconds to wait for the pick (up to 120).",
                        {"set": {"type": "string"}, "wait": {"type": "integer"}}),
    "petal_note_pdf_comments": (assist("petal_note_pdf_comments"), "Write the user's notes on a PDF into it as comments (a passage's note as a highlight with its words, any other as a sticky note on its page), so they show in Preview, Acrobat and anywhere else. "
                                "By default into a copy beside it (\"Name (with notes).pdf\"); into_original: true writes into the PDF itself, only after the user allows it, and keeps the original beside it (\"Name (before notes).pdf\"). Only for a PDF petal_view could open, in a folder the user can write. Saved secrets are never written; nothing is written while the vault can't be read.",
                                {"path": {"type": "string"}, "into_original": {"type": "boolean"}}),
}


TOOLS = {
    "petal_get_state": (t_get_state, "Everything about the user's Petal dock: all settings (with help text and current values), modes, current mode, position/auto-hide and file paths. Call this first.", {}),
    "petal_set_settings": (t_set_settings, "Change one or more Petal settings (appearance like dockColor/dockOpacity/iconSize/accentColor, and feature switches like bounce/badges). Applies instantly.",
                           {"settings": {"type": "object", "description": "setting name -> new value"}}),
    "petal_reset_settings": (t_reset_settings, "Reset settings to their defaults (all, or just the given keys).",
                             {"keys": {"type": "array", "items": {"type": "string"}}}),
    "petal_set_dock": (t_set_dock, "Move the dock (position: bottom, left, right) and/or turn auto-hide on or off; use: petal or macos picks Petal or macOS's own Dock (the other turns off)." if MAC
                       else "Move the dock (position: bottom, top, left, right) and/or turn auto-hide on or off.",
                       {"position": {"type": "string", "enum": ["bottom", "left", "right"] if MAC else ["bottom", "top", "left", "right"]},
                        "autohide": {"type": "boolean"}, **({"use": {"type": "string", "enum": ["petal", "macos"]}} if MAC else {})}),
    "petal_save_mode": (t_save_mode, "Create a mode or update fields of an existing one (merges). Fields: " + "; ".join("%s: %s" % kv for kv in MODE_FIELDS.items()),
                        {"mode": {"type": "object", "description": "must include id"}}),
    "petal_delete_mode": (t_delete_mode, "Delete a mode.", {"id": {"type": "string"}}),
    "petal_set_default_mode": (t_set_default_mode, "Set the mode new %ss start in." % WORKSPACE, {"id": {"type": "string"}}),
    "petal_switch_mode": (t_switch_mode, "Switch the focused %s to a mode." % WORKSPACE, {"id": {"type": "string"}}),
    "petal_list_apps": (t_list_apps, "Installed apps (%s and name), optionally filtered by a search word. Use the ids in a mode's apps." % ("bundle id" if MAC else "desktop id"),
                        {"query": {"type": "string"}}),
    "petal_export_recipe": (globals().get("t_export_recipe", not_yet), "Save the user's dock as a shareable recipe file (.petal): modes, apps, look and features, nothing personal. Returns its path.",
                            {"path": {"type": "string", "description": "where to save it; default ~/<name>.petal"}, "name": {"type": "string"}}),
    "petal_import_recipe": (globals().get("t_import_recipe", not_yet), "Add the modes from a recipe file (.petal) someone shared, and optionally its look. Apps are matched to what's installed; the rest are listed as missing.",
                            {"path": {"type": "string"}, "look": {"type": "boolean", "description": "also use its look and features"}}),
    "petal_suggestions": (globals().get("t_suggestions", not_yet), "Modes Petal would suggest from the user's activity (new modes, or apps to add to a mode).", {}),
    "petal_summary": (globals().get("t_summary", not_yet), "The user's time in each mode (top apps, focus cards) over the last `days` (7 by default; up to 30, the history kept)" + (", or from/to (YYYY-MM-DD), with a day-by-day breakdown (byDay) for charts." if MAC else "."),
                      {"days": {"type": "integer"}, **({"from": {"type": "string"}, "to": {"type": "string"}} if MAC else {})}),
    "petal_reload": (t_reload, "Restart Petal to load a rebuilt Petal.app (settings and modes don't need this)." if MAC
                     else "Restart Omarchy's shell to load edits to Petal's own source code (settings and modes don't need this).", {}),
}


if MAC:
    TOOLS.update(ASSIST_TOOLS)


def version():
    if MAC:   # inside Petal.app: Contents/Resources/mcp/petal-mcp.py
        try:
            with open(os.path.join(PLUGIN_DIR, "..", "Info.plist"), "rb") as f:
                return plistlib.load(f).get("CFBundleShortVersionString", "")
        except (OSError, ValueError, plistlib.InvalidFileException):
            return ""
    return read_json(os.path.join(PLUGIN_DIR, "manifest.json"), {}).get("version", "")


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
                "serverInfo": {"name": "petal", "version": version()},
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


def cli(argv):
    """`petal recipe export|import`, `petal suggest`, `petal summary` (bin/petal), in plain words."""
    command = argv[0] if argv else ""
    rest = [a for a in argv[1:] if not a.startswith("--")]
    flags = [a for a in argv[1:] if a.startswith("--")]
    if command == "summary":
        s = t_summary({})
        print("%s to %s" % (s["from"], s["to"]))
        for line in s["lines"]:
            print("  " + line)
    elif command == "suggest":
        found = t_suggestions({})["suggestions"]
        if not found:
            print("No suggestions right now. Petal suggests modes once it has seen a few days of use.")
        for i, g in enumerate(found, 1):
            print("%d. %s" % (i, g["text"]))
        if found:
            print("\nAsk Claude to make one, or say \"petal suggest --dismiss <n>\" to stop suggesting it.")
        for flag in flags:
            if flag.startswith("--dismiss"):
                n = int(rest[0]) if rest and rest[0].isdigit() else 0
                if 1 <= n <= len(found):
                    dismiss_suggestion(found[n - 1]["key"])
                    print("Won't suggest %d again." % n)
    elif command == "get":
        state = t_get_state({})
        if rest:
            print(json.dumps(state["settings"].get(rest[0]), ensure_ascii=False))
        else:
            print(json.dumps(state, indent=2, ensure_ascii=False))
    elif command == "set" and len(rest) >= 2:
        raw = " ".join(argv[2:])
        try:
            value = json.loads(raw)
        except ValueError:
            value = raw   # a bare word: a string setting
        t_set_settings({"settings": {rest[0]: value}})
        print("%s = %s" % (rest[0], json.dumps(value, ensure_ascii=False)))
    elif command == "dismiss" and rest:
        dismiss_suggestion(rest[0])
    elif command == "prune":
        prune_activity()
    elif command == "recipe" and rest[:1] == ["export"]:
        out = t_export_recipe({"path": rest[1] if len(rest) > 1 else ""})
        print("Saved %s (%s)." % (out["path"].replace(HOME, "~"), ", ".join(out["modes"])))
        print("Share the file; someone adds it with: petal recipe import <file>")
    elif command == "recipe" and rest[:1] == ["import"] and len(rest) > 1:
        look = "--look" in flags
        plan = t_import_recipe({"path": rest[1], "look": look, "preview": True})
        print("This adds %d mode%s:" % (len(plan["modes"]), "" if len(plan["modes"]) == 1 else "s"))
        names = app_names()
        for m in plan["modes"]:
            print("  %s: %s" % (m["name"], ", ".join(names.get(a, a) for a in m.get("apps", [])) or "no apps yet"))
        if plan["missing"]:
            print("Not installed here (left out): " + ", ".join(plan["missing"]))
        for k, v in (plan.get("settings") or {}).items():
            print("  %s: %s -> %s" % (k, json.dumps(v["from"]), json.dumps(v["to"])))
        for k, v in (plan.get("dock") or {}).items():
            print("  dock %s -> %s" % (k, v))
        if not look:
            print("(Its look stays out; add --look to use it too.)")
        if "--yes" not in flags:
            if not sys.stdin.isatty():
                print("Run again with --yes to add it.")
                return
            if input("Add it? [y/N] ").strip().lower() not in ("y", "yes"):
                print("Nothing changed.")
                return
        out = t_import_recipe({"path": rest[1], "look": look})
        print("Added %s." % ", ".join(m["name"] for m in out["modes"]))
    else:
        print("usage: petal get [key] | petal set <key> <json value> | petal recipe export [file] | "
              "petal recipe import <file> [--look] [--yes] | petal suggest | petal summary")
        sys.exit(2)


def main():
    # Petal for macOS answers Claude itself (no python3 needed on the Mac); its build takes the tools, settings and
    # mode fields from here, so both platforms describe them the same way.
    # `--tool <name> '<json args>'` runs one tool and prints its JSON (the dock and bin/petal use it, so there's one
    # implementation); `--cli …` is bin/petal's plain-words side of the same.
    if "--tool" in sys.argv[1:2]:
        entry = TOOLS.get(sys.argv[2] if len(sys.argv) > 2 else "")
        try:
            if not entry:
                raise ValueError("Unknown tool")
            json.dump(entry[0](json.loads(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else {}), sys.stdout, ensure_ascii=False)
        except Exception as e:  # one line of JSON either way, for whoever reads it
            json.dump({"error": str(e)}, sys.stdout)
            print()
            sys.exit(1)
        print()
        return
    if "--cli" in sys.argv[1:2]:
        try:
            cli(sys.argv[2:])
        except (ValueError, OSError) as e:
            print(e, file=sys.stderr)
            sys.exit(1)
        return
    if "--describe" in sys.argv:
        json.dump({"tools": tool_list(), "settings": {k: list(v) for k, v in SETTINGS_SCHEMA.items()},
                   "mode_fields": MODE_FIELDS}, sys.stdout, indent=1, ensure_ascii=False)
        return
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
