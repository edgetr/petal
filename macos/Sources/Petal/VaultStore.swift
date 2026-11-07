import Foundation
import Observation
import Security

/// The vault's items in the Keychain (service `tech.edgetr.petal.vault`), never in a plain file: one generic password
/// per item, its account `item:<id>`, its data the item as JSON, marked as Petal's format (kSecAttrGeneric,
/// Vault.format). Read once and kept until it changes. Every read and write of the Keychain runs on `queue`, one at a
/// time and in order, never on the main thread; a read that a save overtook is never kept (`generation`).
///
/// Before kinds, the vault kept a secret under a name (account "OpenAI key", data the secret): the first load
/// moves each into an API key (Vault.migrate), deleting the old item only once the new one is saved. A record that
/// doesn't read as an item (an old name that happens to start with "item:") is such a secret, never dropped.
enum VaultStore {
    static let service = "tech.edgetr.petal.vault"
    static let prefix = "item:"
    private static let onQueue = DispatchSpecificKey<Bool>()
    /// One at a time, in order.
    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "petal.vault", qos: .userInitiated)
        queue.setSpecific(key: onQueue, value: true)
        return queue
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [VaultItem]?
    /// Goes up with every save and removal: a read that started before one is stale.
    nonisolated(unsafe) private static var generation = 0
    /// Set for `Petal --snapshot`: these stand in for the Keychain, which is then never touched.
    nonisolated(unsafe) private static var stand: [VaultItem]?

    /// Runs `work` on `queue` (at once when already on it), waiting for it.
    private static func serially<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: onQueue) == true ? work() : queue.sync(execute: work)
    }

    static func standIn(_ items: [VaultItem]) {
        lock.lock()
        stand = items
        cache = nil
        generation += 1
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
        return serially {
            lock.lock()
            if let cache { lock.unlock(); return cache }
            let started = generation
            lock.unlock()
            let sorted = readAll().sorted { $0.updated > $1.updated }
            lock.lock()
            if generation == started { cache = sorted }   // a save meanwhile: read again next time
            lock.unlock()
            return sorted
        }
    }

    /// Reads every record (on `queue`). An old secret becomes an API key, the old record deleted only once the
    /// new one is in; if the Keychain refuses the new one, the old stays and the secret is still listed (and hidden
    /// from the AI) under the new item for now.
    private static func readAll() -> [VaultItem] {
        var found: [VaultItem] = []
        var unreadable = 0
        for (account, marked) in accounts() {
            guard let data = read(account) else { continue }
            switch Vault.stored(account: account, data: data, marked: marked) {
            case .item(let item):
                found.append(item)
            case .legacy(let name, let secret):
                guard let item = Vault.migrate([(name, secret)]).first else { continue }
                if write(item) { delete(account) }
                found.append(item)
            case .unreadable:
                unreadable += 1
            }
        }
        if unreadable > 0 { NSLog("Petal vault: \(unreadable) Keychain item(s) aren't text or an item; left as they are.") }
        return found
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
        let ok: Bool = serially {
            lock.lock()
            if stand != nil {
                for item in items {
                    if let index = stand!.firstIndex(where: { $0.id == item.id }) { stand![index] = item } else { stand!.append(item) }
                }
                generation += 1
                lock.unlock()
                return true
            }
            lock.unlock()
            var ok = true
            for item in items where !write(item) { ok = false }
            lock.lock()
            generation += 1
            cache = nil
            lock.unlock()
            return ok
        }
        VaultIndex.changed()
        return ok
    }

    static func remove(_ id: String) {
        serially {
            lock.lock()
            if stand != nil {
                stand!.removeAll { $0.id == id }
                generation += 1
                lock.unlock()
                return
            }
            lock.unlock()
            delete(prefix + id)
            lock.lock()
            generation += 1
            cache = nil
            lock.unlock()
        }
        VaultIndex.changed()
    }

    // MARK: The Keychain

    /// Every record's account, and whether it's marked as Petal's item format.
    private static func accounts() -> [(account: String, marked: Bool)] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let found = result as? [[String: Any]] else { return [] }
        return found.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            let generic = (attributes[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) }
            return (account, generic == Vault.format)
        }
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
        let marker = Data(Vault.format.utf8)
        let change: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label, kSecAttrGeneric as String: marker]
        switch SecItemUpdate(match as CFDictionary, change as CFDictionary) {
        case errSecSuccess: return true
        case errSecItemNotFound:
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            add[kSecAttrGeneric as String] = marker
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
