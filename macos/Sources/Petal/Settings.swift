import Foundation

/// One setting in settings.json: its key, its default and what it does.
struct Setting {
    /// The default, which is also the setting's type.
    enum Default {
        case bool(Bool), number(Double), string(String), list([String])

        var value: Any {
            switch self {
            case .bool(let value): return value
            case .number(let value): return value
            case .string(let value): return value
            case .list(let value): return value
            }
        }
    }

    let key: String
    let fallback: Default
    /// What it does, in the words Petal AI is given (`petal_get_state`'s `settings_help`).
    let help: String
    /// Whether Petal AI's tools list it and may change it. Where an AI app is installed is the person's to say.
    let forTools: Bool

    init(_ key: String, _ fallback: Default, _ help: String, forTools: Bool = true) {
        self.key = key
        self.fallback = fallback
        self.help = help
        self.forTools = forTools
    }
}

/// Every setting Petal reads, in one list: `Config` takes its defaults from here, and Petal AI's tools list and
/// change the ones that are `forTools`. A new setting is one line here, and nothing else needs to know it exists.
/// Foundation only: `macos/checks/run.sh` checks the list, and every read of a setting in the sources against it.
enum Settings {
    /// How the dock looks.
    static let looks: [Setting] = [
        Setting("dockColor", .string(""), "Dock tint, #rrggbb. Empty = no tint: macOS's own glass."),
        Setting("dockOpacity", .number(0.45), "Dock background opacity, 0 to 1."),
        Setting("dockRadius", .number(-1), "Dock corner radius in points; -1 = fully rounded ends."),
        Setting("dockMargin", .number(-1), "Gap between the dock and the screen edge in points; -1 = default."),
        Setting("iconSize", .number(36), "App icon size in points."),
        Setting("iconPadding", .number(-1), "Space around each icon in points; -1 = default."),
        Setting("idleOpacity", .number(0.7), "Opacity of pinned apps that aren't running, 0 to 1."),
        Setting("separators", .bool(true), "Thin dividers between the dock's sections."),
        Setting("hoverLift", .bool(true), "Icons lift slightly on hover."),
        Setting("hoverLiftAmount", .number(0.05), "How much an icon grows/rises under the pointer, 0 (off) to 0.3."),
        Setting("appGlow", .bool(true), "Running apps glow in their icon's color; their dot takes that color."),
        Setting("glowStrength", .number(1), "App-colored glow behind running apps, 0 to 1."),
        Setting("accentColor", .string(""), "Accent color for dots, highlights, buttons, #rrggbb. Empty = Petal's pink."),
        Setting("magnification", .bool(false), "Icons grow under the pointer."),
        Setting("magnificationAmount", .number(0.5), "How much icons grow, 0.1 to 1 (1 = twice the size)."),
    ]

    /// What the dock shows and does.
    static let dock: [Setting] = [
        Setting("tooltips", .bool(true), "Show app names on hover."),
        Setting("thisWorkspaceOnly", .bool(true), "Show running apps only from the current Desktop."),
        Setting("previews", .bool(true), "Live window previews when hovering a running app."),
        Setting("minimized", .bool(true), "Minimized windows appear as thumbnails in the dock."),
        Setting("badges", .bool(true), "Unread notification counts on app icons."),
        Setting("bounce", .bool(true), "An icon bounces once when its app wants attention."),
        Setting("progress", .bool(true), "Progress rings around icons (downloads etc.)."),
        Setting("quickActions", .bool(true), "An app's own actions in its right-click menu."),
        Setting("recentFiles", .bool(true), "Recent files in an app's right-click menu."),
        Setting("dropToOpen", .bool(true), "Drop files on an app icon to open them in it."),
        Setting("nowPlaying", .bool(true), "A now-playing tile with album art."),
        Setting("stacks", .bool(true), "Folder stacks in the dock."),
        Setting("stackFolders", .list(["~/Downloads", "~/Pictures/Screenshots"]), "Folders shown as stacks."),
        Setting("trash", .bool(true), "Trash in the dock."),
        Setting("finderInDock", .bool(true), "Finder as its own button next to the AI button (never among the apps, so it never appears at the end and moves the rest)."),
    ]

    /// Tiling.
    static let windows: [Setting] = [
        Setting("tiling", .bool(false), "Petal tiles the windows on each Desktop, like a tiling window manager."),
        Setting("tilingGaps", .number(8), "Space between tiled windows and around them, in points."),
        Setting("tilingFloat", .list([]), "Bundle ids of apps whose windows never tile."),
    ]

    /// The AI: which one, how it runs, and what it may do.
    static let ai: [Setting] = [
        Setting("aiProviders", .list(["claude"]), "The AI apps Petal uses, each the user's own install and account: claude, codex, both, or none ([] = no AI; the dock still works)."),
        Setting("chatProvider", .string("claude"), "Which of aiProviders the chat panel, the usage ring and small jobs use: claude or codex."),
        Setting("claudePath", .string(""), "Where Claude Code is, when Petal can't find it by itself (a path to `claude`). The person's to set, in settings.json.", forTools: false),
        Setting("codexPath", .string(""), "Where Codex is, when Petal can't find it by itself (a path to `codex`). The person's to set, in settings.json.", forTools: false),
        Setting("chatModel", .string("sonnet"), "Claude panel model: haiku, sonnet, opus or fable."),
        Setting("chatEffort", .string("medium"), "Claude panel effort: low, medium, high, xhigh or max."),
        Setting("codexModel", .string(""), "Codex chat model; empty = Codex's own default."),
        Setting("codexEffort", .string("medium"), "Codex chat reasoning effort: low, medium, high or xhigh."),
        Setting("claudeAuth", .string("subscription"), "How Petal's own Claude runs (chat, sorting) pay: subscription (the user's Claude Code sign-in) or api (an Anthropic API key the user pastes in Settings > AI; it stays in the Keychain, and only Petal's runs use it). Never ask for or handle a key yourself."),
        Setting("codexAuth", .string("subscription"), "How Petal's own Codex runs pay: subscription (the user's ChatGPT sign-in) or api (an OpenAI API key the user pastes in Settings > AI; Keychain only, Petal's runs only). Never ask for or handle a key yourself."),
        Setting("claudeAccess", .string("auto"), "Claude panel permissions: auto (safe actions run, risky ones ask) or full."),
        Setting("chatWhileWorking", .string("steer"), "Writing in the AI chat while it works: steer (it stops where it is and carries on from the new message) or queue (sent once it's done)."),
        Setting("ai", .bool(true), "Small jobs for the chat AI's small model (Claude Haiku, Codex's Luna): routines that sort files by what they are, and notes' quick answers."),
        Setting("claudeUsage", .bool(true), "Claude usage ring around the Claude button."),
        Setting("otherAgents", .bool(true), "Let the user's other AI sessions (T3 Code, Claude Code or Codex in a terminal) change Petal: its MCP server, skill and `petal` command are set up for them."),
        Setting("aiMemory", .bool(true), "Petal AI remembers what helps: what the user asks it to, and what it notices (memory.json). petal_remember / petal_forget / petal_memories."),
        Setting("aiAllowed", .list([]), "What Petal AI may do without asking first (the user chose Always on its card): quit, close, trash, tidy, computer:<bundle id> (using that app), browser (a browser of its own, petal_browser)."),
        Setting("aiNeverLook", .list(["com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess"]), "Apps Petal AI never looks into (bundle ids): petal_look gives only their name, window lists leave out their titles, and screenshots leave them out."),
        Setting("selectionAsk", .bool(true), "Selecting text in any app brings up a small \"Ask Petal AI\" button by it (and \"Note\", a new note on that sentence, when notes is on); clicking Ask quotes the text in the chat. (Also in every app's Services menu.) Never in apps kept private or password fields."),
        Setting("computerUse", .bool(true), "Petal AI can use the user's apps for them (petal_ui, petal_act): it presses buttons, types and chooses menu items through Accessibility, with a pink pointer of its own; the user's pointer never moves. A sticky note works in its own window in the background (no pointer, nothing comes forward) and asks the user to bring the window forward for what can't be done there. It asks before it uses each app (once per reply), and Stop or Escape ends it. Never apps in aiNeverLook, never password fields. Off: both tools refuse."),
        Setting("runDisplays", .bool(false), "A hidden display for each Petal AI run, so its work never shows up in front of the user: a helper in a note, or an AI session outside Petal, opens its windows (petal_apps open) on a display of its own that the user doesn't see and their pointer can't reach, works there through Accessibility with nothing brought forward, and the display goes when the run ends (an app the run itself started that the user never used, with nothing unsaved, is quit; an empty window it made is closed; anything else comes back to the user's screen). Two runs take turns on one app (\"Waiting for TextEdit\"). Questions, Buy cards and the vault's card still show over the dock or on the note. The AI button's preview shows each run's display live, with Show me to bring its window to the user's screen. Off by default."),
        Setting("runDisplaysLimit", .number(0), "The most hidden displays at once (runDisplays). 0 = what this Mac's memory allows: one per 8 GB, at least 1, at most 4; a number only lowers that. A run past the limit waits its turn (\"Waiting for a display\")."),
        Setting("runBrowser", .string(""), "Which installed browser a Petal AI run gets as its own (petal_browser, with runDisplays on): a bundle id, one of com.google.Chrome, com.microsoft.edgemac, com.brave.Browser, com.vivaldi.Vivaldi, net.imput.helium. Empty = Petal picks one that's installed, preferring one the user doesn't have open. It starts with a fresh profile (signed in to nothing) on the run's display and goes when the run ends; Petal installs no browser."),
        Setting("pointerColor", .string(""), "Color of Petal AI's own pointer (the arrow that shows what it presses while it uses apps), #rrggbb. Empty = Petal's pink."),
        Setting("routines", .bool(true), "Run the user's routines (routines.json): what Petal does by itself when a file lands in a folder, an app opens or at a time. Made with petal_routine_save."),
    ]

    /// Petal Notes.
    static let notes: [Setting] = [
        Setting("notes", .bool(true), "Petal Notes, the user's own notes on paper stuck to places: a sentence, a browser tab, a window, all of an app, a file in any app, a Desktop, the screen itself (it shows on every Desktop, whatever is in front), a person (beside their conversation in Messages, WhatsApp, Telegram, Slack or Mail). On a window they rest as tabs on its right edge at their line's height; a paper dragged anywhere stays exactly there. The note pad in the dock (notesPad: click it, or drag a paper off it and let go anywhere), ⌃⌥N, \"Note\" by selected text, dragging from the AI button or Stick here on a quick question makes one. Markdown files, one per note, a folder per notebook. The Petal Notes window (the menu bar's mark) shows every note: search, Coming back, Watching, Helpers at work, each notebook as a grid or a canvas (per notebook, on its cover). A notebook can be Private (its notes kept from you and the note tools unless asked from inside it, from previews and other notebooks' memory, and out of Petal's own pictures) or kept in the dock as a stack (stackFolders); dropping a note on an app in the dock uses it there. petal_notes / petal_note_read / petal_note_write / petal_note_move / petal_note_stick. Helpers: @Petal in a note runs only when the person presses Return on that line; its answer is ink on the note, its steps and what was allowed (stamps) on the back; things said in words (bring this back Friday, remember, put this away, check this every morning, recalculate, when @A is done, check this against @Notebook) are done there. Petal's viewer shows a document with its notes in a margin (petal_view, petal_view_versions, petal_view_pick, petal_note_pdf_comments)."),
        Setting("notesPad", .bool(true), "The note pad in the dock, by the AI button (shown while notes is on): a click makes a blank note on what's in front, and a paper dragged off it becomes a note wherever it's let go, on the window under it or that Desktop (holding Option: kept on the screen itself)."),
        Setting("notesLook", .string("paper"), "How notes look: paper (opaque paper tinted with the notebook's color) or glass (macOS's Liquid Glass)."),
        Setting("notesFolder", .string(""), "Where notes are kept (a folder path; empty: iCloud Drive's Petal Notes when iCloud Drive is on, else Petal's own folder in Application Support)."),
        Setting("notesNotebook", .string("Inbox"), "The notebook new notes go to, unless one was last used on that site or app."),
    ]

    /// Petal itself.
    static let app: [Setting] = [
        Setting("autoUpdate", .bool(true), "Install new Petal releases automatically (then offer a restart)."),
        Setting("shortcuts", .bool(true), "Petal's keyboard shortcuts (Control-Option): Space opens the AI panel, = the + search, N a new note. Never takes one already in use."),
        Setting("menuBarIcon", .bool(true), "Petal's mark in the menu bar (Petal Notes, settings, updates)."),
    ]

    static let all: [Setting] = looks + dock + windows + ai + notes + app

    private static let byKey: [String: Setting] = {
        var found: [String: Setting] = [:]
        for setting in all { found[setting.key] = setting }
        return found
    }()

    static func named(_ key: String) -> Setting? { byKey[key] }

    /// Each setting's default, by key.
    static let defaults: [String: Any] = byKey.mapValues { $0.fallback.value }

    /// The settings Petal AI's tools list and change.
    static let forTools: [Setting] = all.filter { $0.forTools }
}
