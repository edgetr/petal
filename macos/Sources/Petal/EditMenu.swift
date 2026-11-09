import AppKit

/// Petal's main menu, never shown: Petal is an accessory app, so it has no menu bar. It's there only so the standard
/// editing keys (⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌥⇧⌘V, ⌘A, ⌘F) reach every text view the standard way: notes, the chat,
/// Settings fields and vault cards alike. The app menu is empty on purpose: no Quit, Hide or Settings key that could
/// act unexpectedly.
enum EditMenu {
    @MainActor static func make() -> NSMenu {
        let main = NSMenu(title: "Main")
        let app = NSMenuItem(title: "Petal", action: nil, keyEquivalent: "")
        app.submenu = NSMenu(title: "Petal")
        main.addItem(app)

        let edit = NSMenu(title: "Edit")
        func add(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            edit.addItem(item)
        }
        add("Undo", Selector(("undo:")), "z")
        add("Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x")
        add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(NSText.paste(_:)), "v")
        add("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add("Delete", #selector(NSText.delete(_:)), "")
        add("Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    /// For Petal's panels that take typing without making Petal the active app (notes, the chat): the window's own
    /// key handling first, then the Edit menu's keys, so they work there too whether or not macOS hands an
    /// inactive app's menu its key equivalents. Each key is handled once.
    @MainActor static func keyEquivalent(_ event: NSEvent, window: NSWindow, viewsHandled: Bool) -> Bool {
        if viewsHandled { return true }
        guard window.isKeyWindow, event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}
