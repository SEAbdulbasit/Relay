import Foundation
import Security

nonisolated struct CustomResponsesCredentials: Sendable {
    static let serviceName = "app.relay.custom-responses.api-key.v1"

    struct Store: Sendable {
        let read: @Sendable (String) throws -> Data?
        let write: @Sendable (String, Data) throws -> Void
        let delete: @Sendable (String) throws -> Void

        static func keychain(service: String = CustomResponsesCredentials.serviceName) -> Store {
            Store(
                read: { account in
                    var result: CFTypeRef?
                    let query: [CFString: Any] = [
                        kSecClass: kSecClassGenericPassword,
                        kSecAttrService: service,
                        kSecAttrAccount: account,
                        kSecReturnData: true,
                        kSecMatchLimit: kSecMatchLimitOne
                    ]
                    let status = SecItemCopyMatching(query as CFDictionary, &result)
                    if status == errSecItemNotFound { return nil }
                    guard status == errSecSuccess, let data = result as? Data else {
                        throw CustomResponsesFailure.keychainFailure(status)
                    }
                    return data
                },
                write: { account, data in
                    let query: [CFString: Any] = [
                        kSecClass: kSecClassGenericPassword,
                        kSecAttrService: service,
                        kSecAttrAccount: account
                    ]
                    SecItemDelete(query as CFDictionary)
                    var attributes = query
                    attributes[kSecValueData] = data
                    attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                    let status = SecItemAdd(attributes as CFDictionary, nil)
                    guard status == errSecSuccess else {
                        throw CustomResponsesFailure.keychainFailure(status)
                    }
                },
                delete: { account in
                    let query: [CFString: Any] = [
                        kSecClass: kSecClassGenericPassword,
                        kSecAttrService: service,
                        kSecAttrAccount: account
                    ]
                    let status = SecItemDelete(query as CFDictionary)
                    guard status == errSecSuccess || status == errSecItemNotFound else {
                        throw CustomResponsesFailure.keychainFailure(status)
                    }
                }
            )
        }

        static func memory(_ initial: [String: Data] = [:]) -> Store {
            let box = LockedAccountData(initial)
            return Store(
                read: { account in box.read(account) },
                write: { account, data in box.write(account, data) },
                delete: { account in box.delete(account) }
            )
        }

        static func memory(for endpoint: CustomResponsesEndpoint, key: Data) -> Store {
            memory([endpoint.credentialAccount: key])
        }
    }

    private let store: Store

    init(store: Store = .keychain()) {
        self.store = store
    }

    static func accountName(for endpoint: CustomResponsesEndpoint) -> String {
        endpoint.credentialAccount
    }

    func hasKey(for endpoint: CustomResponsesEndpoint) -> Bool {
        (try? validatedKey(for: endpoint)) != nil
    }

    func validatedKey(for endpoint: CustomResponsesEndpoint) throws -> Data {
        guard let raw = try store.read(endpoint.credentialAccount) else {
            throw CustomResponsesFailure.missingAPIKey
        }
        return try Self.validateKeyData(raw)
    }

    func resolvedKey(for endpoint: CustomResponsesEndpoint, requiresAPIKey: Bool) throws -> Data? {
        if !endpoint.isLoopback || requiresAPIKey {
            return try validatedKey(for: endpoint)
        }
        guard let raw = try store.read(endpoint.credentialAccount) else {
            return nil
        }
        return try Self.validateKeyData(raw)
    }

    func saveKey(_ raw: Data, for endpoint: CustomResponsesEndpoint) throws {
        let valid = try Self.validateKeyData(raw)
        try store.write(endpoint.credentialAccount, valid)
    }

    func clearKey(for endpoint: CustomResponsesEndpoint) throws {
        try store.delete(endpoint.credentialAccount)
    }

    static func validateKeyData(_ raw: Data) throws -> Data {
        let trimmed = trimASCIIWhitespace(raw)
        guard (16...4096).contains(trimmed.count),
              trimmed.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw CustomResponsesFailure.invalidAPIKey
        }
        return trimmed
    }

    private static func trimASCIIWhitespace(_ data: Data) -> Data {
        let bytes = Array(data)
        guard let first = bytes.firstIndex(where: { !isASCIIWhitespace($0) }),
              let last = bytes.lastIndex(where: { !isASCIIWhitespace($0) }) else {
            return Data()
        }
        return Data(bytes[first...last])
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }
}

private nonisolated final class LockedAccountData: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]

    init(_ values: [String: Data]) {
        self.values = values
    }

    func read(_ account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func write(_ account: String, _ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        values[account] = value
    }

    func delete(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}
