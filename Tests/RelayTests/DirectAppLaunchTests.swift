import Foundation
import Testing
@testable import Relay

@MainActor
struct DirectAppLaunchTests {
    @Test func opensOneKnownAppAndRecordsItsVerifiedOutcomeWithoutAModel() async throws {
        var calls: [ToolCall] = []
        let store = AssistantStore(persistenceURL: nil, execute: { call in
            calls.append(call)
            return ToolResult(summary: "Opened Calculator.", evidence: "Fixture verified the process.", verified: true)
        })
        #expect(!store.actionsReady)
        #expect(store.canRunWithoutModel("open Calculator."))

        store.draft = "open Calculator."
        store.send(useWorkspaceProvider: true)
        await store.waitForConversationTaskToSettle()

        #expect(calls.count == 1)
        #expect(calls.first?.name == "open_app")
        #expect(calls.first?.arguments == ["app": .string("com.apple.calculator")])
        #expect(store.messages.last?.text.contains("Fixture verified the process.") == true)
        #expect(store.activity.contains { $0.name == "open_app" && $0.status == "verified" })
        #expect(!store.actionsReady)
    }

    @Test func compoundOrAmbiguousRequestsAndOtherProvidersDoNotUseTheShortcut() async {
        let store = AssistantStore(persistenceURL: nil, codexCheck: {})
        for request in ["Open Calculator and add 1 + 2", "Open Calendar\nOpen Notes", "Open the app", "Open System Settings", "Open https://example.org", "What is the time?", "What is 12 + 30 and write a file"] {
            #expect(!store.canRunWithoutModel(request))
        }
        await store.selectWorkspaceCodex()
        #expect(!store.canRunWithoutModel("Open Calculator"))
    }

    @Test func exactArithmeticUsesTheLocalCalculatorAndItsVerifiedResult() async throws {
        let store = AssistantStore(persistenceURL: nil)
        store.draft = "What is 48 × 37?"
        #expect(store.canRunWithoutModel(store.draft))
        store.send(useWorkspaceProvider: true)
        await store.waitForConversationTaskToSettle()
        #expect(store.messages.last?.text.contains("1776") == true)
        #expect(store.activity.contains { $0.name == "calculate" && $0.status == "verified" })
        #expect(!store.actionsReady)
    }
}
