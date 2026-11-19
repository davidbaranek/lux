import Foundation
import Security

/// The search index's key: 32 random bytes in the Keychain, for this device only (never synced or
/// backed up; a new device builds its own index). Made on first use.
enum SearchKey {
    static let service = "\(AppIdentity.bundleId).search-index"

    @concurrent
    static func key(for store: String) async throws -> String {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: store, kSecReturnData as String: true]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data, let key = String(data: data, encoding: .utf8) {
            return key
        }
        // only a key that is not there is made: one the Keychain cannot give now (the iPhone not
        // unlocked since it started: errSecInteractionNotAllowed) is an error, never a new key,
        // which would read the index as another key's file and replace it.
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status == errSecSuccess ? errSecDecode : status))
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAllocate))
        }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        query[kSecReturnData as String] = nil
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return key
    }

    /// The key of `store`'s index when the app has made it; an extension reads it, never makes it.
    @concurrent
    static func existingKey(for store: String) async -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: store, kSecReturnData as String: true]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the key of `store`'s index, with the account.
    static func delete(for store: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: store]
        SecItemDelete(query as CFDictionary)
    }
}
