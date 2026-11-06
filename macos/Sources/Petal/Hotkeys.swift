import AppKit
import Carbon.HIToolbox
import Observation

/// Petal's keyboard shortcuts, global while `shortcuts` is on: Control-Option-1…9 puts the Desktop in front in that
/// mode (in modes.json's order), Control-Option-Space opens the AI panel, Control-Option-= the "+" search. A
/// combination macOS or another app already uses is left alone.
@MainActor @Observable
final class Hotkeys {
    struct Key: Identifiable {
        let id: UInt32
        let code: Int
        let label: String
    }

    /// The combinations Petal wanted but someone else has.
    private(set) var taken: Set<UInt32> = []
    @ObservationIgnored private var refs: [EventHotKeyRef] = []
    @ObservationIgnored private var registered: [UInt32] = []
    @ObservationIgnored private var handler: EventHandlerRef?

    static let modifiers = UInt32(controlKey | optionKey)
    static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    static let ask: UInt32 = 100
    static let search: UInt32 = 101

    var app: PetalApp { PetalApp.shared }

    /// The keys Petal would use now: one per mode (up to 9), the AI panel when there's an AI, and "+".
    var keys: [Key] {
        var keys = app.config.modes.prefix(9).indices.map { Key(id: UInt32($0 + 1), code: Self.digits[$0], label: "⌃⌥\($0 + 1)") }
        if !app.providers.isEmpty { keys.append(Key(id: Self.ask, code: kVK_Space, label: "⌃⌥Space")) }
        keys.append(Key(id: Self.search, code: kVK_ANSI_Equal, label: "⌃⌥="))
        return keys
    }

    /// Registers what the settings ask for, and nothing else. Called when settings or modes change.
    func refresh() {
        let wanted = app.config.bool("shortcuts") && app.docks.shown ? keys : []
        guard wanted.map(\.id) != registered else { return }
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        registered = wanted.map(\.id)
        var taken: Set<UInt32> = []
        guard !wanted.isEmpty else { self.taken = []; return }
        installHandler()
        let system = Self.systemShortcuts()
        for key in wanted {
            if system.contains(Self.combo(key.code, Self.modifiers)) { taken.insert(key.id); continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key.code), Self.modifiers, EventHotKeyID(signature: OSType(0x5045_544C), id: key.id),
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref { refs.append(ref) } else { taken.insert(key.id) }
        }
        if taken != self.taken { self.taken = taken }
    }

    /// A key another part of Petal holds (tiling's, ids from 200 up, which `fire` sends to Tiling). Nil when macOS
    /// or another app already has the combination.
    func register(_ code: Int, modifiers: UInt32, id: UInt32) -> EventHotKeyRef? {
        installHandler()
        if Self.systemShortcuts().contains(Self.combo(code, modifiers)) { return nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), modifiers, EventHotKeyID(signature: OSType(0x5045_544C), id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        return status == noErr ? ref : nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { PetalApp.shared.hotkeys.fire(key) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ key: UInt32) {
        switch key {
        case Self.ask:
            if app.claude.isOpen { app.claude.close() } else { app.claude.open(asking: nil) }
        case Self.search:
            app.search.open(in: nil)
        case 1...9:
            let modes = app.config.modes
            guard Int(key) <= modes.count,
                  let desktop = app.docks.focusedDock?.desktop ?? Spaces.desktop(on: NSScreen.main ?? NSScreen.screens[0]) else { return }
            app.requestMode(modes[Int(key) - 1].id, desktop: desktop)
        case 200...:
            Tiling.hotkey(key)
        default:
            break
        }
    }

    private static func combo(_ code: Int, _ modifiers: UInt32) -> Int { code << 16 | Int(modifiers & 0xFF00) }

    /// macOS's own shortcuts that are switched on (Mission Control, Spotlight, input sources, …).
    private static func systemShortcuts() -> Set<Int> {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let array = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var found = Set<Int>()
        for entry in array where (entry[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false {
            guard let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { continue }
            found.insert(combo(code, modifiers))
        }
        return found
    }
}
