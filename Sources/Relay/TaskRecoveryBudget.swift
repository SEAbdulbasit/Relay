import CryptoKit
import Foundation

/// Operation errors and complete-window read errors are separate domains. A
/// read can reconcile only a preexisting error for its exact validated scope.
nonisolated struct TaskRecoveryBudget {
    fileprivate enum Domain: Hashable, Sendable { case operation, windowRead }
    struct Key: Hashable, Sendable {
        let fingerprint: String
        let resolvesOnVerifiedSuccess: Bool
        fileprivate let domain: Domain
    }
    struct WindowReadAttempt: Sendable {
        fileprivate let owner: UUID
        fileprivate let id: UUID
    }
    enum Limit: LocalizedError {
        case repeatedIssue, unresolvedIssues
        var errorDescription: String? {
            switch self {
            case .repeatedIssue:
                "The same operation on this target still fails after three recovery opportunities. Inspect the remaining blocker before another attempt."
            case .unresolvedIssues:
                "The task has too many unresolved tool errors. Verified work is preserved; inspect the remaining blockers."
            }
        }
    }
    private struct Issue {
        var count: Int
        // Never reused when an issue is cleared, evicted or recreated (no ABA).
        var version: UUID
    }
    private struct PreparedRead {
        let attemptID: UUID
        let versions: [Key: UUID]
    }
    private let owner = UUID()
    private var failures: [Key: Issue] = [:]
    private var preparedReads: [UUID: PreparedRead] = [:]
    private var readOrder: [UUID] = []
    var hasUnresolvedErrors: Bool { !failures.isEmpty }

    static func key(for call: ToolCall, observedScope: String?) -> Key {
        let references: Set<String> = ["element_id", "window_id", "root_ref"]
        let arguments = call.arguments.filter { !references.contains($0.key) }
        var value: [String: JSONValue] = [
            "tool": .string(call.name), "arguments": .object(arguments),
            "scope": .string(observedScope.map { "observed:" + $0 } ?? "unbound")
        ]
        if observedScope == nil {
            // Values rotate, but scoped reads must never collide with a broad
            // observation or another reference kind when their proof is absent.
            value["reference_kinds"] = .array(call.arguments.keys.filter { references.contains($0) }.sorted().map(JSONValue.string))
        }
        let unboundControl = observedScope == nil && ["set_value", "press_control", "scroll_control"].contains(call.name)
        return Key(fingerprint: digest(.object(value)), resolvesOnVerifiedSuccess: !unboundControl, domain: .operation)
    }

    static func windowReadKey(_ window: NativeRecoveryIdentityRegistry.WindowID) -> Key {
        Key(fingerprint: digest(.object(["domain": .string("full-native-window-read"), "scope": .string(window.opaqueValue)])),
            resolvesOnVerifiedSuccess: true, domain: .windowRead)
    }

    static func unboundWindowReadKey(originalAction: Key) -> Key {
        Key(fingerprint: digest(.object(["domain": .string("unbound-native-window-read"), "action": .string(originalAction.fingerprint)])),
            resolvesOnVerifiedSuccess: false, domain: .windowRead)
    }

    /// Capture before the physical read. A bounded snapshot permits a window's
    /// document identity to become positively known only after the full read.
    mutating func captureWindowReadAttempt(for attemptID: UUID) -> WindowReadAttempt {
        let versions = failures.filter { $0.key.domain == .windowRead && $0.key.resolvesOnVerifiedSuccess }.mapValues(\.version)
        if readOrder.count >= 128 { preparedReads.removeValue(forKey: readOrder.removeFirst()) }
        let id = UUID()
        preparedReads[id] = PreparedRead(attemptID: attemptID, versions: versions)
        readOrder.append(id)
        return WindowReadAttempt(owner: owner, id: id)
    }

    /// Call only with the identity/attempt ID from a consumed MacTools receipt.
    /// No await may separate receipt consumption from this atomic bookkeeping.
    @discardableResult
    mutating func recordVerifiedWindowRead(_ attempt: WindowReadAttempt,
        window: NativeRecoveryIdentityRegistry.WindowID, attemptID: UUID) -> Bool {
        guard attempt.owner == owner else { return false }
        guard let prepared = preparedReads.removeValue(forKey: attempt.id) else { return false }
        readOrder.removeAll { $0 == attempt.id }
        let key = Self.windowReadKey(window)
        guard prepared.attemptID == attemptID, let version = prepared.versions[key],
              failures[key]?.version == version else { return false }
        failures.removeValue(forKey: key)
        return true
    }

    mutating func discardWindowReadAttempt(_ attempt: WindowReadAttempt) {
        guard attempt.owner == owner else { return }
        preparedReads.removeValue(forKey: attempt.id)
        readOrder.removeAll { $0 == attempt.id }
    }

    mutating func recordFailure(_ key: Key) throws {
        if failures[key] == nil, failures.count >= 128 { throw Limit.unresolvedIssues }
        let count = min((failures[key]?.count ?? 0) + 1, 4)
        failures[key] = Issue(count: count, version: UUID())
        if count > 3 { throw Limit.repeatedIssue }
    }

    mutating func recordVerifiedSuccess(_ key: Key) {
        guard key.domain == .operation, key.resolvesOnVerifiedSuccess else { return }
        failures.removeValue(forKey: key)
    }

    private static func digest(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
