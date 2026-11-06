import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Tiling (`tiling`, off by default): a tiling window manager inside Petal. The ordinary, resizable windows of the
/// mode in front on each Desktop showing fill its screen, dwindle-style as Hyprland lays them out (WindowLayout.swift
/// holds the maths), inside the visible frame less Petal's dock strip, with `tilingGaps` around and between them.
/// Dialogs, sheets, windows that can't be resized, minimized and full-screen windows, apps in `tilingFloat`, and
/// Petal's own panels float. With per-mode windows on, each mode has its own layout and parked windows are left out.
/// Turning it off leaves every window where it is.
@MainActor
enum Tiling {
    struct Key: Identifiable {
        let id: UInt32
        let code: Int
        let shift: Bool
    }

    /// Control-Option-arrows focus a neighbour, with Shift they swap with it; T floats or tiles, R rebalances.
    static let keys: [Key] = [
        Key(id: 200, code: kVK_LeftArrow, shift: false), Key(id: 201, code: kVK_RightArrow, shift: false),
        Key(id: 202, code: kVK_UpArrow, shift: false), Key(id: 203, code: kVK_DownArrow, shift: false),
        Key(id: 210, code: kVK_LeftArrow, shift: true), Key(id: 211, code: kVK_RightArrow, shift: true),
        Key(id: 212, code: kVK_UpArrow, shift: true), Key(id: 213, code: kVK_DownArrow, shift: true),
        Key(id: 220, code: kVK_ANSI_T, shift: false), Key(id: 221, code: kVK_ANSI_R, shift: false),
    ]

    /// The legend in the settings window: which keys, what they do, and the ids they need.
    static let legend: [(keys: String, what: String, ids: [UInt32])] = [
        ("⌃⌥ ← → ↑ ↓", "Go to the window next to this one", [200, 201, 202, 203]),
        ("⌃⌥⇧ ← → ↑ ↓", "Swap places with it", [210, 211, 212, 213]),
        ("⌃⌥T", "Float or tile the window in front", [220]),
        ("⌃⌥R", "Even out the layout", [221]),
    ]

    /// The keys someone else already has.
    private(set) static var taken: Set<UInt32> = []

    private static var trees: [String: TileTree] = [:]
    private static var layouts: [String: [CGWindowID: CGRect]] = [:]
    private static var floated: Set<CGWindowID> = []
    /// What each window was asked for, and what it took: an app that refuses a frame (its minimum size) isn't asked again.
    private static var applied: [CGWindowID: (target: CGRect, actual: CGRect)] = [:]
    private static var tileable: [CGWindowID: Bool] = [:]
    private static var history: [CGWindowID] = []   // focus, newest first
    private static var active = false
    private static var started = false
    private static var timer: Timer?
    private static var work: DispatchWorkItem?
    private static var settling: DispatchWorkItem?
    private static var refs: [EventHotKeyRef] = []

    private static var config: Config { PetalApp.shared.config }

    // MARK: Starting and stopping

    static func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        tick()
    }

    static func stop() {
        timer?.invalidate()
        if active { disable() }
    }

    private static var wanted: Bool {
        config.bool("tiling") && PetalApp.shared.docks.shown && Windows.trusted && Windows.canManage
    }

    private static func tick() {
        if wanted != active { wanted ? enable() : disable() }
        if active { retile() }
    }

    private static func enable() {
        active = true
        WindowEvents.shared.listen("tiling") { event in handle(event) }
        registerKeys()
        retile()
    }

    /// Off: the keys go, and every window stays where it is.
    private static func disable() {
        active = false
        WindowEvents.shared.stopListening("tiling")
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        taken = []
        trees = [:]
        layouts = [:]
        applied = [:]
        floated = []
        work?.cancel()
        settling?.cancel()
    }

    /// The mode of `desktop` changed (App.swift's apply, after Parking has swapped the windows).
    static func modeChanged(desktop: Int) {
        if active { retile() }
    }

    // MARK: Laying out

    private static func scheduleRetile(after delay: Double = 0.12) {
        work?.cancel()
        let item = DispatchWorkItem { retile() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private static func treeKey(desktop: Int) -> String {
        guard Parking.active else { return "\(desktop)" }
        return "\(desktop)|\(config.mode(forDesktop: desktop)?.id ?? "")"
    }

    /// Lays out every Desktop showing. Windows already where they belong aren't touched, so this is cheap when
    /// nothing changed, and the timer can run it every second to catch what no notification told.
    static func retile() {
        // Never while the mouse is down: a window being dragged or resized isn't pulled back under the pointer.
        guard active, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let screens = Windows.screens()
        let list = Windows.onScreen()
        let gaps = CGFloat(max(0, config.number("tilingGaps")))
        let floatApps = Set(config.strings("tilingFloat"))
        let perMode = Parking.active
        for screen in screens {
            guard let desktop = screen.desktop else { continue }   // a full-screen app's Space
            let key = treeKey(desktop: desktop)
            let mode = config.mode(forDesktop: desktop)?.id ?? ""
            let here = list.filter { window in
                let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                guard screen.frame.contains(center), !floated.contains(window.id), !floatApps.contains(window.bundleID),
                      Parking.parked[window.id] == nil else { return false }
                if perMode && Parking.owners[window.id]?.mode != mode { return false }
                return canTile(window)
            }
            var tree = trees[key] ?? TileTree()
            // Back to front, so on a first layout the window in front is the newest, at the end of the spiral.
            tree.sync(here.reversed().map(\.id), focus: history.first { tree.contains($0) })
            trees[key] = tree
            let area = Windows.usableArea(frame: screen.frame, visible: screen.visible, respectClear: false)
            let frames = TileLayout.frames(tree, in: area, gaps: gaps)
            layouts[key] = frames
            for window in here {
                guard let target = frames[window.id] else { continue }
                if let done = applied[window.id], done.target == target, window.frame.equalTo(done.actual, within: 2) { continue }
                if window.frame.equalTo(target, within: 1) { applied[window.id] = (target, window.frame); continue }
                guard let element = Windows.element(window.id, pid: window.pid) else { continue }
                let actual = Windows.place(element, pid: window.pid, target) ?? target
                applied[window.id] = (target, actual)
            }
        }
    }

    private static func canTile(_ window: ScreenWindow) -> Bool {
        if let known = tileable[window.id] { return known }
        guard let element = Windows.element(window.id, pid: window.pid) else { return false }
        let answer = Windows.isStandard(element) && Windows.isResizable(element) && !Windows.isFullScreen(element) && !Windows.isMinimized(element)
        tileable[window.id] = answer
        return answer
    }

    /// The layout a window is in, among the Desktops showing.
    private static func layout(of id: CGWindowID) -> String? {
        let showing = Set(Windows.screens().compactMap(\.desktop).map(treeKey(desktop:)))
        return layouts.first { showing.contains($0.key) && $0.value[id] != nil }?.key
    }

    // MARK: Events

    private static func handle(_ event: WindowEvents.Event) {
        switch event.kind {
        case .closed:
            if let id = event.window { forget(id) }
            scheduleRetile()
        case .created, .minimized, .unminimized, .space, .screens, .shown, .hidden, .quit, .launched:
            if event.kind == .minimized || event.kind == .unminimized, let id = event.window { tileable[id] = nil }
            scheduleRetile()
        case .focused, .activated:
            if let focused = Windows.focused() {
                history.removeAll { $0 == focused.id }
                history.insert(focused.id, at: 0)
                if history.count > 64 { history.removeLast() }
            }
        case .moved, .resized:
            guard let id = event.window, let element = event.element, Parking.parked[id] == nil, let done = applied[id],
                  let now = Windows.frame(of: element), !now.equalTo(done.actual, within: 2), layout(of: id) != nil else { return }
            // Someone is dragging or resizing a tiled window: wait for the mouse to let go.
            settle(id, attempts: 0)
        case .missionControl, .missionControlEnded:
            break
        }
    }

    private static func forget(_ id: CGWindowID) {
        applied[id] = nil
        tileable[id] = nil
        floated.remove(id)
        history.removeAll { $0 == id }
    }

    /// When the drag ends: dropped on another tiled window, the two swap; on another screen's layout, it joins it
    /// there; anywhere else, it goes back to its place. Resizing goes back too. Petal never moves the pointer: it
    /// only reads where it is.
    private static func settle(_ id: CGWindowID, attempts: Int) {
        settling?.cancel()
        let item = DispatchWorkItem {
            if NSEvent.pressedMouseButtons & 1 != 0 && attempts < 300 { settle(id, attempts: attempts + 1); return }
            guard active, let from = layout(of: id) else { return }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let mouse = NSEvent.mouseLocation
            let pointer = CGPoint(x: mouse.x, y: top - mouse.y)
            let screens = Windows.screens()
            if let screen = screens.first(where: { $0.frame.contains(pointer) }), let desktop = screen.desktop {
                let to = treeKey(desktop: desktop)
                let other = layouts[to].flatMap { TileLayout.window(at: pointer, in: $0, except: id) }
                if to == from, let other {
                    trees[from]?.swap(id, other)
                } else if to != from {
                    trees[from]?.remove(id)
                    trees[to, default: TileTree()].insert(id, splitting: other)
                }
            }
            applied[id] = nil
            retile()
        }
        settling = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempts == 0 ? 0.3 : 0.1), execute: item)
    }

    // MARK: Keys

    private static func registerKeys() {
        let hotkeys = PetalApp.shared.hotkeys
        var taken: Set<UInt32> = []
        for key in keys {
            let modifiers = Hotkeys.modifiers | (key.shift ? UInt32(shiftKey) : 0)
            if let ref = hotkeys.register(key.code, modifiers: modifiers, id: key.id) { refs.append(ref) } else { taken.insert(key.id) }
        }
        self.taken = taken
    }

    /// One of tiling's keys was pressed (Hotkeys.fire sends ids from 200 up here).
    static func hotkey(_ id: UInt32) {
        guard active, let focused = Windows.focused() else { return }
        let directions: [TileLayout.Direction] = [.left, .right, .up, .down]
        switch id {
        case 200...203, 210...213:
            guard let key = layout(of: focused.id), let frames = layouts[key],
                  let other = TileLayout.neighbor(of: focused.id, directions[Int(id % 10)], in: frames) else { return }
            if id < 210 {
                guard let element = Windows.element(other, pid: pidOf(other)) else { return }
                Windows.raise(element, pid: pidOf(other))
            } else {
                trees[key]?.swap(focused.id, other)
                retile()
            }
        case 220:
            if floated.remove(focused.id) == nil {
                guard let key = layout(of: focused.id) else { return }
                floated.insert(focused.id)
                trees[key]?.remove(focused.id)
            }
            retile()
        case 221:
            let showing = Set(Windows.screens().compactMap(\.desktop).map(treeKey(desktop:)))
            for key in layout(of: focused.id).map({ [$0] }) ?? Array(showing) { trees[key]?.rebalance() }
            retile()
        default:
            break
        }
    }

    private static func pidOf(_ id: CGWindowID) -> pid_t {
        Windows.onScreen().first { $0.id == id }?.pid ?? 0
    }
}

// MARK: - Settings

/// The settings rows for per-mode windows and tiling.
struct WindowsCard: View {
    @Environment(PetalApp.self) private var app
    /// Shows tiling's rows whatever the setting (for `--snapshot`).
    var showTiling = false

    var body: some View {
        Card(title: "Windows", footer: "Quitting Petal, or turning these off, leaves every window where you can see it.") {
            SettingToggle(key: "modeWindows", title: "Each mode keeps its own windows",
                          detail: "Switching mode puts the other modes' windows and tabs away, and brings this one's back.")
            SettingToggle(key: "tiling", title: "Tile windows", detail: "Windows sit side by side and fill the screen, with no overlap.")
            if showTiling || app.config.bool("tiling") {
                SettingSlider(key: "tilingGaps", title: "Gaps", range: 0...32)
                ForEach(Tiling.legend, id: \.keys) { row in
                    HStack(spacing: 10) {
                        KeyCaps(text: row.keys).frame(width: 104, alignment: .leading)
                        Text(row.what).font(.system(size: 12))
                        Spacer()
                        if row.ids.allSatisfy(Tiling.taken.contains) && !row.ids.isEmpty {
                            Text("In use elsewhere").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Drag a window onto another to swap them.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
