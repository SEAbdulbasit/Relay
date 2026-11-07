import Foundation
import Testing
@testable import Relay

struct DesktopActionBatchTests {
    private static let changes = ["set_value", "press_control", "scroll_control"]
    private static let invalidators = ["observe_app", "stage_attachment", "open_app", "open_file", "search_finder",
        "move_file", "browser_navigate", "search_web", "open_url", "write_file", "create_document", "create_spreadsheet"]

    private func call(_ name: String, bundle: String = "test.original.app", arguments: [String: JSONValue] = [:]) -> ToolCall {
        var fields = arguments
        if Self.changes.contains(name) {
            fields["bundle_id"] = .string(bundle)
            fields["element_id"] = .string("previously-observed-control")
        } else if name == "observe_app" { fields["bundle_id"] = .string(bundle) }
        return ToolCall(name: name, arguments: fields)
    }

    @Test func emptyAndIndependentReadOnlyBatchesRemainAvailable() throws {
        try DesktopActionBatch.validate([])
        let names = ["calculate", "list_apps", "read_file", "read_browser_page", "search_knowledge", "list_files",
            "read_calendar", "search_files", "preview_file_move", "prepare_mail_send"]
        try DesktopActionBatch.validate(names.map { call($0) })
        #expect(names.allSatisfy { !DesktopActionBatch.invalidatesReferences(call($0)) })
    }

    @Test(arguments: invalidators + changes)
    func invalidatorClassificationIsSharedByPreflightAndPostActionReadback(_ name: String) {
        #expect(DesktopActionBatch.invalidatesReferences(call(name)))
    }

    @Test(arguments: changes)
    func oneControlChangeCanBeFollowedByUnscopedInspectionAndIndependentReads(_ name: String) throws {
        try DesktopActionBatch.validate([
            call("calculate"), call("read_file"), call(name), call("observe_app"), call("read_browser_page"), call("read_file")
        ])
        try DesktopActionBatch.validate([
            call(name), call("observe_app", arguments: ["window_id": .string(""), "root_ref": .string("")])
        ])
    }

    @Test(arguments: changes, changes)
    func multipleControlChangesRejectEvenAcrossAppsOrWithAnObservationBetween(_ first: String, _ second: String) {
        for separatingRead in [false, true] {
            var batch = [call(first)]
            if separatingRead { batch.append(call("observe_app")) }
            batch.append(call(second, bundle: "test.other.app"))
            #expect(throws: ModelProtocolError.self) { try DesktopActionBatch.validate(batch) }
        }
    }

    @Test(arguments: invalidators, changes)
    func anEarlierInvalidatingCallCannotSupplyReferencesForALaterMutation(_ first: String, _ change: String) {
        #expect(throws: ModelProtocolError.self) {
            try DesktopActionBatch.validate([call(first), call("calculate"), call(change, bundle: "test.other.app")])
        }
    }

    @Test(arguments: invalidators, ["window_id", "root_ref"])
    func scopedInspectionCannotReuseReferencesAfterAnInvalidatingCall(_ first: String, _ reference: String) {
        #expect(throws: ModelProtocolError.self) {
            try DesktopActionBatch.validate([
                call(first), call("observe_app", bundle: "test.other.app", arguments: [reference: .string("old-scope-ref")])
            ])
        }
    }

    @Test func anInitiallyScopedInspectionMayBeFollowedByOnlyUnscopedReads() throws {
        let initial = call("observe_app", arguments: ["window_id": .string("existing-window")])
        try DesktopActionBatch.validate([initial, call("calculate"), call("observe_app")])
        #expect(throws: ModelProtocolError.self) {
            try DesktopActionBatch.validate([initial, call("observe_app", arguments: ["root_ref": .string("@old:e2")])])
        }
    }

    @Test(arguments: ["focus", "check", "uncheck", "select", "toggle", "expand", "collapse"])
    func controlActionVariantsAndPotentialNoOpsStillConsumeOneChange(_ action: String) {
        let first = call("press_control", arguments: ["action": .string(action)])
        #expect(throws: ModelProtocolError.self) { try DesktopActionBatch.validate([first, call("press_control")]) }
    }

    @Test func stagingAndFileWritesMayFollowAControlChangeWhenNoOldReferenceFollows() throws {
        try DesktopActionBatch.validate([call("set_value"), call("write_file"), call("read_file")])
        try DesktopActionBatch.validate([call("set_value"), call("stage_attachment"), call("observe_app")])
    }

    @Test func malformedOrWhitespaceScopeCannotBypassThePreflightReferenceFence() {
        for value in [JSONValue.string(" "), .number(4), .null] {
            #expect(throws: ModelProtocolError.self) {
                try DesktopActionBatch.validate([call("set_value"), call("observe_app", arguments: ["window_id": value])])
            }
        }
    }

    @Test func theCompleteReplyIsRefusedBeforeAnyDispatchAndExactArgumentsStayUntouched() throws {
        let literal = "Cafe\u{0301} 🌍\nKeep exact bytes and opaque review-id-8431."
        let batch = [call("write_file", arguments: ["path": .string("/synthetic/reply.md"), "content": .string(literal)]),
                     call("press_control")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(batch)
        var dispatched: [ToolCall] = []
        do {
            try DesktopActionBatch.validate(batch)
            dispatched.append(contentsOf: batch)
            Issue.record("A rejected desktop batch reached dispatch.")
        } catch let error as ModelProtocolError {
            #expect(error.localizedDescription.contains("No action from that reply was dispatched"))
            #expect(error.localizedDescription.contains("unscoped observe_app"))
        }
        #expect(dispatched.isEmpty)
        #expect(try encoder.encode(batch).elementsEqual(original))
        #expect(batch[0].arguments["content"]?.string?.utf8.elementsEqual(literal.utf8) == true)
    }
}
