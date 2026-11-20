import Contacts
import Dispatch
import Foundation

/// The rows that actually fit the existing local inference excerpt.
nonisolated struct ChatArchiveExcerpt: Sendable {
    struct Row: Sendable {
        let text: String
        let incomingHandle: String?
    }

    let rows: [Row]

    init(messages: [ChatArchiveEntry]) {
        var selected: [Row] = []
        var remaining = 8_000
        for message in messages.reversed() {
            let text = "\(message.time) — \(message.sender): \(message.body)"
            let count = text.utf8.count
            guard count <= remaining else { break }
            remaining -= count
            selected.append(Row(text: text, incomingHandle: message.incomingHandle))
        }
        rows = Array(selected.reversed())
    }
}

nonisolated enum MessagesArchiveContacts {
    static let maximumHandleBytes = 254
    private static let maximumCandidateContacts = 16
    private static let maximumIdentityValues = 32

    enum Identity: Hashable, Sendable {
        case email(String)
        case phone(String)

        init?(_ raw: String) {
            guard !raw.isEmpty, raw.utf8.count <= MessagesArchiveContacts.maximumHandleBytes,
                  raw.utf8.allSatisfy({ $0 < 128 }) else { return nil }
            if raw.contains("@") {
                guard let address = Self.emailAddress(raw) else { return nil }
                self = .email(address)
            } else {
                guard let number = Self.internationalNumber(raw) else { return nil }
                self = .phone(number)
            }
        }

        private static func emailAddress(_ raw: String) -> String? {
            let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let local = parts[0], domain = parts[1]
            let localPunctuation = Set(".!#$%&'*+-/=?^_`{|}~".utf8)
            guard (1...64).contains(local.utf8.count), !local.hasPrefix("."), !local.hasSuffix("."),
                  !local.contains(".."), local.utf8.allSatisfy({ asciiAlphanumeric($0) || localPunctuation.contains($0) }) else {
                return nil
            }
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2, labels.allSatisfy({ label in
                (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.utf8.allSatisfy { asciiAlphanumeric($0) || $0 == 45 }
            }) else { return nil }
            // A Contacts predicate is case-insensitive. Post-match the
            // local part byte-for-byte, and normalize only the DNS name.
            return "\(local)@\(domain.lowercased())"
        }

        private static func internationalNumber(_ raw: String) -> String? {
            guard raw.utf8.first == 43 else { return nil }
            let separators = Set(" -().".utf8)
            let body = raw.utf8.dropFirst()
            guard body.allSatisfy({ (48...57).contains($0) || separators.contains($0) }) else { return nil }
            let digits = body.filter { (48...57).contains($0) }
            guard (7...15).contains(digits.count), digits.first != 48 else { return nil }
            return "+" + String(decoding: digits, as: UTF8.self)
        }

        private static func asciiAlphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }

    struct Candidate: Sendable {
        let name: String
        let identifiers: [String]
    }

    struct Attribution: Equatable, Identifiable, Sendable {
        let handle: String
        let name: String
        var id: String { handle }
    }

    struct Directory: Sendable {
        let authorized: @Sendable (_ mayRequestAccess: Bool) async -> Bool
        let lookup: @Sendable (Identity) async -> [Candidate]?

        static let contacts = Directory(authorized: { await sdkAuthorized(mayRequestAccess: $0) },
            lookup: { await sdkLookup($0) })
    }

    @MainActor static func attributions(in excerpt: ChatArchiveExcerpt, enabled: Bool,
        directory: Directory, validateCurrent: @MainActor () throws -> Void) async throws -> [Attribution] {
        @MainActor func check() throws { try Task.checkCancellation(); try validateCurrent() }
        try check()
        guard enabled else { return [] }
        var seenHandles = Set<String>()
        let handles: [(String, Identity)] = excerpt.rows.compactMap { row in
            guard let raw = row.incomingHandle, let identity = Identity(raw),
                  seenHandles.insert(raw).inserted else { return nil }
            return (raw, identity)
        }
        guard !handles.isEmpty else { return [] }
        let granted = await directory.authorized(true)
        try check()
        guard granted else { return [] }

        var queried = Set<Identity>(), names: [Identity: String] = [:]
        for (_, identity) in handles where queried.insert(identity).inserted {
            try check()
            let candidates = await directory.lookup(identity)
            try check()
            if let candidates, let name = uniqueName(identity, candidates: candidates) { names[identity] = name }
        }
        let stillAuthorized = await directory.authorized(false)
        try check()
        guard stillAuthorized else { return [] }
        return handles.compactMap { raw, identity in
            names[identity].map { Attribution(handle: raw, name: $0) }
        }
    }

    private static func uniqueName(_ identity: Identity, candidates: [Candidate]) -> String? {
        guard candidates.count <= maximumCandidateContacts,
              candidates.allSatisfy({ $0.identifiers.count <= maximumIdentityValues }) else { return nil }
        let matches = candidates.filter { $0.identifiers.contains { Identity($0) == identity } }
        guard matches.count == 1, let name = matches.first?.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }

    private static let queue = DispatchQueue(label: "dev.relay.archive-contacts", qos: .userInitiated)

    private static var hasContactsPurpose: Bool {
        Bundle.main.bundleIdentifier == "dev.relay.assistant"
            && (Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") as? String)?.isEmpty == false
    }

    private static func sdkAuthorized(mayRequestAccess: Bool) async -> Bool {
        guard hasContactsPurpose else { return false }
        return await onQueue(fallback: false) { result in
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: result.resume(returning: true)
            case .notDetermined where mayRequestAccess:
                CNContactStore().requestAccess(for: .contacts) { granted, _ in result.resume(returning: granted) }
            default: result.resume(returning: false)
            }
        }
    }

    private static func sdkLookup(_ identity: Identity) async -> [Candidate]? {
        guard hasContactsPurpose else { return nil }
        return await onQueue(fallback: nil) { result in
            result.resume(returning: autoreleasepool { exactCandidates(for: identity) })
        }
    }

    private static func exactCandidates(for identity: Identity) -> [Candidate]? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let predicate: NSPredicate
        let identityKey: String
        switch identity {
        case .email(let address):
            predicate = CNContact.predicateForContacts(matchingEmailAddress: address)
            identityKey = CNContactEmailAddressesKey
        case .phone(let number):
            predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
            identityKey = CNContactPhoneNumbersKey
        }
        let keys: [any CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, identityKey]
            .map { $0 as NSString as any CNKeyDescriptor }
        guard let contacts = try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys),
              contacts.count <= maximumCandidateContacts,
              contacts.allSatisfy({ $0.areKeysAvailable(keys) }) else { return nil }
        return contacts.map { contact in
            let values: [String] = switch identity {
            case .email: contact.emailAddresses.prefix(maximumIdentityValues + 1).map { $0.value as String }
            case .phone: contact.phoneNumbers.prefix(maximumIdentityValues + 1).map { $0.value.stringValue }
            }
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return Candidate(name: name, identifiers: values)
        }
    }

    private static func onQueue<Value: Sendable>(fallback: Value,
        _ start: @escaping @Sendable (CheckedContinuation<Value, Never>) -> Void) async -> Value {
        let gate = QueueCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { result in
                queue.async {
                    guard !gate.isCancelled else { result.resume(returning: fallback); return }
                    start(result)
                }
            }
        } onCancel: { gate.cancel() }
    }

    private final class QueueCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
