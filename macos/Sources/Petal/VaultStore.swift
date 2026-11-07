import Foundation
import Observation
import Security

/// The vault's items in the Keychain (service `tech.edgetr.petal.vault`), never in a plain file: one generic password
/// per item, its account `item:<id>`, its data the item as JSON. Read once and kept until it changes. Every read and
/// write waits on the Keychain, so all of it runs on `queue`, never on the main thread.
///
/// Before kinds, the vault kept a secret under a name (account "OpenAI key", data the secret): the first load
/// moves each into an API key (Vault.migrate), deleting the old item only once the new one is saved.
enum VaultStore {
    static let service = "tech.edgetr.petal.vault"
    static let prefix = "item:"
    /// One at a time, in order.
    static let queue = DispatchQueue(label: "petal.vault", qos: .userInitiated)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [VaultItem]?
    /// Set for `Petal --snapshot`: these stand in for the Keychain, which is then never touched.
    nonisolated(unsafe) private static var stand: [VaultItem]?

    static func standIn(_ items: [VaultItem]) {
        lock.lock()
        stand = items
        cache = nil
        lock.unlock()
        VaultIndex.changed()
    }

    // MARK: Reading (off the main thread)

    /// Every item, newest first. Reads the Keychain the first time and after a change.
    static func items() -> [VaultItem] {
        lock.lock()
        if let stand { lock.unlock(); return stand.sorted { $0.updated > $1.updated } }
        if let cache { lock.unlock(); return cache }
        lock.unlock()
        var found: [VaultItem] = []
        for account in accounts() {
            guard let data = read(account) else { continue }
            if account.hasPrefix(prefix) {
                if let item = try? JSONDecoder().decode(VaultItem.self, from: data) { found.append(item) }
            } else if let secret = String(data: data, encoding: .utf8), let item = Vault.migrate([(account, secret)]).first {
                // An older item becomes an API key; the old one goes only once its new one is in.
                if write(item) {
                    delete(account)
                    found.append(item)
                }
            }
        }
        let sorted = found.sorted { $0.updated > $1.updated }
        lock.lock()
        cache = sorted
        lock.unlock()
        return sorted
    }

    static func item(_ id: String) -> VaultItem? { items().first { $0.id == id } }

    /// The items, read on `queue`, handed back on the main thread.
    static func load(_ done: @escaping @MainActor ([VaultItem]) -> Void) {
        queue.async {
            let list = items()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(list) } }
        }
    }

    // MARK: Writing (off the main thread)

    /// Saves (adds, or replaces the item with its id); false when the Keychain refused it.
    @discardableResult
    static func save(_ items: [VaultItem]) -> Bool {
        var ok = true
        lock.lock()
        if stand != nil {
            for item in items {
                if let index = stand!.firstIndex(where: { $0.id == item.id }) { stand![index] = item } else { stand!.append(item) }
            }
            lock.unlock()
        } else {
            lock.unlock()
            for item in items where !write(item) { ok = false }
            lock.lock()
            cache = nil
            lock.unlock()
        }
        VaultIndex.changed()
        return ok
    }

    static func remove(_ id: String) {
        lock.lock()
        if stand != nil {
            stand!.removeAll { $0.id == id }
            lock.unlock()
        } else {
            lock.unlock()
            delete(prefix + id)
            lock.lock()
            cache = nil
            lock.unlock()
        }
        VaultIndex.changed()
    }

    // MARK: The Keychain

    private static func accounts() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let found = result as? [[String: Any]] else { return [] }
        return found.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ item: VaultItem) -> Bool {
        guard let data = try? JSONEncoder().encode(item) else { return false }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: prefix + item.id]
        let label = "Petal vault: \(item.title)"
        let change: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        switch SecItemUpdate(match as CFDictionary, change as CFDictionary) {
        case errSecSuccess: return true
        case errSecItemNotFound:
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        default: return false
        }
    }

    private static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    /// Random bytes from the system's secure source.
    static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // Never a weak password: arc4random is the system's secure source too.
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        }
        return bytes
    }
}

/// The vault for the settings window: its items, kept on the main thread, read and saved through VaultStore's queue.
@MainActor @Observable
final class VaultModel {
    static let shared = VaultModel()
    private(set) var items: [VaultItem] = []
    private(set) var loaded = false
    /// Touch ID or the Mac's password was given this recently: a saved password shows without asking again.
    var unlockedUntil = Date.distantPast

    func load() {
        VaultStore.load { list in
            self.items = list
            self.loaded = true
        }
    }

    func save(_ item: VaultItem, done: ((Bool) -> Void)? = nil) {
        var item = item
        item.updated = Date()
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.insert(item, at: 0) }
        VaultStore.queue.async {
            let ok = VaultStore.save([item])
            DispatchQueue.main.async { MainActor.assumeIsolated { done?(ok); self.load() } }
        }
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        VaultStore.queue.async {
            VaultStore.remove(id)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.load() } }
        }
    }

    /// Items to show without the Keychain, for `Petal --snapshot`.
    func preview(_ list: [VaultItem]) {
        items = list
        loaded = true
    }

    /// Changes made elsewhere (Petal AI saved a login): read again if the window has it.
    func changed() { if loaded { load() } }

    struct Imported: Equatable {
        var added = 0
        var same = 0
        var updated: [String] = []
        var skipped = 0
        var file: URL
        var failed: String?
        var trashed = false
    }

    /// An export (Apple Passwords, Chrome or Proton Pass as CSV; Proton Pass's unencrypted JSON or zip; Petal's own
    /// file), read and merged off the main thread.
    func importFile(_ url: URL, done: @escaping (Imported) -> Void) {
        VaultStore.queue.async {
            var result = Imported(file: url)
            let data = url.pathExtension.lowercased() == "zip" ? Self.unzipJSON(url) : try? Data(contentsOf: url)
            if let data, let parsed = Vault.importData(data) {
                let merge = Vault.merge(existing: VaultStore.items(), incoming: parsed.items)
                if VaultStore.save(merge.save) {
                    result.added = merge.added
                    result.same = merge.same
                    result.updated = merge.updated
                    result.skipped = parsed.skipped
                } else {
                    result.failed = "The Keychain didn't take them. Nothing was added."
                }
            } else {
                result.failed = data == nil ? "Petal couldn't read that file." : "That isn't an export Petal knows (Apple Passwords, Chrome, Proton Pass or Petal)."
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.load(); done(result) } }
        }
    }

    /// The JSON inside a Proton Pass zip, with macOS's own unzip (in memory: nothing is written out).
    nonisolated private static func unzipJSON(_ url: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "*.json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    enum ExportFormat { case petal, csv }

    /// Writes the vault to `url` (Petal's file with every kind, or logins as a CSV), off the main thread. The file
    /// holds the secrets as plain text: only after Touch ID or the Mac's password (the settings window asks).
    func export(_ format: ExportFormat, to url: URL, done: @escaping (Bool) -> Void) {
        VaultStore.queue.async {
            let items = VaultStore.items()
            let data = format == .petal ? Vault.exportJSON(items) : Data(Vault.exportCSV(items).utf8)
            let ok = (try? data.write(to: url, options: [.atomic])) != nil
            if ok { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// The export holds every password in plain text: to the Trash (never deleted), off the main thread.
    func trash(_ url: URL, done: @escaping (Bool) -> Void) {
        VaultStore.queue.async {
            let ok = (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
            DispatchQueue.main.async { done(ok) }
        }
    }
}
