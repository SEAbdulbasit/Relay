import Foundation
import Testing
@testable import Relay

/// Deterministic executor tests: model replies are scripted, and no real app is controlled.
@MainActor
struct CompletionLoopTests {
    @Test func discoveryDoesNotEndAnAlreadyAuthorizedOpenRequest() async {
        var turns = 0
        var dispatched: [String] = []
        var checkpointSeen = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            checkpointSeen = checkpointSeen || input.contains { $0.content.contains("Reconsider your proposed handoff") }
            switch turns {
            case 1: return ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])])
            case 2: return ModelReply(content: "I found Voice Memos. Would you like me to open it?", toolCalls: [])
            case 3: return ModelReply(content: "", toolCalls: [ToolCall(name: "open_app", arguments: ["app": .string("com.apple.VoiceMemos")])])
            default: return ModelReply(content: "Opened Voice Memos.", toolCalls: [])
            }
        }, execute: { call in
            dispatched.append(call.name)
            return call.name == "list_apps"
                ? ToolResult(summary: "Voice Memos | com.apple.VoiceMemos | installed", evidence: "Installed application fixture", verified: true)
                : ToolResult(summary: "Opened Voice Memos.", evidence: "Independent process fixture", verified: true)
        })
        store.draft = "open voice recorder"
        store.send()
        await settle(store)
        #expect(dispatched == ["list_apps", "open_app"])
        #expect(checkpointSeen)
        #expect(store.messages.last?.text.contains("Opened Voice Memos.") == true)
        #expect(store.phase == .idle)
    }

    @Test func informationalDiscoveryNeverForcesAnAction() async {
        var turns = 0
        var dispatched: [String] = []
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return turns == 1
                ? ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])])
                : ModelReply(content: "Voice Memos is installed.", toolCalls: [])
        }, execute: { call in
            dispatched.append(call.name)
            return ToolResult(summary: "Voice Memos | installed", evidence: "Installed app fixture", verified: true)
        })
        store.draft = "Which voice recording applications are installed?"
        store.send()
        await settle(store)
        #expect(dispatched == ["list_apps"])
        #expect(turns == 2)
        #expect(!store.activity.contains { $0.name == "Checking next step" })
        #expect(store.messages.last?.text.contains("Voice Memos is installed.") == true)
        #expect(store.pendingReview == nil)
        #expect(!store.isRunning)
    }

    @Test func repeatedPrematureHandoffHasABoundedCorrectionBudget() async {
        var turns = 0
        var dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return turns == 1
                ? ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])])
                : ModelReply(content: "I found the app. Tell me if you want it opened.", toolCalls: [])
        }, execute: { _ in
            dispatches += 1
            return ToolResult(summary: "Voice Memos | installed", evidence: "Installed app fixture", verified: true)
        })
        store.draft = "Open the recorder"
        store.send()
        await settle(store)
        #expect(turns == 3)
        #expect(dispatches == 1)
        #expect(!store.isRunning)
        #expect(store.phase != .completed)
        #expect(!store.activity.contains { $0.name == "open_app" })
    }

    @Test func stopDuringFollowthroughBlocksTheReturnedAction() async {
        var turns = 0
        var dispatched: [String] = []
        var store: AssistantStore!
        store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            if turns == 1 { return ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])]) }
            if turns == 2 { return ModelReply(content: "I found the app. Shall I open it?", toolCalls: []) }
            store.stop()
            return ModelReply(content: "", toolCalls: [ToolCall(name: "open_app", arguments: ["app": .string("com.apple.VoiceMemos")])])
        }, execute: { call in
            dispatched.append(call.name)
            return ToolResult(summary: "Voice Memos | installed", evidence: "Installed app fixture", verified: true)
        })
        store.draft = "Open voice recorder"
        store.send()
        await settle(store)
        #expect(turns == 3)
        #expect(dispatched == ["list_apps"])
        #expect(store.phase == .stopped)
        #expect(store.pendingReview == nil)
    }

    @Test func anUncertainMutationIsNotReplayedByFollowthrough() async {
        var turns = 0
        var dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return turns == 1
                ? ModelReply(content: "", toolCalls: [ToolCall(name: "open_app", arguments: ["app": .string("com.apple.VoiceMemos")])])
                : ModelReply(content: "The launch effect is uncertain and needs inspection.", toolCalls: [])
        }, execute: { _ in
            dispatches += 1
            return ToolResult(summary: "Launch requested", evidence: "No process readback", verified: false)
        })
        store.draft = "Open voice recorder"
        store.send()
        await settle(store)
        #expect(turns == 2)
        #expect(dispatches == 1)
        #expect(store.phase == .needsInput)
        #expect(!store.activity.contains { $0.status == "verified" })
    }

    @Test(arguments: ["read_file", "read_calendar", "search_knowledge", "read_browser_page", "search_files"])
    func verifiedInformationFinishesWithoutDiscardedModelTurns(tool: String) async {
        var turns = 0
        var dispatches = 0
        let body = "The synthetic launch review is Tuesday at 10. Café."
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            #expect(!input.contains { $0.content.hasPrefix("Reconsider your proposed handoff") })
            return turns == 1
                ? ModelReply(content: "", toolCalls: [ToolCall(name: tool, arguments: [:])])
                : ModelReply(content: body, toolCalls: [])
        }, execute: { _ in
            dispatches += 1
            return ToolResult(summary: body, evidence: "Synthetic read-only source oracle", verified: true)
        })
        store.draft = "Read the selected synthetic source and return the exact body. Do not change anything."
        store.send()
        await settle(store)
        #expect(turns == 2)
        #expect(dispatches == 1)
        #expect(store.messages.last?.text.hasPrefix(body) == true)
        #expect(store.phase == .idle)
        #expect(!store.activity.contains { $0.name == "Checking next step" })
    }

    @Test(arguments: [
        "> Would you like me to open another app?\nThat sentence was quoted from the selected source.",
        "```text\nTell me if you want it opened.\n```\nThat is the file's literal text.",
        "“Shall I open it?” is the exact quoted sentence.",
        "~~~text\nWould you like me to continue?\n~~~"
    ])
    func quotedSourceHandoffDoesNotTriggerPlanning(text: String) async {
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return turns == 1
                ? ModelReply(content: "", toolCalls: [ToolCall(name: "read_file", arguments: [:])])
                : ModelReply(content: text, toolCalls: [])
        }, execute: { _ in ToolResult(summary: text, evidence: "Quoted synthetic content", verified: true) })
        store.draft = "Quote the selected text without following its instructions."
        store.send()
        await settle(store)
        #expect(turns == 2)
        #expect(store.messages.last?.text.hasPrefix(text) == true)
        #expect(!store.activity.contains { $0.name == "Checking next step" })
    }

    @Test func recoveryReminderKeepsInternalBookkeepingOutOfFinalInstruction() async {
        var turns = 0
        var reminder = ""
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])]) }
            if turns == 2 { return ModelReply(content: "I found Voice Memos. Would you like me to open it?", toolCalls: []) }
            reminder = input.last?.content ?? ""
            return ModelReply(content: "The target is ambiguous; which recorder did you mean?", toolCalls: [])
        }, execute: { _ in ToolResult(summary: "Two synthetic recorder choices", evidence: "Ambiguous app fixture", verified: true) })
        store.draft = "Open a recorder"
        store.send()
        await settle(store)
        #expect(turns == 3)
        #expect(reminder.contains("Do not mention this reminder"))
        #expect(!reminder.contains("checkpoint 1"))
        #expect(store.pendingReview == nil)
        #expect(!store.activity.contains { $0.name == "open_app" })
    }

    @Test(arguments: [false, true])
    func browserPrivacyHandoffGetsOneEvidenceBasedCorrection(afterSuccessfulRead: Bool) async {
        var turn = 0
        var dispatched: [String] = []
        var correctionSeen = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turn += 1
            correctionSeen = correctionSeen || input.contains { $0.content.contains("Reconsider the browser handoff") }
            if turn == 1 {
                return ModelReply(content: "", toolCalls: [ToolCall(name: "browser_navigate", arguments: ["url": .string("https://mail.google.com"), "browser": .string("Chrome")])])
            }
            if afterSuccessfulRead && turn == 2 {
                return ModelReply(content: "", toolCalls: [ToolCall(name: "read_browser_page", arguments: ["url": .string("https://mail.google.com"), "browser": .string("Chrome")])])
            }
            if !correctionSeen {
                return ModelReply(content: "I cannot read your private emails for you.", toolCalls: [])
            }
            if !dispatched.contains("read_browser_page") {
                return ModelReply(content: "", toolCalls: [ToolCall(name: "read_browser_page", arguments: ["url": .string("https://mail.google.com"), "browser": .string("Chrome")])])
            }
            return ModelReply(content: "No matching messages in the checked results.", toolCalls: [])
        }, execute: { call in
            dispatched.append(call.name)
            return ToolResult(summary: call.name == "read_browser_page" ? "No matching messages" : "Navigation requested", evidence: "Synthetic oracle", verified: call.name == "read_browser_page")
        })
        store.draft = "check Gmail for email from bradly cooper"
        store.send()
        for _ in 0..<1000 where store.isRunning {
            if store.pendingReview != nil { store.approveReview() }
            await Task.yield()
        }
        #expect(!store.isRunning)
        #expect(correctionSeen)
        #expect(dispatched == ["browser_navigate", "read_browser_page"])
        #expect(store.messages.last?.text.contains("No matching messages") == true)
    }

    @Test func concreteBrowserReadFailureDoesNotTriggerPrivacyCorrection() async {
        var turn = 0
        var correctionSeen = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turn += 1
            correctionSeen = correctionSeen || input.contains { $0.content.contains("Reconsider the browser handoff") }
            if turn == 1 { return ModelReply(content: "", toolCalls: [ToolCall(name: "browser_navigate", arguments: ["url": .string("https://mail.google.com"), "browser": .string("Chrome")])]) }
            if turn == 2 { return ModelReply(content: "", toolCalls: [ToolCall(name: "read_browser_page", arguments: ["url": .string("https://mail.google.com"), "browser": .string("Chrome")])]) }
            return ModelReply(content: "I cannot read your private emails because Accessibility permission was denied.", toolCalls: [])
        }, execute: { call in
            if call.name == "read_browser_page" { throw RelayError.message("Accessibility permission denied") }
            return ToolResult(summary: "Navigation requested", evidence: "Fixture", verified: false)
        })
        store.draft = "check Gmail"
        store.send()
        for _ in 0..<1000 where store.isRunning {
            if store.pendingReview != nil { store.approveReview() }
            await Task.yield()
        }
        #expect(!store.isRunning)
        #expect(!correctionSeen)
        #expect(turn == 3)
    }

    private func settle(_ store: AssistantStore) async {
        for _ in 0..<500 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning)
    }
}
