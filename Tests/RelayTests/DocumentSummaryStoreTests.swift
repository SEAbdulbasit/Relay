import AppKit
import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct DocumentSummaryStoreTests {
    @Test func currentNativeDocumentRoutingKeepsChatDraftAndHostedProviderUntouched() async throws {
        var preparations = 0, captures = 0, localGenerations = 0, hostedGenerations = 0
        let store = AssistantStore(persistenceURL: nil, complete: { messages, tools, _ in
            localGenerations += 1
            #expect(tools.isEmpty && messages.last?.content.contains("Synthetic original native source") == true)
            return ModelReply(content: "The original native source was summarized.", toolCalls: [])
        }, codexComplete: { _, _ in
            hostedGenerations += 1
            throw CancellationError()
        })
        store.draft = "Keep this unrelated composer draft."
        store.summaries.prepareNativeCapture = { _, active in
            preparations += 1
            #expect(active())
            return .init(kind: .nativeDocument, isSourceAuthorized: active, capture: {
                captures += 1
                return try DocumentSummarySource(kind: .nativeDocument, title: "Original synthetic native document",
                    application: "Synthetic editor", text: "Synthetic original native source",
                    coverage: "Only the original synthetic document was read.")
            })
        }
        let session = try store.startCurrentDocumentSummary(application: .current, presentPanel: false)
        #expect(preparations == 1 && captures == 0)
        await Self.until { session.phase == .ready }
        #expect(captures == 1 && localGenerations == 1 && hostedGenerations == 0)
        #expect(store.messages.isEmpty && store.draft == "Keep this unrelated composer draft.")
        #expect(session.source?.kind == .nativeDocument)
        store.stop()
        #expect(session.source == nil && session.resultText.isEmpty)
    }

    @Test func explicitConversationRoutingRefusesADocumentWithoutCapturingIt() throws {
        var captures = 0, generations = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            generations += 1
            throw CancellationError()
        })
        store.summaries.prepareNativeCapture = { _, active in
            .init(kind: .nativeDocument, isSourceAuthorized: active, capture: {
                captures += 1
                return try Self.source("This document must not become a chat capture.")
            })
        }
        #expect(throws: SummaryNativeDocumentCapture.Failure.unsupportedProfile) {
            try store.startCurrentDocumentSummary(application: .current, conversationOnly: true, presentPanel: false)
        }
        #expect(captures == 0 && generations == 0 && store.summaries.sessions.isEmpty)
    }

    @Test func sessionDeactivationBeforeNativeCapturePreventsAnyRead() async throws {
        var captures = 0, generations = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            generations += 1
            throw CancellationError()
        })
        store.summaries.prepareNativeCapture = { _, active in
            .init(kind: .nativeDocument, isSourceAuthorized: active, capture: {
                captures += 1
                return try Self.source("No inactive capture allowed.")
            })
        }
        let session = try store.startCurrentDocumentSummary(application: .current, presentPanel: false)
        store.setInteractiveSessionActive(false)
        await Self.until { !store.summaries.isBusy }
        #expect(captures == 0 && generations == 0 && session.source == nil && session.resultText.isEmpty)
        #expect(store.messages.isEmpty)
        store.stop()
    }

    @Test func summaryQueueUsesOnlyLocalToolFreeInferenceAndStopFencesLateResults() async throws {
        var releases: [CheckedContinuation<ModelReply, Never>] = []
        var capturedInputs: [[ModelMessage]] = []
        let store = AssistantStore(persistenceURL: nil, complete: { messages, tools, _ in
            #expect(tools.isEmpty)
            capturedInputs.append(messages)
            return await withCheckedContinuation { releases.append($0) }
        }, execute: { _ in
            Issue.record("A document summary must never execute a computer action.")
            throw CancellationError()
        })
        store.draft = "Preserve my workspace draft."
        var stops = 0
        store.onStopInput = { stops += 1 }
        let first = try store.summaries.start { try Self.source("First private fixture source") }
        await Self.until { releases.count == 1 }
        #expect(store.isRunning && store.canStartDocumentSummary)
        let second = try store.summaries.start { try Self.source("Second private fixture source") }
        await Self.until { second.phase == .queued }
        #expect(capturedInputs.count == 1)
        store.phase = .awaitingReview
        #expect(!store.canStartDocumentSummary)
        store.phase = .idle
        store.stop()
        #expect(stops == 1 && store.summaries.sessions.isEmpty)
        #expect(first.source == nil && second.source == nil)
        releases[0].resume(returning: ModelReply(content: "Late private output must disappear.", toolCalls: []))
        await Self.until { !store.isRunning }
        #expect(first.resultText.isEmpty && second.resultText.isEmpty)
        #expect(capturedInputs.count == 1)
        #expect(store.messages.isEmpty && store.draft == "Preserve my workspace draft.")
    }

    @Test func removingSourceGrantClearsCompletedReaderWithoutChangingChatOrDraft() async throws {
        let store = AssistantStore(persistenceURL: nil, complete: { _, tools, _ in
            #expect(tools.isEmpty)
            return ModelReply(content: "Synthetic private summary.", toolCalls: [])
        })
        let grant = ScopeGrant(path: "/tmp/relay-summary-synthetic-scope", writable: false)
        store.grants = [grant]
        store.draft = "Keep this unrelated draft."
        let session = try store.summaries.start(isSourceAuthorized: {
            store.grants.contains(where: { $0.id == grant.id })
        }) { try Self.source("Synthetic source cleared on revocation") }
        await Self.until { session.phase == .ready }
        #expect(!session.resultText.isEmpty && session.source != nil)
        store.removeGrant(grant.id)
        #expect(session.source == nil && session.resultText.isEmpty && session.phase == .stopped)
        #expect(store.messages.isEmpty && store.draft == "Keep this unrelated draft.")
        store.stop()
    }

    private static func source(_ text: String) throws -> DocumentSummarySource {
        try DocumentSummarySource(kind: .selection, title: "Owned synthetic source", application: "Synthetic fixture", text: text,
            coverage: "Complete synthetic fixture text.")
    }

    private static func until(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition(), "The synthetic summary operation did not settle.")
    }
}
