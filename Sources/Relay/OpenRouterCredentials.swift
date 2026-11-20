import Foundation
import Security

/// Independent service/account; no subscription token, environment, CLI auth
/// file or other provider's Keychain item is consulted, even on failure.
nonisolated struct OpenRouterCredentials: Sendable {
    static let service = "app.relay.openrouter.api-key.v1"
    static let account = "openrouter-api-key"
    let read: @Sendable () throws -> Data?
    let write: @Sendable (Data?) throws -> Void
    init(read: @escaping @Sendable () throws -> Data?, write: @escaping @Sendable (Data?) throws -> Void) {
        self.read = read; self.write = write
    }
    static var keychain: Self {
        Self(read: {
            var query = baseQuery
            query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw OpenRouterFailure.secureStorage }
            return data
        }, write: { data in
            let query = baseQuery
            guard let data else {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw OpenRouterFailure.secureStorage }
                return
            }
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query; insert[kSecValueData] = data
                insert[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw OpenRouterFailure.secureStorage }
            } else if status != errSecSuccess { throw OpenRouterFailure.secureStorage }
        })
    }
    private static var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
         kSecAttrSynchronizable: false, kSecUseDataProtectionKeychain: true]
    }
    static func validated(_ data: Data) throws -> String {
        guard (16...4_096).contains(data.count), let value = String(data: data, encoding: .utf8),
              value.utf8.allSatisfy({ (33...126).contains($0) }) else { throw OpenRouterFailure.invalidKey }
        return value
    }
}
