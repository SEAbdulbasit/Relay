import AppKit
import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct QuickTextActionRoutingTests {
    @Test func exactTypedActionUsesDedicatedLocalRouteWithoutChatOrHostedRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.store.selectWorkspaceCodex()
        fixture.controller.promptText = "Relay, could you summarize this page for me?"
        fixture.controller.submit(store: fixture.store)
        #expect(fixture.actions == [.init(action: .summarize, target: .page)])
        #expect(fixture.controller.promptText.isEmpty && fixture.store.messages.isEmpty)
        #expect(fixture.store.draft == fixture.originalDraft)
        #expect(fixture.localCalls == 0 && fixture.hostedCalls == 0)
    }

    @Test func failedOrUnavailableDedicatedActionPreservesBothDraftsAndNeverFallsThrough() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.failAction = true
        fixture.controller.promptText = "Proofread this selected text."
        fixture.controller.submit(store: fixture.store)
        #expect(fixture.actions.count == 1)
        #expect(fixture.controller.promptText == "Proofread this selected text.")
        #expect(fixture.controller.errorMessage == "Synthetic source changed.")
        fixture.store.actionsReady = false
        fixture.controller.submit(store: fixture.store)
        #expect(fixture.actions.count == 1)
        #expect(fixture.controller.errorMessage?.contains("Load a local model") == true)
        #expect(fixture.store.draft == fixture.originalDraft && fixture.store.messages.isEmpty)
        #expect(fixture.localCalls == 0 && fixture.hostedCalls == 0)
    }

    @Test func compoundRequestRemainsOrdinaryConversationAndDoesNotCaptureASource() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let request = "Summarize this page and explain the next steps."
        fixture.controller.promptText = request
        fixture.controller.submit(store: fixture.store)
        for _ in 0..<2_000 where fixture.store.isRunning { await Task.yield() }
        #expect(!fixture.store.isRunning)
        #expect(fixture.actions.isEmpty && fixture.localCalls == 1 && fixture.hostedCalls == 0)
        #expect(fixture.store.messages.contains { $0.role == "user" && $0.text == request })
        #expect(fixture.store.draft == fixture.originalDraft)
    }

    @Test func explicitFinalVoiceSendUsesTheSameDedicatedRouteOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try #require(fixture.controller.beginDictation(focusPanel: false, expandPanel: false))
        for _ in 0..<2_000 where fixture.backend.callback == nil { await Task.yield() }
        let callback = try #require(fixture.backend.callback)
        callback(.final("Please proofread this text."))
        fixture.controller.sendTranscript()
        fixture.controller.sendTranscript()
        #expect(fixture.actions == [.init(action: .proofread, target: .selection)])
        #expect(!fixture.controller.ownsDictation && fixture.store.voice.transcript.isEmpty)
        #expect(fixture.store.messages.isEmpty && fixture.store.draft == fixture.originalDraft)
        #expect(fixture.localCalls == 0 && fixture.hostedCalls == 0)
    }

    @Test func optedInFinalHoldReleaseOpensOnlyTheDedicatedReaderAndPreservesDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.setHoldForVoiceEnabled(true)
        fixture.controller.setReleaseVoiceToSend(true)
        try #require(fixture.controller.beginNotchVoiceHold())
        for _ in 0..<2_000 where fixture.backend.callback == nil { await Task.yield() }
        let callback = try #require(fixture.backend.callback)
        callback(.final("Summarize this page."))
        fixture.controller.endNotchVoiceHold(cancelled: false)
        for _ in 0..<2_000 where fixture.actions.isEmpty { await Task.yield() }
        #expect(fixture.actions == [.init(action: .summarize, target: .page)])
        #expect(!fixture.controller.expanded && !fixture.controller.ownsDictation)
        #expect(fixture.controller.promptText.isEmpty && fixture.store.messages.isEmpty)
        #expect(fixture.store.draft == fixture.originalDraft && fixture.store.voice.transcript.isEmpty)
        #expect(fixture.localCalls == 0 && fixture.hostedCalls == 0)
    }

    @Test func staleControllerOwnerCannotDispatchIntoAPreviousStore() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let current = AssistantStore(persistenceURL: nil)
        fixture.controller.connect(store: current, available: true, openWorkspace: {})
        fixture.controller.promptText = "Summarize this page."
        fixture.controller.submit(store: fixture.store)
        #expect(fixture.actions.isEmpty && fixture.store.messages.isEmpty && current.messages.isEmpty)
        #expect(fixture.controller.promptText == "Summarize this page.")
    }

    @Test func inactiveSessionClearsReadersAndBlocksInputUntilEveryInterruptionEnds() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let reader = try fixture.store.summaries.start {
            try DocumentSummarySource(kind: .selection, title: "Synthetic source", application: "Fixture",
                text: "Private fixture text.", coverage: "Complete synthetic source.")
        }
        for _ in 0..<2_000 where reader.phase != .ready { await Task.yield() }
        try #require(reader.phase == .ready)
        fixture.controller.promptText = "Summarize this page."
        fixture.controller.receiveSessionNotification(NSWorkspace.sessionDidResignActiveNotification)
        #expect(!fixture.store.interactiveSessionActive && fixture.store.summaries.sessions.isEmpty)
        #expect(reader.source == nil && reader.resultText.isEmpty)
        #expect(!fixture.store.canStartDocumentSummary && !fixture.controller.beginDictation())
        fixture.controller.submit(store: fixture.store)
        #expect(fixture.actions.isEmpty && fixture.backend.callback == nil)
        fixture.controller.receiveSessionNotification(NSWorkspace.willSleepNotification)
        fixture.controller.receiveSessionNotification(NSWorkspace.screensDidSleepNotification)
        fixture.controller.receiveSessionNotification(NSWorkspace.sessionDidBecomeActiveNotification)
        fixture.controller.receiveSessionNotification(NSWorkspace.didWakeNotification)
        #expect(!fixture.store.interactiveSessionActive)
        fixture.controller.receiveSessionNotification(NSWorkspace.screensDidWakeNotification)
        #expect(fixture.store.interactiveSessionActive && fixture.actions.isEmpty)
        #expect(fixture.controller.promptText == "Summarize this page." && fixture.store.draft == fixture.originalDraft)
        fixture.controller.submit(store: fixture.store)
        #expect(fixture.actions == [.init(action: .summarize, target: .page)])
        #expect(fixture.store.messages.isEmpty && fixture.hostedCalls == 0)
    }

    @MainActor private final class Fixture {
        let suite = "relay.quick-route." + UUID().uuidString
        let preferences: UserDefaults
        let backend = RoutingVoiceBackend()
        let store: AssistantStore
        let controller: NotchOverlayController
        let originalDraft = "Preserve my independent workspace draft."
        var actions: [QuickTextActionIntent] = []
        var localCalls: Int { counts.local }
        var hostedCalls: Int { counts.hosted }
        var failAction = false

        init() throws {
            preferences = try #require(UserDefaults(suiteName: suite))
            preferences.set(false, forKey: "relay.sidekick.showInNotch")
            preferences.set(false, forKey: "relay.sidekick.holdForVoice")
            let calls = Counts()
            store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
                calls.local += 1
                return ModelReply(content: "Synthetic ordinary conversation.", toolCalls: [])
            }, voiceInput: LocalVoiceInput(backend: backend, sleepNotificationCenter: NotificationCenter()), codexComplete: { _, _ in
                calls.hosted += 1
                return ModelReply(content: "Unexpected hosted request.", toolCalls: [])
            }, codexCheck: {})
            controller = NotchOverlayController(preferences: preferences, presentsPanels: false,
                quickTextAction: { intent in _ = try calls.perform?(intent) }, frontmostPID: { 42 })
            self.counts = calls
            calls.perform = { [weak self] intent in
                guard let self else { throw CancellationError() }
                self.actions.append(intent)
                if self.failAction { throw RelayError.message("Synthetic source changed.") }
            }
            store.actionsReady = true
            store.draft = originalDraft
            controller.connect(store: store, available: true, openWorkspace: {})
        }
        private let counts: Counts
        func close() {
            store.stop()
            controller.connect(store: store, available: false, openWorkspace: {})
            preferences.removePersistentDomain(forName: suite)
        }
        @MainActor private final class Counts {
            var local = 0, hosted = 0
            var perform: (@MainActor (QuickTextActionIntent) throws -> Void)?
        }
    }
}

@MainActor private final class RoutingVoiceBackend: LocalVoiceBackend {
    var callback: (@MainActor @Sendable (LocalSpeechEvent) -> Void)?
    func capability(localeIdentifier: String) -> LocalVoiceCapability { .init(localeSupported: true, onDeviceSupported: true) }
    func requestPermissions() async throws {}
    func begin(localeIdentifier: String, requiresOnDeviceRecognition: Bool, onEvent: @escaping @MainActor @Sendable (LocalSpeechEvent) -> Void) throws { callback = onEvent }
    func stop() { callback = nil }
}
