import Foundation

/// Browser commit is target-bound. A Return key is never an acceptable fallback,
/// because queued process-wide input can reach a page control after focus changes.
enum BrowserAddressCommit {
    /// A failed AX writability query is never interpreted as permission to edit,
    /// even if its out-parameter contains a stale true value. Confirm support must
    /// be known before entering any URL; unsupported providers receive no payload.
    static func entryConfirmationAction(settableQuerySucceeded: Bool, valueSettable: Bool,
                                        advertisedActions: [String]?) -> String? {
        guard settableQuerySucceeded, valueSettable else { return nil }
        return confirmationAction(advertisedActions: advertisedActions)
    }

    static func confirmationAction(advertisedActions: [String]?) -> String? {
        guard let actions = advertisedActions, !actions.isEmpty, actions.count <= 32,
              Set(actions).count == actions.count, actions.allSatisfy(isTechnicalActionName),
              actions.contains("AXConfirm") else { return nil }
        return "AXConfirm"
    }

    /// Technical native action names only, bounded independently of the AX provider.
    /// This never returns labels, values, URLs or arbitrary diagnostic content.
    static func diagnostic(advertisedActions: [String]?) -> String {
        guard let actions = advertisedActions else { return "unavailable" }
        let names = Array(Set(actions.prefix(32).filter(isTechnicalActionName))).sorted()
        guard !names.isEmpty else { return "none qualified" }
        return names.prefix(8).joined(separator: ", ") + (names.count > 8 || actions.count > 32 ? " (bounded list)" : "")
    }

    private static func isTechnicalActionName(_ name: String) -> Bool {
        name.hasPrefix("AX") && (3...64).contains(name.utf8.count)
            && name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }
}
