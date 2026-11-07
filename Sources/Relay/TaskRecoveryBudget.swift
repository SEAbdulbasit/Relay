import CryptoKit
import Foundation

/// Counts unresolved errors for a particular operation and observed target.
/// A fresh read is an opportunity to reassess, never permission to replay an
/// action. Successful unrelated tools cannot replenish a failed action's budget.
nonisolated struct TaskRecoveryBudget {
    struct Key: Hashable, Sendable {
        let fingerprint: String
        let resolvesOnVerifiedSuccess: Bool
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

    private var failures: [Key: Int] = [:]
    var hasUnresolvedErrors: Bool { !failures.isEmpty }

    static func key(for call: ToolCall, observedScope: String?) -> Key {
        // Request IDs and observation-local refs rotate on every read. They are
        // neither a new user intent nor evidence that an error was recovered.
        let references: Set<String> = ["element_id", "window_id", "root_ref"]
        let arguments = call.arguments.filter { !references.contains($0.key) }
        let value = JSONValue.object([
            "tool": .string(call.name), "arguments": .object(arguments),
            "scope": .string(observedScope.map { "observed:" + $0 } ?? "unbound")
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(value)) ?? Data()
        let unboundControl = observedScope == nil && ["set_value", "press_control", "scroll_control"].contains(call.name)
        return Key(fingerprint: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                   resolvesOnVerifiedSuccess: !unboundControl)
    }

    mutating func recordFailure(_ key: Key) throws {
        if failures[key] == nil, failures.count >= 128 { throw Limit.unresolvedIssues }
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        // Initial failure, then at most three model-directed recovery attempts.
        if count > 3 { throw Limit.repeatedIssue }
    }

    mutating func recordVerifiedSuccess(_ key: Key) {
        // With no observed target identity, a successful different control can
        // look identical after rotating IDs are removed. Keep that issue open.
        guard key.resolvesOnVerifiedSuccess else { return }
        failures.removeValue(forKey: key)
    }
}
