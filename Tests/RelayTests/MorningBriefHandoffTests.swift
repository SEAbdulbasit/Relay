import Foundation
import Testing
@testable import Relay

@MainActor
struct MorningBriefHandoffTests {
    @Test func reviewedCardRunsTheEditedRequestLocallyAndReportsVerifiedAction() async throws {
        let fixture = try BriefFixture()
        defer { fixture.remove() }
        var localRequests: [String] = []
        var executed: [String] = []
        let store = AssistantStore(persistenceURL: nil, complete: { messages, tools, _ in
            let request = try #require(messages.last(where: { $0.role == "user" })?.content)
            localRequests.append(request)
            if tools.isEmpty { return ModelReply(content: "Open Calculator locally.", toolCalls: []) }
            if executed.isEmpty {
                return ModelReply(content: "", toolCalls: [ToolCall(name: "open_app", arguments: ["app": .string("Calculator")])])
            }
            return ModelReply(content: "Calculator is open.", toolCalls: [])
        }, execute: { call in
            executed.append(call.name)
            return ToolResult(summary: "Opened Calculator", evidence: "Synthetic app-process receipt", verified: true)
        }, codexComplete: { _, _ in
            Issue.record("A briefing task must stay in the local workspace.")
            throw CancellationError()
        }, codexCheck: {})
        let card = try await fixture.prepare(store)
        await store.selectWorkspaceCodex()
        #expect(store.workspaceUsesCodex)
        let draft = try await store.draftBriefTask(card.id, request: card.title)
        #expect(draft == "Open Calculator locally.")
        #expect(store.messages.isEmpty)
        #expect(executed.isEmpty)

        try store.startBriefTask(card.id, request: "Open Calculator, then report its launch.")
        await store.waitForConversationTaskToSettle()
        #expect(!store.isRunning)
        #expect(!store.workspaceUsesCodex)
        #expect(executed == ["open_app"])
        #expect(localRequests.contains("Open Calculator, then report its launch."))
        #expect(store.messages.last?.text.contains("Synthetic app-process receipt") == true)
    }

    @Test func changedSourcesAndUnsentWorkspaceDraftsBlockHandoff() async throws {
        let fixture = try BriefFixture()
        defer { fixture.remove() }
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            Issue.record("A blocked briefing task must not reach the model.")
            throw CancellationError()
        })
        let card = try await fixture.prepare(store)
        store.draft = "Keep my own draft"
        #expect(throws: RelayError.self) { try store.startBriefTask(card.id, request: card.title) }
        #expect(store.draft == "Keep my own draft")
        store.draft = ""
        try Data("TODO: A replacement action".utf8).write(to: fixture.source)
        #expect(throws: RelayError.self) { try store.startBriefTask(card.id, request: card.title) }
        #expect(store.suggestions.suggestions.isEmpty)
        #expect(store.messages.isEmpty)
    }

    @Test func windowDescriptionEntersOnlyTheReviewedLocalRun() async throws {
        let fixture = try BriefFixture()
        defer { fixture.remove() }
        let state = fixture.folder.appending(path: "state.json")
        let marker = "private window fixture marker"
        var inputs: [[ModelMessage]] = []
        let history = AssistantConversationHistory(stateURL: state)
        let store = AssistantStore(persistenceURL: state, complete: { messages, _, _ in
            inputs.append(messages)
            return ModelReply(content: "Fixture answer.", toolCalls: [])
        }, conversationHistory: history, multiAgent: true, codexComplete: { _, _ in
            Issue.record("The reviewed window description must stay local.")
            throw CancellationError()
        }, codexCheck: {})
        await store.selectWorkspaceCodex()
        try store.startWindowTask(request: "Summarize the selected window.", reviewedDescription: marker)
        await store.waitForConversationTaskToSettle()
        #expect(!store.isRunning)
        #expect(inputs.first?.first?.content.contains(marker) == true)
        #expect(inputs.first?.first?.content.contains("untrusted evidence") == true)
        #expect(store.messages.allSatisfy { !$0.text.contains(marker) })
        #expect(try !String(contentsOf: try #require(history.preferencesURL), encoding: .utf8).contains(marker))
        let core = try await history.journalForTesting(), scope = try await core.scope()
        for record in try await core.page(expectedScope: scope).records {
            #expect(!String(decoding: try JSONEncoder().encode(record.event), as: UTF8.self).contains(marker))
        }
        #expect(!FileManager.default.fileExists(atPath: state.path))

        store.draft = "Start a new request."
        store.send(useMultiAgent: false)
        await store.waitForConversationTaskToSettle()
        #expect(inputs.count == 2)
        #expect(inputs.last?.allSatisfy { !$0.content.contains(marker) } == true)
    }

    private struct BriefFixture {
        let folder: URL
        var source: URL { folder.appending(path: "brief.md") }

        init() throws {
            folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "relay-brief-handoff-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("TODO: Open Calculator".utf8).write(to: source)
        }

        @MainActor func prepare(_ store: AssistantStore) async throws -> Suggestion {
            store.grants = [ScopeGrant(path: folder.path)]
            await store.knowledge.index(grants: store.grants)
            store.setSuggestionsEnabled(true)
            store.suggestions.prepare(records: store.knowledge.records)
            return try #require(store.suggestions.suggestions.first)
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }
}
