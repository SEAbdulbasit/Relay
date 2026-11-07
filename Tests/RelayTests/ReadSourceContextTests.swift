import Foundation
import Testing
@testable import Relay

struct ReadSourceContextTests {
    @Test func largeReadKeepsExplicitPartialCoverageUncertaintyEvidenceAndExactTaskWithoutChangingAudit() throws {
        let goal = "Quote only supported source facts; preserve cafe\u{301} 🌍."
        let source = "BEGIN-CODE café\u{301}\n" + String(repeating: "Long synthetic source 🌍\n", count: 1_000) + "\nEND-CODE-8374"
        let history = pair(tool: "read_file", summary: source, verified: false, goal: goal)
        let original = try #require(history.last)
        let window = try ContextWindow.prepare(history, activeStart: 0, budget: 4_000)
        let excerpt = try #require(window.messages.last)
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: Data(excerpt.content.utf8))
        #expect(ContextWindow.bytes(window.messages) <= 4_000 && ContextWindow.isWellFormed(window.messages))
        #expect(payload["verified"] == .bool(false) && payload["evidence"]?.string == "Complete synthetic read evidence; no UI or file was read.")
        #expect(payload["context_coverage"]?.string?.contains("Explicitly partial") == true)
        #expect(payload["context_coverage"]?.string?.contains("Omitted text is not evidence") == true)
        #expect(payload["summary"]?.string?.hasPrefix("BEGIN-CODE café\u{301}") == true)
        #expect(payload["summary"]?.string?.hasSuffix("END-CODE-8374") == true)
        #expect(window.messages.first?.content.utf8.elementsEqual(goal.utf8) == true)
        #expect(window.messages.flatMap(\.toolCalls) == history.flatMap(\.toolCalls))
        #expect(history.last?.content.utf8.elementsEqual(original.content.utf8) == true)
    }

    @Test func smallReadRemainsByteExactAndHasNoInventedPartialCoverage() throws {
        let history = pair(tool: "read_file", summary: "Exact source café\u{301} 🌍", verified: true)
        let window = try ContextWindow.prepare(history, activeStart: 0, budget: 4_000)
        #expect(window.compactedMessages == 0 && window.messages.map(\.content) == history.map(\.content))
    }

    @Test func listingProjectionKeepsOnlyWholeExactLinesAndNeverAHalfPath() throws {
        let lines = (0..<400).map { "/synthetic/selected/source-\($0)-cafe\u{301}-🌍.txt" }
        let history = pair(tool: "list_files", summary: lines.joined(separator: "\n"), verified: true)
        let window = try ContextWindow.prepare(history, activeStart: 0, budget: 2_000)
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: Data(try #require(window.messages.last).content.utf8))
        let excerpt = try #require(payload["summary"]?.string)
        let kept = excerpt.split(separator: "\n").map(String.init)
        #expect(!kept.isEmpty && kept.count < lines.count && kept.allSatisfy { lines.contains($0) })
        #expect(kept.allSatisfy { $0.hasSuffix(".txt") })
        #expect(payload["context_coverage"]?.string?.contains("partial") == true)
        let oversizedPath = "/synthetic/" + String(repeating: "x", count: 8_000) + ".txt"
        #expect(throws: RelayError.self) {
            try ContextWindow.prepare(pair(tool: "list_files", summary: oversizedPath, verified: true), activeStart: 0, budget: 1_000)
        }
    }

    @Test(arguments: ["observe_app", "create_mail_draft", "prepare_mail_send", "preview_file_move", "send_mail", "move_file", "set_value", "press_control"])
    func freshControlsAndOpaqueOrMutationReceiptsCannotBeExcerpted(tool: String) {
        let source = String(repeating: "Exact receipt content\n", count: 600) + "\nOPAQUE-IDENTIFIER-AT-END-4783"
        #expect(throws: RelayError.self) {
            try ContextWindow.prepare(pair(tool: tool, summary: source, verified: false), activeStart: 0, budget: 1_000)
        }
    }

    private func pair(tool: String, summary: String, verified: Bool, goal: String = "Read the selected synthetic source") -> [ModelMessage] {
        let call = ToolCall(id: "source-call", name: tool, arguments: ["path": .string("/synthetic/selected/source.txt")])
        return [ModelMessage(role: "user", content: goal), ModelMessage(role: "assistant", content: "", toolCalls: [call]),
            ModelMessage(role: "tool", content: JSONValue.object(["summary": .string(summary),
                "evidence": .string("Complete synthetic read evidence; no UI or file was read."), "verified": .bool(verified)]).pretty,
                toolCallID: call.id, toolName: tool)]
    }
}
