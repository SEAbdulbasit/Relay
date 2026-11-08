import Foundation
import Testing
@testable import Relay

@Suite(.serialized) @MainActor struct LocalModelHistorySourcesTests {
    @Test func equalBodiesAndReusedProviderIDsKeepTheirExactAcceptedGroup() async throws {
        let book = LocalModelHistorySources(), a = State("A"), b = State("B"), run = UUID()
        var history = [ModelMessage(role: "user", content: "Read the admitted synthetic sources.")]
        let first = try appendRead(book, history: &history, run: run, provider: "reused-id", text: "IDENTICAL_PRIVATE_BODY", source: a)
        let second = try appendRead(book, history: &history, run: run, provider: "reused-id", text: "IDENTICAL_PRIVATE_BODY", source: b)
        a.current = false
        let projected = try await book.project(history, activeStart: 0, currentRun: run, budget: 10_000, gate: {})
        #expect(projected.omittedGroups == 1 && ContextWindow.isWellFormed(projected.messages))
        #expect(!projected.originalIndices.contains(first.start) && projected.originalIndices.contains(second.start))
        #expect(projected.messages.filter { $0.role == "tool" }.count == 1)
        #expect(projected.messages.filter { $0.role == "tool" }.first?.content.utf8.elementsEqual(history[second.start + 1].content.utf8) == true)
        let oldChecks = a.checks
        try await projected.validate(); try await projected.sourceProof?.validate()
        #expect(a.checks == oldChecks && b.checks > 1)
    }
    @Test func staleInputOmitsNarrationExactArgumentsWholeBatchAndLateAppDerivedCorrection() async throws {
        let book = LocalModelHistorySources(), a = State("A"), run = UUID()
        let secret = "PRIVATE_cafe\u{301}_" + UUID().uuidString
        var history = [ModelMessage(role: "user", content: "Keep this exact user constraint.")]
        _ = try appendRead(book, history: &history, run: run, provider: "source", text: secret, source: a)
        let group = UUID(), index = history.count
        let calls = [ToolCall(id: "write", name: "write_file", arguments: ["path": .string("/owned/output.txt"), "content": .string(secret)]),
                     ToolCall(id: "calc", name: "calculate", arguments: ["expression": .string("1+1")])]
        let reply = ModelReply(content: "Source-derived narration: " + secret, toolCalls: calls)
        history.append(.init(role: "assistant", content: reply.content, toolCalls: calls))
        try book.acceptReply(at: index, groupID: group, runID: run, reply: reply, inputProof: a.proof)
        for call in calls {
            history.append(tool(call, text: "Actual result for " + secret))
            try book.returned(groupID: group, call: call, receipt: .verified)
        }
        let correction = history.count
        history.append(.init(role: "user", content: "App-generated correction includes " + secret))
        try book.appDerivedMessage(at: correction, runID: run, inputProof: a.proof)
        history.append(.init(role: "user", content: "Preserve this later real user message byte for byte."))
        let original = history
        a.current = false
        let view = try await book.project(history, activeStart: 0, currentRun: run, budget: 10_000, gate: {})
        #expect(view.omittedGroups == 3 && ContextWindow.isWellFormed(view.messages))
        #expect(!view.messages.map(\.content).joined().contains(secret))
        #expect(view.messages.flatMap(\.toolCalls).isEmpty && view.messages.filter { $0.role == "tool" }.isEmpty)
        #expect(view.messages.contains { $0.content.utf8.elementsEqual(original.last!.content.utf8) })
        #expect(history[index].content.utf8.elementsEqual(reply.content.utf8))
        #expect(view.messages.contains { $0.content.contains("returned_verified_receipts") })
    }
    @Test func contextWindowOmittedHistoryNeverCallsItsSourceValidator() async throws {
        let book = LocalModelHistorySources(), a = State("old"), run = UUID()
        var history = [ModelMessage(role: "user", content: "Earlier completed request.")]
        _ = try appendRead(book, history: &history, run: run, provider: "old", text: String(repeating: "private old source ", count: 1_000), source: a)
        let current = history.count
        history.append(.init(role: "user", content: "Answer this new source-free request."))
        let view = try await book.project(history, activeStart: current, currentRun: UUID(), budget: 900, gate: {})
        #expect(a.checks == 0 && view.sourceProof == nil && view.originalIndices.contains(current))
        #expect(view.originalIndices.filter { $0 == nil }.count >= 1)
        #expect(view.messages.count == view.originalIndices.count)
    }
    @Test func evictedUnregisteredAndRebasedSourceDataNeverBecomeSourceFree() async throws {
        let book = LocalModelHistorySources(), a = State("A"), run = UUID()
        var history = [ModelMessage(role: "user", content: "Actual user.")]
        let group = try appendRead(book, history: &history, run: run, provider: "a", text: "PRIVATE_A", source: a)
        book.retireProof(groupID: group.id)
        let first = try await book.project(history, activeStart: 0, currentRun: run, budget: 6_000, gate: {})
        #expect(!first.messages.map(\.content).joined().contains("PRIVATE_A"))
        let derived = history.count
        history.append(.init(role: "user", content: "PRIVATE_APP_CORRECTION"))
        try book.appDerivedMessage(at: derived, runID: run, inputProof: a.proof)
        history.append(.init(role: "user", content: "Actual later UI input."))
        let kept = [derived, history.count - 1]
        book.rebase(keepingOriginalIndices: kept); history = kept.map { history[$0] }
        let rebased = try await book.project(history, activeStart: 0, currentRun: UUID(), budget: 6_000, gate: {})
        #expect(!rebased.messages.map(\.content).joined().contains("PRIVATE_APP_CORRECTION"))
        #expect(rebased.messages.contains { $0.content == "Actual later UI input." })
        book.reset()
        let call = ToolCall(id: "unregistered", name: "read_file", arguments: ["path": .string("/owned/source.txt")])
        history = [.init(role: "user", content: "Read source."), .init(role: "assistant", content: "", toolCalls: [call]), tool(call, text: "UNREGISTERED_PRIVATE")]
        let unknown = try await book.project(history, activeStart: 0, currentRun: run, budget: 6_000, gate: {})
        #expect(unknown.omittedGroups == 1 && !unknown.messages.map(\.content).joined().contains("UNREGISTERED_PRIVATE"))
    }
    @Test func preparedViewRejectsStopResetAndSourceDriftOnItsSuccessOrErrorFence() async throws {
        let book = LocalModelHistorySources(), a = State("A"), run = UUID()
        var history = [ModelMessage(role: "user", content: "Read source.")]
        _ = try appendRead(book, history: &history, run: run, provider: "a", text: "PRIVATE_A", source: a)
        let view = try await book.project(history, activeStart: 0, currentRun: run, budget: 6_000, gate: {})
        a.current = false
        await #expect(throws: (any Error).self) { try await view.validate() }
        a.current = true; book.reset()
        await #expect(throws: (any Error).self) { try await view.validate() }
    }
    @Test func omissionCoverageNeverEchoesAnUnrecognizedSourceDerivedToolName() async throws {
        let book = LocalModelHistorySources(), a = State("A"), run = UUID(), secret = "private_unrecognized_tool_551"
        let call = ToolCall(id: "invalid", name: secret, arguments: [:]), id = UUID()
        let history = [ModelMessage(role: "user", content: "User input."), ModelMessage(role: "assistant", content: "", toolCalls: [call]), tool(call, text: "failed")]
        try book.acceptReply(at: 1, groupID: id, runID: run, reply: .init(content: "", toolCalls: [call]), inputProof: a.proof)
        a.current = false
        let view = try await book.project(history, activeStart: 0, currentRun: run, budget: 6_000, gate: {})
        #expect(!view.messages.map(\.content).joined().contains(secret))
        #expect(view.messages.map(\.content).joined().contains("unrecognized_tool"))
    }
    private func appendRead(_ book: LocalModelHistorySources, history: inout [ModelMessage], run: UUID,
                            provider: String, text: String, source: State) throws -> (id: UUID, start: Int) {
        let id = UUID(), start = history.count
        let call = ToolCall(id: provider, name: "read_file", arguments: ["path": .string("/owned/source.txt")])
        history.append(.init(role: "assistant", content: "", toolCalls: [call]))
        try book.acceptReply(at: start, groupID: id, runID: run, reply: .init(content: "", toolCalls: [call]), inputProof: nil)
        history.append(tool(call, text: text))
        try book.returned(groupID: id, call: call, receipt: .verified)
        try book.resultSource(groupID: id, call: call, proof: source.proof)
        return (id, start)
    }
    private func tool(_ call: ToolCall, text: String) -> ModelMessage {
        .init(role: "tool", content: JSONValue.object(["summary": .string(text), "evidence": .string("Actual synthetic data receipt"), "verified": .bool(true)]).pretty,
            toolCallID: call.id, toolName: call.name)
    }
    @MainActor private final class State {
        let owner = UUID(), name: String
        var current = true, checks = 0
        init(_ name: String) { self.name = name }
        lazy var proof = ModelInputSourceProof.source(identity: .init(owner: owner, sourceID: Data(name.utf8), purpose: "actual inert source")) { [self] in
            checks += 1; guard current else { throw LocalModelHistorySources.Failure.unavailable }
        }
    }
}

@Suite @MainActor struct ContextWindowSourceIndexTests {
    @Test func actualInputPositionsSurviveAnOmittedPrefixAndSyntheticNotice() throws {
        let call = ToolCall(id: "old", name: "read_file", arguments: ["path": .string("/owned/old.txt")])
        let history = [ModelMessage(role: "user", content: "Earlier request."), ModelMessage(role: "assistant", content: "", toolCalls: [call]),
            ModelMessage(role: "tool", content: String(repeating: "OLD_PRIVATE ", count: 1_000), toolCallID: call.id, toolName: call.name),
            ModelMessage(role: "user", content: "Exact current user request cafe\u{301}.")]
        let view = try ContextWindow.prepare(history, activeStart: 3, budget: 900)
        #expect(view.messages.count == view.originalIndices.count && view.originalIndices.first! == nil)
        #expect(view.originalIndices.compactMap { $0 } == [3])
        #expect(view.messages.last?.content.utf8.elementsEqual(history[3].content.utf8) == true)
    }
}
