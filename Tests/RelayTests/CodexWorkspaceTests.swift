import Foundation
import Testing
@testable import Relay

@MainActor
struct CodexWorkspaceTests {
    @Test func defaultFailedLoginAndNonWorkspaceEntryUseLocalPlanning() async {
        var localRequests = 0
        var hostedRequests = 0
        var loginSucceeds = false
        var hostedFails = false
        let store = AssistantStore(
            persistenceURL: nil,
            complete: { _, _, _ in
                localRequests += 1
                return ModelReply(content: "Local answer.", toolCalls: [])
            },
            codexComplete: { _, _ in
                hostedRequests += 1
                if hostedFails { throw RelayError.message("Fixture hosted request failed.") }
                return ModelReply(content: "Hosted answer.", toolCalls: [])
            },
            codexCheck: {
                if !loginSucceeds { throw RelayError.message("Fixture Codex login is unavailable.") }
            }
        )
        defer { if store.isRunning { store.stop() } }

        #expect(!store.workspaceUsesCodex)
        store.draft = "Use the default planner."
        store.send(useWorkspaceProvider: true)
        await settle(store)

        await store.selectWorkspaceCodex()
        #expect(!store.workspaceUsesCodex)
        #expect(store.codexStatus == "Fixture Codex login is unavailable.")
        store.draft = "Continue after the failed provider check."
        store.send(useWorkspaceProvider: true)
        await settle(store)

        loginSucceeds = true
        await store.selectWorkspaceCodex()
        #expect(store.workspaceUsesCodex)
        store.draft = "Use the separate local entry point."
        store.send()
        await settle(store)

        #expect(localRequests == 3)
        #expect(hostedRequests == 0)
        #expect(store.messages.last?.text.hasPrefix("Local answer.") == true)

        hostedFails = true
        store.draft = "Use the selected hosted planner."
        store.send(useWorkspaceProvider: true)
        await settle(store)
        #expect(hostedRequests == 1)
        #expect(localRequests == 3)
        #expect(store.phase == .failed)
        #expect(store.errorMessage == "Fixture hosted request failed.")
    }

    @Test func hostedWorkspaceExcludesPriorLocalMessagesGrantsAndMemory() async throws {
        let path = "/synthetic/RELAY_PRIVATE_GRANT.txt"
        let artifact = "/synthetic/RELAY_PRIVATE_ARTIFACT.txt"
        let read = ToolCall(id: "local-read", name: "read_file", arguments: ["path": .string(path)])
        let markers = ["RELAY_PRIOR_LOCAL_PROMPT", "RELAY_PRIVATE_GRANT", "RELAY_PRIVATE_MEMORY",
                       "RELAY_PRIOR_LOCAL_RESULT", "RELAY_PRIOR_LOCAL_EVIDENCE", "RELAY_PRIOR_LOCAL_REPLY", "RELAY_PRIVATE_ARTIFACT"]
        var localTurns = 0
        var received: [[ModelMessage]] = []
        var definitions: [ToolDefinition] = []
        let store = AssistantStore(
            persistenceURL: nil,
            complete: { _, _, _ in
                localTurns += 1
                return localTurns == 1
                    ? ModelReply(content: "", toolCalls: [read])
                    : ModelReply(content: "RELAY_PRIOR_LOCAL_REPLY", toolCalls: [])
            },
            execute: { call in
                #expect(call == read)
                return ToolResult(summary: "RELAY_PRIOR_LOCAL_RESULT", evidence: "RELAY_PRIOR_LOCAL_EVIDENCE",
                                  verified: true, artifactPath: artifact)
            },
            codexComplete: { input, tools in
                received.append(input)
                definitions = tools
                return ModelReply(content: "Hosted fixture answer.", toolCalls: [])
            },
            codexCheck: {}
        )
        defer { if store.isRunning { store.stop() } }
        store.grants = [ScopeGrant(path: path)]
        store.memories = [MemoryItem(text: "RELAY_PRIVATE_MEMORY")]
        store.draft = "Read the selected fixture. RELAY_PRIOR_LOCAL_PROMPT"
        store.send()
        await settle(store)
        #expect(localTurns == 2)
        #expect(store.messages.last?.text.contains("RELAY_PRIOR_LOCAL_RESULT") == true)
        #expect(store.messages.last?.artifacts == [artifact])

        await store.selectWorkspaceCodex()
        let current = "Answer this hosted fixture question."
        store.draft = current
        store.send(useWorkspaceProvider: true)
        await settle(store)

        #expect(received.count == 1)
        let input = try #require(received.first)
        #expect(input.map(\.role) == ["system", "user"])
        #expect(input.last?.content == current)
        #expect(input.allSatisfy { $0.toolCalls.isEmpty && $0.toolCallID == nil })
        let wire = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode(definitions), as: UTF8.self)
        #expect(markers.allSatisfy { !wire.contains($0) })
        #expect(!definitions.map(\.name).contains("read_file"))
        #expect(store.messages.last?.text.hasPrefix("Hosted fixture answer.") == true)
    }

    @Test(arguments: ["calculate", "open_app"])
    func hostedProposalsUseLocalExecutionAndBoundedFeedback(tool: String) async throws {
        let calculation = tool == "calculate"
        let action = ToolCall(id: "local-dispatch", name: tool,
                              arguments: calculation ? ["expression": .string("41+1")] : ["app": .string("Calculator")])
        let localDetail = "RELAY_PRIVATE_APP_RECEIPT"
        var received: [[ModelMessage]] = []
        var dispatched: [ToolCall] = []
        let store = AssistantStore(
            persistenceURL: nil,
            complete: { _, _, _ in
                Issue.record("The local model should not plan a hosted workspace request.")
                return ModelReply(content: "", toolCalls: [])
            },
            execute: { call in
                dispatched.append(call)
                return ToolResult(summary: calculation ? "Result: 42" : "Opened Calculator.",
                                  evidence: calculation ? "Verified local arithmetic." : localDetail, verified: true)
            },
            codexComplete: { input, _ in
                received.append(input)
                return received.count == 1
                    ? ModelReply(content: "", toolCalls: [action])
                    : ModelReply(content: "Finished the requested fixture action.", toolCalls: [])
            },
            codexCheck: {}
        )
        defer { if store.isRunning { store.stop() } }
        await store.selectWorkspaceCodex()
        store.draft = calculation ? "What is 41 plus 1?" : "Open Calculator."
        store.send(useWorkspaceProvider: true)
        await settle(store)

        #expect(dispatched == [action])
        #expect(received.count == 2)
        let result = try #require(received.last?.last)
        #expect(result.role == "tool")
        #expect(result.toolCallID == action.id)
        #expect(result.toolName == action.name)
        if calculation {
            #expect(result.content.contains("Result: 42"))
        } else {
            #expect(result.content.contains("Relay verified"))
            #expect(!result.content.contains(localDetail))
            #expect(store.messages.last?.text.contains(localDetail) == true)
        }
        #expect(store.activity.contains { $0.name == tool && $0.status == "verified" })
        #expect(store.pendingReview == nil)
    }

    @Test(arguments: ["observe_app", "read_browser_page"], [false, true])
    func hostedObservationRequiresReviewAndSendsExactlyTheApprovedExcerpt(tool: String, approve: Bool) async throws {
        let isBrowser = tool == "read_browser_page"
        let action = ToolCall(id: "share-preview", name: tool, arguments: isBrowser
            ? ["browser": .string("com.apple.Safari"), "url": .string("https://example.test/fixture")]
            : ["bundle_id": .string("com.apple.TextEdit")])
        let summary = "RELAY_REVIEWED_HEAD " + String(repeating: "🧪", count: 5_000) + " RELAY_UNAPPROVED_TAIL"
        var received: [[ModelMessage]] = []
        var dispatched: [ToolCall] = []
        let store = AssistantStore(
            persistenceURL: nil,
            execute: { call in
                dispatched.append(call)
                return ToolResult(summary: summary, evidence: "Synthetic local observation.", verified: true)
            },
            codexComplete: { input, _ in
                received.append(input)
                return received.count == 1
                    ? ModelReply(content: "", toolCalls: [action])
                    : ModelReply(content: "Reviewed fixture result received.", toolCalls: [])
            },
            codexCheck: {}
        )
        defer { if store.isRunning { store.stop() } }
        await store.selectWorkspaceCodex()
        store.draft = isBrowser ? "Read the currently selected synthetic page in Safari." : "Inspect the synthetic TextEdit window."
        store.send(useWorkspaceProvider: true)
        await waitUntil { store.pendingReview != nil || !store.isRunning }
        let review = try #require(store.pendingReview)

        #expect(dispatched == [action])
        #expect(received.count == 1)
        let firstRequest = try #require(received.first)
        #expect(firstRequest.allSatisfy { !$0.content.contains("RELAY_REVIEWED_HEAD") })
        #expect(review.sharesWithOpenAI)
        #expect(review.call == action)
        #expect(review.reason.contains("RELAY_REVIEWED_HEAD"))
        #expect(review.reason.utf8.count <= 16_000)
        #expect(!review.reason.contains("RELAY_UNAPPROVED_TAIL"))

        if approve { store.approveReview() }
        else { store.denyReview() }
        await settle(store)

        #expect(store.pendingReview == nil)
        #expect(dispatched == [action])
        if approve {
            #expect(received.count == 2)
            let result = try #require(received.last?.last)
            #expect(result.role == "tool")
            #expect(result.toolCallID == action.id)
            #expect(result.content == review.reason)
            #expect(store.activity.contains { $0.name == "ChatGPT data sharing" && $0.status == "approved" })
        } else {
            #expect(received.count == 1)
            #expect(store.phase == .needsInput)
            #expect(store.messages.last?.text.contains("kept the observation on this Mac") == true)
            #expect(store.activity.contains { $0.name == "ChatGPT data sharing" && $0.status == "declined" })
        }
    }

    @Test func hostedPlannerCannotDispatchAnUnadvertisedPrivateTool() async throws {
        let action = ToolCall(id: "blocked-private-tool", name: "read_file",
                              arguments: ["path": .string("/synthetic/private-fixture.txt")])
        var received: [[ModelMessage]] = []
        var dispatched: [ToolCall] = []
        let store = AssistantStore(
            persistenceURL: nil,
            execute: { call in
                dispatched.append(call)
                return ToolResult(summary: "Unexpected private read", evidence: "Fixture", verified: false)
            },
            codexComplete: { input, definitions in
                received.append(input)
                #expect(!definitions.map(\.name).contains(action.name))
                return received.count == 1
                    ? ModelReply(content: "", toolCalls: [action])
                    : ModelReply(content: "Switch to the local model to read the file.", toolCalls: [])
            },
            codexCheck: {}
        )
        defer { if store.isRunning { store.stop() } }
        await store.selectWorkspaceCodex()
        store.draft = "Read the synthetic fixture."
        store.send(useWorkspaceProvider: true)
        await settle(store)

        #expect(dispatched.isEmpty)
        #expect(received.count == 2)
        let result = try #require(received.last?.last)
        #expect(result.toolCallID == action.id)
        #expect(!result.content.contains("/synthetic/private-fixture.txt"))
        #expect(!result.content.contains("available with the local model only"))
        #expect(store.activity.contains { $0.name == action.name && $0.detail.contains("local model only") })
        #expect(store.phase == .needsInput)
        #expect(store.pendingReview == nil)
    }

    private func settle(_ store: AssistantStore) async {
        await waitUntil { !store.isRunning }
        #expect(!store.isRunning)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
