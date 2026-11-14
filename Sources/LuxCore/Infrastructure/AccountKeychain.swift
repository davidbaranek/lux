import Foundation
import Security

/// What the Keychain keeps of the signed-in account: its session, and the name of its store
/// folder (a session without its store has lost its encryption keys).
struct KeptAccount: Codable, Equatable, Sendable {
    /// The account's session, as the core keeps it (`CoreKeptSession`).
    struct Session: Codable, Equatable, Sendable {
        var userId: String
        var deviceId: String
        var homeserverUrl: String
        var accessToken: String
        var refreshToken: String?
        /// The app's registration with the server's account service; nil for a password sign-in.
        var oauthClientId: String?
        var nativeSlidingSync: Bool
    }

    var session: Session
    var store: String
}

/// Keeps the account's item in the Keychain, on this device only and readable after the first
/// unlock (a notification extension may read it while the phone is locked). Beside it, in the
/// same service and access group, the key of the account's stores: whoever reads the session can
/// open the stores.
struct AccountKeychain: Sendable {
    let service: String
    /// The item's account attribute.
    private let slot = "session"
    /// The store key's account attribute.
    private let storeKeySlot = "store-key"

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }

    private var item: [String: Any] { item(slot) }

    private func item(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() throws -> KeptAccount? {
        guard let data = try data(slot) else { return nil }
        return try JSONDecoder().decode(KeptAccount.self, from: data)
    }

    /// Writes the account in place: a failed write leaves the old session where it was.
    func write(_ account: KeptAccount) throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(account),
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(item as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }
        let status = SecItemAdd(item.merging(values) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    /// The key of the account's stores (32 bytes), or nil when none is kept.
    func storeKey() throws -> Data? {
        try data(storeKeySlot)
    }

    /// Keeps `key` as the key of the account's stores, in place of any other.
    func writeStoreKey(_ key: Data) throws {
        let values: [String: Any] = [kSecValueData as String: key,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(item(storeKeySlot) as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }
        let status = SecItemAdd(item(storeKeySlot).merging(values) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    /// Deletes the session and the store key: the account's folder goes with them.
    func delete() throws {
        for account in [slot, storeKeySlot] {
            let status = SecItemDelete(item(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
        }
    }

    private func data(_ account: String) throws -> Data? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data else { throw Failure(status: status) }
        return data
    }
}
