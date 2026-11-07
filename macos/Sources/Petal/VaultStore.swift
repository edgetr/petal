import Foundation
import Observation
import Security

/// The vault's items in the Keychain (service `tech.edgetr.petal.vault`), never in a plain file: one generic password
/// per item, its account `item:<id>`, its data the item as JSON, marked as Petal's format (kSecAttrGeneric,
/// Vault.format). Read once and kept until it changes. Every read and write of the Keychain runs on `queue`, one at a
/// time and in order, never on the main thread; a read that a save overtook is never kept (`generation`). A read the
/// Keychain refused, whole or in part (locked, busy, access denied), is an error, never a shorter vault: it isn't
/// kept, the next ask reads again, and nothing that needs every item (an export, an import, the AI's redaction) goes
/// ahead on it.
///
/// Before kinds, the vault kept a secret under a name (account "OpenAI key", data the secret): the first load
/// moves each into an unsorted item (Vault.migrate: asked about wherever it fills until the person sorts it),
/// deleting the old item only once the new one is saved. A record that
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
    private static func serially<T>(_ work: () throws -> T) rethrows -> T {
        DispatchQueue.getSpecific(key: onQueue) == true ? try work() : try queue.sync(execute: work)
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

    /// The Keychain didn't give the whole vault (`status`: its error).
    struct Unreadable: Error, Equatable {
        var status: OSStatus
    }

    static let unreadableText = "Your vault can't be read right now (the Keychain didn't answer, or the Mac is locked)."

    /// Every item, newest first. Reads the Keychain the first time and after a change; throws Unreadable when it
    /// couldn't read all of it (nothing kept: the next ask reads again).
    static func items() throws -> [VaultItem] {
        lock.lock()
        if let stand { lock.unlock(); return stand.sorted { $0.updated > $1.updated } }
        if let cache { lock.unlock(); return cache }
        lock.unlock()
        return try serially {
            lock.lock()
            if let cache { lock.unlock(); return cache }
            let started = generation
            lock.unlock()
            let sorted = try readAll().sorted { $0.updated > $1.updated }
            lock.lock()
            if generation == started { cache = sorted }   // a save meanwhile: read again next time
            lock.unlock()
            return sorted
        }
    }

    /// Reads every record (on `queue`). An old secret becomes an unsorted item, the old record deleted only once the
    /// new one is in; if the Keychain refuses the new one, the old stays and the secret is still listed (and hidden
    /// from the AI) under the new item for now. A record the Keychain won't give is an error for the whole read.
    private static func readAll() throws -> [VaultItem] {
        var found: [VaultItem] = []
        var unreadable = 0
        for (account, marked) in try accounts() {
            guard let data = try read(account) else { continue }   // deleted since it was listed
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

    static func item(_ id: String) throws -> VaultItem? { try items().first { $0.id == id } }

    /// What became of an editor's save.
    enum SaveOutcome {
        case saved
        /// The Keychain refused it, or couldn't be read to check it.
        case failed
        /// The item changed since the editor opened (`Vault.editConflict`): nothing was saved; the item as it is now
        /// (nil: deleted).
        case changed(VaultItem?)
    }

    /// Saves `item` only while the vault still has the version its editor opened on (`revision`, from
    /// `Vault.openedRevision`; nil for a new item), checked and saved in one go on `queue`, so nothing saved in between
    /// (an import) is written over with the editor's older copy.
    static func save(_ item: VaultItem, ifStill revision: Int?) -> SaveOutcome {
        serially {
            if revision != nil {
                let stored: VaultItem?
                do { stored = try self.item(item.id) } catch { return .failed }
                if Vault.editConflict(opened: revision, stored: stored) { return .changed(stored) }
            }
            return save([item]) ? .saved : .failed
        }
    }

    /// The items (or why they couldn't be read), read on `queue`, handed back on the main thread.
    static func load(_ done: @escaping @MainActor (Result<[VaultItem], Unreadable>) -> Void) {
        queue.async {
            let list: Result<[VaultItem], Unreadable>
            do { list = .success(try items()) } catch { list = .failure(error as? Unreadable ?? Unreadable(status: errSecInternalError)) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(list) } }
        }
    }

    // MARK: Writing (off the main thread)

    /// Saves (adds, or replaces the item with its id); false when the Keychain refused it.
    @discardableResult
    static func save(_ items: [VaultItem]) -> Bool {
        let items = items.map(Vault.normalized)
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

    /// Every record's account, and whether it's marked as Petal's item format. None saved is an empty list; any
    /// other refusal throws.
    private static func accounts() throws -> [(account: String, marked: Bool)] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Unreadable(status: status) }
        guard let found = result as? [[String: Any]] else { throw Unreadable(status: errSecDecode) }
        return found.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            let generic = (attributes[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) }
            return (account, generic == Vault.format)
        }
    }

    /// One record's data; nil when it was deleted since it was listed; throws when the Keychain won't give it.
    private static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Unreadable(status: status == errSecSuccess ? errSecDecode : status) }
        return data
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
    /// The last read of the Keychain didn't give the whole vault: Settings says so instead of showing fewer items.
    private(set) var unreadable = false
    /// Touch ID or the Mac's password was given this recently: a saved password shows without asking again.
    var unlockedUntil = Date.distantPast

    func load() {
        VaultStore.load { read in
            switch read {
            case .success(let list):
                self.items = list
                self.unreadable = false
            case .failure:
                self.unreadable = true
            }
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

    /// The editor's save: only over the version it opened on (`revision`), else `.changed` and nothing saved.
    func save(_ item: VaultItem, ifStill revision: Int?, done: @escaping (VaultStore.SaveOutcome) -> Void) {
        var item = item
        item.updated = Date()
        VaultStore.queue.async {
            let outcome = VaultStore.save(item, ifStill: revision)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .saved = outcome {
                        if let index = self.items.firstIndex(where: { $0.id == item.id }) { self.items[index] = item } else { self.items.insert(item, at: 0) }
                    }
                    done(outcome)
                    self.load()
                }
            }
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
        /// Saved items the file would give another password, code or key, kept as they are (Vault.Merge), as the
        /// file has them: saved instead only if the person says so.
        var conflicts: [VaultItem] = []
        /// Each conflict's saved item as the import compared it (`Vault.openedRevision`, by id): one changed or
        /// deleted since isn't written over when the person says to use the imported ones.
        var compared: [String: Int] = [:]
        var usedImported = false
        /// Conflicts left as they are when the imported ones were used: changed or deleted since the import.
        var usedSkipped = 0
        var older = 0
        var widened = 0
        var skipped = 0
        /// Rows Petal couldn't read, each with why.
        var unreadable: [String] = []
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
                // Merged against the whole vault only: against part of it, what's saved would be added again.
                if let existing = try? VaultStore.items() {
                    let merge = Vault.merge(existing: existing, incoming: parsed.items, petal: parsed.petal)
                    if VaultStore.save(merge.save) {
                    result.added = merge.added
                    result.same = merge.same
                    result.updated = merge.updated
                    result.conflicts = merge.conflicts
                    // The saved items as they are now, after the import's own save, on this same queue.
                    let now = (try? VaultStore.items()) ?? []
                    for conflict in merge.conflicts {
                        if let stored = now.first(where: { $0.id == conflict.id }), let revision = Vault.openedRevision(stored) {
                            result.compared[conflict.id] = revision
                        }
                    }
                    result.older = merge.older
                    result.widened = merge.widened
                    result.skipped = parsed.skipped
                    result.unreadable = parsed.unreadable
                    } else {
                        result.failed = "The Keychain didn't take them. Nothing was added."
                    }
                } else {
                    result.failed = VaultStore.unreadableText + " Nothing was imported."
                }
            } else {
                result.failed = data == nil ? "Petal couldn't read that file." : "That isn't an export Petal knows (Apple Passwords, Chrome, Proton Pass or Petal)."
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.load(); done(result) } }
        }
    }

    /// The person chose the import's passwords, codes and keys over the ones saved (Vault.Merge's conflicts). Each
    /// only while its saved item is still the version the import compared it with (`compared`), checked and saved in
    /// one go on the vault's queue: one edited or deleted since stays as it is now. `done`: saved, and how many were
    /// skipped so.
    func useImported(_ items: [VaultItem], compared: [String: Int], done: @escaping (_ ok: Bool, _ skipped: Int) -> Void) {
        VaultStore.queue.async {
            let ok: Bool, skipped: Int
            if let stored = try? VaultStore.items() {
                let still = Vault.stillConflicting(items, compared: compared, stored: stored)
                let stamped = still.use.map { item -> VaultItem in var item = item; item.updated = Date(); return item }
                ok = stamped.isEmpty || VaultStore.save(stamped)
                skipped = still.skipped
            } else {
                (ok, skipped) = (false, 0)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.load(); done(ok, skipped) } }
        }
    }

    /// The vault's JSON inside a Proton Pass zip (Vault.protonZipMember: its data.json, never an attachment), with
    /// macOS's own unzip (in memory: nothing is written out).
    nonisolated private static func unzipJSON(_ url: URL) -> Data? {
        guard let listing = unzip(["-Z1", url.path]), let names = String(data: listing, encoding: .utf8),
              let member = Vault.protonZipMember(names.split(whereSeparator: \.isNewline).map(String.init)) else { return nil }
        return unzip(["-p", url.path, member])
    }

    /// What /usr/bin/unzip with `arguments` printed, or nil when it failed or printed nothing.
    nonisolated private static func unzip(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
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
    /// holds the secrets as plain text: only after Touch ID or the Mac's password (the settings window asks). Never
    /// part of the vault: when the Keychain doesn't give all of it, nothing is written. `done`: why it failed, or nil.
    func export(_ format: ExportFormat, to url: URL, done: @escaping (String?) -> Void) {
        VaultStore.queue.async {
            guard let items = try? VaultStore.items() else {
                return DispatchQueue.main.async { done(VaultStore.unreadableText + " Nothing was exported.") }
            }
            let data = format == .petal ? Vault.exportJSON(items) : Data(Vault.exportCSV(items).utf8)
            let ok = (try? data.write(to: url, options: [.atomic])) != nil
            if ok { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            DispatchQueue.main.async { done(ok ? nil : "Petal couldn't write that file.") }
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
