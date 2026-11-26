import Foundation
import Security

/// What only the person decides, kept in the Keychain beside the vault (service `tech.edgetr.petal.own`), never in a
/// plain file any program could write: agents' grants (`grants`) and what Petal last went by for the settings that
/// say how far Petal AI may go (`settings`, `ConfigRules.personsOwn`). One generic password each, its data JSON.
/// Callers run these off the main thread, on a queue of their own (one Keychain call each, in order).
enum OwnRecords {
    static let service = "tech.edgetr.petal.own"
    static let grants = "agent-grants"
    static let settings = "settings"

    enum Read: Equatable {
        case found(Data)
        /// Never kept.
        case none
        /// The Keychain wouldn't give it (locked, busy, access denied): never taken for none.
        case unreadable(OSStatus)
    }

    static func read(_ account: String) -> Read {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .none }
        guard status == errSecSuccess, let data = result as? Data else { return .unreadable(status == errSecSuccess ? errSecDecode : status) }
        return .found(data)
    }

    @discardableResult
    static func write(_ account: String, _ data: Data) -> Bool {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        switch SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary) {
        case errSecSuccess: return true
        case errSecItemNotFound:
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Petal (\(account))"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        default: return false
        }
    }
}
