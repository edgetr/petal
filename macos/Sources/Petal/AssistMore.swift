import AppKit
import Security

/// What Petal AI did (shown in Settings › AI, each with its own undo where there is one), the apps it never looks
/// into, and the vault: secrets it can use (typed into the field in front, after asking) but never sees.
extension Assist {
    // MARK: What it did

    enum Undo: Codable, Equatable {
        case putBack([[String]])          // [from, to in the Trash]
        case forget(String)               // a memory's id
        case remember(String, String)     // text, mode
        case open(String, String)         // a page: path, title (not an undo: open it again)
    }

    struct Done: Codable, Identifiable, Equatable {
        var id = UUID()
        let at: Date
        let text: String
        var undo: Undo?
        var undone = false
    }

    static var historyFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Petal/ai-history.json")
    }

    func did(_ text: String, undo: Undo? = nil) {
        var list = history
        list.insert(Done(at: Date(), text: text, undo: undo), at: 0)
        history = Array(list.prefix(200))
        saveHistory()
    }

    func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyFile) else { return }
        history = (try? JSONDecoder().decode([Done].self, from: data)) ?? []
    }

    private func saveHistory() {
        let list = history
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: Self.historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.historyFile, options: .atomic) }
        }
    }

    /// Undoes one thing it did (or opens the page again).
    func undo(_ done: Done) {
        guard let undo = done.undo else { return }
        switch undo {
        case .putBack(let pairs):
            var stuck: [[String]] = []
            for pair in pairs where pair.count == 2 {
                let fm = FileManager.default
                guard fm.fileExists(atPath: pair[1]) else { continue }   // emptied from the Trash: nothing to bring
                if fm.fileExists(atPath: pair[0]) || (try? fm.moveItem(atPath: pair[1], toPath: pair[0])) == nil { stuck.append(pair) }
            }
            if !stuck.isEmpty, let index = history.firstIndex(where: { $0.id == done.id }) {
                // Something is in the way: what couldn't come back stays to try again.
                history[index].undo = .putBack(stuck)
                saveHistory()
                return
            }
        case .forget(let id): forget(id: id, matching: nil)
        case .remember(let text, let mode): remember(text, mode: mode, learned: false)
        case .open(let path, let title):
            Pages.open(URL(fileURLWithPath: path), title: title)
            return
        }
        if let index = history.firstIndex(where: { $0.id == done.id }) { history[index].undone = true; saveHistory() }
    }

    // MARK: Apps it never looks into

    /// Password managers and the like: their names only, never what's in them, nor in a picture of the screen.
    func neverLook(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return config.strings("aiNeverLook").contains(bundleID)
    }

    var privatePIDs: Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.filter { neverLook($0.bundleIdentifier) }.map(\.processIdentifier))
    }

    // MARK: The vault

    private static let vaultService = "tech.edgetr.petal.vault"

    /// The secrets' names (never their values), from the Keychain.
    static func vaultNames() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: vaultService,
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    static func vaultSave(_ name: String, _ secret: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: vaultService,
                                   kSecAttrAccount as String: name]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(item as CFDictionary, nil)
    }

    static func vaultRemove(_ name: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: vaultService,
                       kSecAttrAccount as String: name] as CFDictionary)
    }

    private static func vaultSecret(_ name: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: vaultService,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The vault tool: list the names, use one (typed into the field in front, after asking every time, even with
    /// Full access), or ask the person for one it doesn't have (typed into the card, never shown to the AI).
    func vault(_ args: [String: Any], _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        switch args["action"] as? String ?? "list" {
        case "list":
            send(["secrets": Self.vaultNames()])
        case "use":
            guard Self.vaultNames().contains(name) else { return fail("There's no “\(name)” in the vault. Ask for it with action: request.") }
            guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return fail("Nothing's in front to type into.")
            }
            let place = front.localizedName ?? "the app in front"
            ask("vault:\(name)", "Type your “\(name)” into \(place)", detail: "Petal types it into the field that has the cursor; \(app.chatProvider?.name ?? "the AI") never sees it.",
                always: true) { allowed in
                guard allowed else { return send(["declined": "The person didn't allow it."]) }
                guard let secret = Self.vaultSecret(name) else { return fail("Couldn't read it from the Keychain.") }
                Self.type(secret, into: front.processIdentifier)
                self.did("Typed your “\(name)” into \(place)")
                send(["typed": name, "into": place])
            }
        case "request":
            guard !name.isEmpty else { return fail("Give the secret a name, such as “GitHub password”.") }
            let why = args["why"] as? String ?? ""
            ask("vault-new", "\(app.chatProvider?.name ?? "Petal AI") needs your “\(name)”", detail: why.isEmpty ? "It goes in Petal's vault (your Keychain), and the AI never sees it." : why,
                always: true, secret: true, typed: { secret in Self.vaultSave(name, secret) }) { allowed in
                guard allowed else { return send(["declined": "The person didn't add it."]) }
                self.did("Saved your “\(name)” in the vault")
                send(["saved": name, "note": "It's in the vault; use it with action: use. You can't read it."])
            }
        default:
            fail("action is list, use or request")
        }
    }

    /// Types text into an app as keystrokes, to the field that has the cursor (needs Accessibility).
    private static func type(_ text: String, into pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        var rest = Array(text.utf16)
        while !rest.isEmpty {
            let chunk = Array(rest.prefix(16))
            rest.removeFirst(chunk.count)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                event?.postToPid(pid)
            }
        }
    }
}
