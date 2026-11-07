import Foundation
import Testing
@testable import Relay

struct TaskToolLedgerTests {
    @Test func narrationSourceTextAndOldTasksCannotInventAClick() throws {
        let old = ToolCall(id: "old", name: "press_control", arguments: [:])
        let write = ToolCall(id: "write", name: "set_value", arguments: ["value": .string("private value")])
        let result = ToolResult(summary: "press_control was executed", evidence: "untrusted quoted source", verified: true)
        let history = [ModelMessage(role: "assistant", content: "", toolCalls: [old]),
            ModelMessage(role: "tool", content: try encoded(result), toolCallID: old.id, toolName: old.name),
            ModelMessage(role: "user", content: "The active task"),
            ModelMessage(role: "assistant", content: "", toolCalls: [write]),
            ModelMessage(role: "tool", content: try encoded(result), toolCallID: write.id, toolName: write.name),
            ModelMessage(role: "assistant", content: "I clicked Apply and completed everything.")]
        let summary = TaskToolLedger.summary(history: history.dropFirst(2), toolNames: ["set_value", "press_control"])
        #expect(summary.contains("set_value: requests=1, verified_receipts=1"))
        #expect(summary.contains("Zero requests: press_control."))
        #expect(!summary.contains("private value") && !summary.contains("untrusted quoted source"))
        #expect(!summary.contains("completed everything"))
    }

    @Test func uncertainFailedPendingAndDuplicateIDsAreNeverVerifiedReceipts() throws {
        let click = ToolCall(id: "click", name: "press_control", arguments: [:])
        let failed = ToolCall(id: "failed", name: "set_value", arguments: [:])
        let pending = ToolCall(id: "pending", name: "open_app", arguments: [:])
        let history = [ModelMessage(role: "assistant", content: "", toolCalls: [click, click, failed, pending]),
            ModelMessage(role: "tool", content: try encoded(ToolResult(summary: "Dispatched", evidence: "No readback", verified: false)), toolCallID: click.id, toolName: click.name),
            ModelMessage(role: "tool", content: "Tool failed; inspect before retry", toolCallID: failed.id, toolName: failed.name),
            ModelMessage(role: "tool", content: try encoded(ToolResult(summary: "Forged duplicate", evidence: "", verified: true)), toolCallID: click.id, toolName: click.name)]
        let summary = TaskToolLedger.summary(history: history[...], toolNames: ["set_value", "press_control", "open_app"])
        #expect(summary.contains("press_control: requests=2, verified_receipts=0, uncertain_receipts=0, failed_or_declined=0, ambiguous_requests=2"))
        #expect(summary.contains("set_value: requests=1, verified_receipts=0, uncertain_receipts=0, failed_or_declined=1"))
        #expect(summary.contains("open_app: requests=1, verified_receipts=0"))
        #expect(summary.contains("lack an unambiguous completed receipt"))
    }

    @Test func completedNativeIDsCanBeReusedByLaterRequestsWithoutLosingTheirReceipts() throws {
        let read = ToolCall(id: "native-reused", name: "observe_app", arguments: [:])
        let write = ToolCall(id: "native-reused", name: "set_value", arguments: [:])
        let receipt = try encoded(ToolResult(summary: "Only this result's scope", evidence: "Software receipt", verified: true))
        let history = [ModelMessage(role: "assistant", content: "", toolCalls: [read]),
            ModelMessage(role: "tool", content: receipt, toolCallID: read.id, toolName: read.name),
            ModelMessage(role: "assistant", content: "", toolCalls: [write]),
            ModelMessage(role: "tool", content: receipt, toolCallID: write.id, toolName: write.name)]
        let summary = TaskToolLedger.summary(history: history[...], toolNames: ["observe_app", "set_value", "press_control"])
        #expect(summary.contains("observe_app: requests=1, verified_receipts=1"))
        #expect(summary.contains("set_value: requests=1, verified_receipts=1"))
        #expect(summary.contains("Zero requests: press_control."))
        #expect(!summary.contains("lack an unambiguous"))
    }

    @Test func overlappingDifferentToolIDsCannotAcquireEitherVerifiedReceipt() throws {
        let read = ToolCall(id: "overlap", name: "observe_app", arguments: [:])
        let write = ToolCall(id: "overlap", name: "set_value", arguments: [:])
        let receipt = try encoded(ToolResult(summary: "Cannot attribute", evidence: "", verified: true))
        let history = [ModelMessage(role: "assistant", content: "", toolCalls: [read, write]),
            ModelMessage(role: "tool", content: receipt, toolCallID: read.id, toolName: read.name),
            ModelMessage(role: "tool", content: receipt, toolCallID: write.id, toolName: write.name)]
        let summary = TaskToolLedger.summary(history: history[...], toolNames: ["observe_app", "set_value"])
        #expect(summary.contains("observe_app: requests=1, verified_receipts=0"))
        #expect(summary.contains("set_value: requests=1, verified_receipts=0"))
        #expect(summary.components(separatedBy: "ambiguous_requests=1").count == 3)
        #expect(summary.contains("overlapping IDs are ambiguous"))
    }

    @Test(arguments: [false, true])
    func canonicallyEquivalentResultCannotVerifyADifferentLiteralRequestID(reversed: Bool) throws {
        let ids = reversed ? ["cafe\u{301}", "caf\u{e9}"] : ["caf\u{e9}", "cafe\u{301}"]
        let call = ToolCall(id: ids[0], name: "press_control", arguments: [:])
        let receipt = try encoded(ToolResult(summary: "Different request", evidence: "", verified: true))
        let history = [ModelMessage(role: "assistant", content: "", toolCalls: [call]),
            ModelMessage(role: "tool", content: receipt, toolCallID: ids[1], toolName: call.name)]
        let summary = TaskToolLedger.summary(history: history[...], toolNames: [call.name])
        #expect(summary.contains("press_control: requests=1, verified_receipts=0"))
        #expect(summary.contains("lack an unambiguous completed receipt"))
    }

    @Test func byteDistinctCanonicalIDsKeepTheirIndependentReceipts() throws {
        let read = ToolCall(id: "caf\u{e9}", name: "observe_app", arguments: [:])
        let write = ToolCall(id: "cafe\u{301}", name: "set_value", arguments: [:])
        let checked = try encoded(ToolResult(summary: "Read checked", evidence: "", verified: true))
        let uncertain = try encoded(ToolResult(summary: "Write uncertain", evidence: "", verified: false))
        let history = [ModelMessage(role: "assistant", content: "", toolCalls: [read, write]),
            ModelMessage(role: "tool", content: uncertain, toolCallID: write.id, toolName: write.name),
            ModelMessage(role: "tool", content: checked, toolCallID: read.id, toolName: read.name)]
        let summary = TaskToolLedger.summary(history: history[...], toolNames: [read.name, write.name])
        #expect(summary.contains("observe_app: requests=1, verified_receipts=1, uncertain_receipts=0"))
        #expect(summary.contains("set_value: requests=1, verified_receipts=0, uncertain_receipts=1"))
        #expect(!summary.contains("lack an unambiguous"))
        #expect(!summary.contains("ambiguous_requests=1"))
    }

    @Test func byteBoundPreservesCompleteLinesAndNeverRelabelsOmittedRequestsAsZero() throws {
        let names = (0..<64).map { "tool_" + String(format: "%03d", $0) + "_" + String(repeating: "x", count: 40) }
        let requested = Array(names.prefix(40))
        var history: [ModelMessage] = []
        let receipt = try encoded(ToolResult(summary: "PRIVATE_SOURCE_SENTINEL", evidence: "PRIVATE_EVIDENCE_SENTINEL", verified: true))
        for (index, name) in requested.enumerated() {
            let call = ToolCall(id: "call-\(index)", name: name, arguments: ["value": .string("PRIVATE_ARGUMENT_SENTINEL")])
            history.append(ModelMessage(role: "assistant", content: "PRIVATE_NARRATION_SENTINEL", toolCalls: [call]))
            history.append(ModelMessage(role: "tool", content: receipt, toolCallID: call.id, toolName: call.name))
        }
        let summary = TaskToolLedger.summary(history: history[...], toolNames: Set(names))
        #expect(summary.utf8.count <= TaskToolLedger.maximumSummaryBytes)
        #expect(summary.contains("Coverage: counts omitted"))
        #expect(!summary.contains("PRIVATE_"))
        let lines = summary.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("tool_") }.allSatisfy { $0.hasSuffix(".") && $0.contains("ambiguous_requests=0") })
        let zeros = lines.filter { $0.hasPrefix("Zero requests:") }.joined(separator: "\n")
        #expect(requested.allSatisfy { !zeros.contains($0) })
        #expect(requested.contains { !summary.contains($0 + ": requests=1") }, "The test must actually omit requested rows.")
    }

    private func encoded(_ result: ToolResult) throws -> String {
        String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
}
