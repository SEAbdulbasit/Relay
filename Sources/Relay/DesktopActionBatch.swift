import Foundation

/// Validates one proposed reply before any call is reviewed or dispatched.
/// Snapshot IDs are chosen before execution, so a later call in the same reply
/// cannot use IDs produced by an earlier observation or UI change.
nonisolated enum DesktopActionBatch {
    private static let controlChanges: Set<String> = ["set_value", "press_control", "scroll_control"]
    // These mirror the entry points that discard MacTools' native/helper cache.
    // File writes invalidate too: a document change can replace its open UI.
    private static let referenceInvalidators: Set<String> = controlChanges.union([
        "observe_app", "stage_attachment", "open_app", "open_file", "search_finder", "move_file",
        "browser_navigate", "search_web", "open_url", "write_file", "create_document", "create_spreadsheet"
    ])

    static func invalidatesReferences(_ call: ToolCall) -> Bool {
        referenceInvalidators.contains(call.name)
    }

    static func validate(_ calls: [ToolCall]) throws {
        var changedControl = false
        var earlierInvalidator: String?
        for call in calls {
            let changesControl = controlChanges.contains(call.name)
            if changesControl, changedControl {
                throw ModelProtocolError.invalidAction("Return at most one desktop control change per reply. Choose the next change, optionally followed by an unscoped observe_app. Wait for its result before choosing another control ID")
            }
            let consumesReferences = changesControl || (call.name == "observe_app"
                && (hasReference(call.arguments["window_id"]) || hasReference(call.arguments["root_ref"])))
            if consumesReferences, let earlierInvalidator {
                throw ModelProtocolError.invalidAction("\(earlierInvalidator) expires previously observed control and window IDs. Do not combine it with a later reference-based call. Return an unscoped observe_app, wait for the fresh result, then choose the next control")
            }
            if changesControl { changedControl = true }
            if invalidatesReferences(call) { earlierInvalidator = call.name }
        }
    }

    private static func hasReference(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if case .string(let text) = value { return !text.isEmpty }
        // Incorrect argument types belong to schema validation. They cannot
        // make a scoped inspection look like an unscoped read at this boundary.
        return true
    }
}
