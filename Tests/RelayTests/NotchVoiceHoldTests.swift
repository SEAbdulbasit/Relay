import AppKit
import Foundation
import Testing
@testable import Relay

/// Synthetic controller/backend tests: no window, microphone, OS permission
/// request, real preference mutation, hosted inference or desktop action.
@Suite(.serialized)
@MainActor
struct NotchVoiceHoldTests {
    @Test func releaseStopsMicrophoneAndSubmitsExactlyOneFinalTranscriptPreservingWorkspaceDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.beginRecording()
        fixture.backend.emit(.partial("Partial words must never submit."))
        #expect(fixture.calls.local == 0 && fixture.userMessages.isEmpty)
        fixture.backend.finalOnFinish = "Final café 🌍 task."
        fixture.controller.endNotchVoiceHold(cancelled: false)
        #expect(!fixture.backend.running, "Pointer release must stop microphone input before returning.")
        try await fixture.wait { fixture.calls.local == 1 && !fixture.store.isRunning }
        #expect(fixture.userMessages.map(\.text) == ["Final café 🌍 task."])
        #expect(fixture.store.draft.utf16.elementsEqual(fixture.originalDraft.utf16))
        #expect(fixture.controller.promptText.isEmpty)
        #expect(!fixture.controller.ownsDictation && fixture.voice.transcript.isEmpty)
        fixture.controller.endNotchVoiceHold(cancelled: false)
        fixture.backend.historicalCallbacks.first?(.final("Late repeated callback."))
        await fixture.yieldJobs()
        #expect(fixture.calls.local == 1 && fixture.userMessages.count == 1)
        #expect(fixture.calls.hosted == 0)
    }

    @Test(arguments: ["opt-off", "codex", "origin", "origin-unknown", "prompt-before", "prompt-during", "edit"])
    func unsafeReleaseContextRetainsReviewAndNeverAutoSubmits(reason: String) async throws {
        let fixture = try Fixture(releaseEnabled: reason != "opt-off")
        defer { fixture.close() }
        if reason == "codex" { await fixture.store.selectWorkspaceCodex() }
        if reason == "origin-unknown" { fixture.origin.pid = nil }
        if reason == "prompt-before" { fixture.controller.promptText = "Keep the existing notch prompt." }
        try await fixture.beginRecording()
        fixture.backend.emit(.partial("Review this transcript."))
        fixture.backend.finalOnFinish = "Final review-only transcript."
        if reason == "origin" { fixture.origin.pid = 8_888 }
        if reason == "prompt-during" { fixture.controller.promptText = "New notch prompt while speaking." }
        if reason == "edit" { fixture.controller.editTranscript("User-edited transcript.") }
        fixture.controller.endNotchVoiceHold(cancelled: false)
        try await fixture.wait { !fixture.voice.isBusy }
        await fixture.yieldJobs()
        #expect(fixture.calls.local == 0 && fixture.calls.hosted == 0 && fixture.userMessages.isEmpty)
        #expect(fixture.store.draft.utf16.elementsEqual(fixture.originalDraft.utf16))
        #expect(fixture.controller.ownsDictation)
        #expect(fixture.controller.transcriptText == (reason == "edit" ? "User-edited transcript." : "Final review-only transcript."))
        if reason == "prompt-before" { #expect(fixture.controller.promptText == "Keep the existing notch prompt.") }
        if reason == "prompt-during" { #expect(fixture.controller.promptText == "New notch prompt while speaking.") }
    }

    @Test func editedTranscriptRequiresExplicitSendAndUsesTheEditedTextOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.beginRecording()
        fixture.backend.emit(.partial("Recognizer draft."))
        fixture.controller.editTranscript("Reviewed correction — شكرًا 🌍.")
        fixture.controller.endNotchVoiceHold(cancelled: false)
        await fixture.yieldJobs()
        #expect(fixture.calls.local == 0 && fixture.userMessages.isEmpty)
        fixture.controller.sendTranscript()
        try await fixture.wait { !fixture.store.isRunning && fixture.calls.local == 1 }
        #expect(fixture.userMessages.map(\.text) == ["Reviewed correction — شكرًا 🌍."])
        #expect(fixture.store.draft == fixture.originalDraft)
        fixture.controller.sendTranscript()
        await fixture.yieldJobs()
        #expect(fixture.calls.local == 1)
    }

    @Test(arguments: ["gesture", "owned-stop", "store-stop", "hide", "discard", "sleep"])
    func cancellationWhileFinalizingBlocksLateFinalAndNeverAutoSubmits(method: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.beginRecording()
        fixture.backend.emit(.partial("Words captured before cancellation."))
        let late = try #require(fixture.backend.callback)
        fixture.controller.endNotchVoiceHold(cancelled: false)
        try await fixture.wait { fixture.backend.finishes == 1 }
        switch method {
        case "gesture": fixture.controller.endNotchVoiceHold(cancelled: true)
        case "owned-stop": fixture.controller.cancelOwnedDictation(for: fixture.store)
        case "store-stop": fixture.store.stop()
        case "hide": fixture.controller.hideFloatingNotchPanel()
        case "sleep": fixture.controller.prepareForSleep()
        default: fixture.controller.discardDictation()
        }
        #expect(!fixture.backend.running)
        late(.final("Late result must not create a task."))
        await fixture.yieldJobs()
        #expect(fixture.calls.local == 0 && fixture.calls.hosted == 0 && fixture.userMessages.isEmpty)
        #expect(fixture.store.draft == fixture.originalDraft)
        if method == "owned-stop" || method == "store-stop" || method == "discard" {
            #expect(fixture.voice.transcript.isEmpty)
        }
    }

    @Test func releaseDuringPermissionWaitCannotStartAfterLateSyntheticConsent() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.backend.holdPermissions = true
        try #require(fixture.controller.beginNotchVoiceHold())
        try await fixture.wait { fixture.backend.permissionRequests == 1 }
        #expect(fixture.voice.phase == .requestingPermission)
        fixture.controller.endNotchVoiceHold(cancelled: false)
        await fixture.yieldJobs()
        fixture.backend.completePermissions()
        await fixture.yieldJobs()
        #expect(fixture.backend.starts == 0 && !fixture.backend.running)
        #expect(fixture.userMessages.isEmpty && fixture.calls.local == 0 && fixture.calls.hosted == 0)
        #expect(fixture.store.draft == fixture.originalDraft)
    }

    @Test func finalTimeoutKeepsOnlyPartialTextForManualReview() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.beginRecording()
        fixture.backend.emit(.partial("Review these bounded partial words."))
        fixture.controller.endNotchVoiceHold(cancelled: false)
        try await fixture.wait(timeout: .seconds(3)) { !fixture.voice.isBusy }
        await fixture.yieldJobs()
        #expect(!fixture.backend.running && !fixture.voice.transcriptIsFinal)
        #expect(fixture.controller.transcriptText == "Review these bounded partial words.")
        #expect(fixture.userMessages.isEmpty && fixture.calls.local == 0)
        #expect(fixture.store.draft == fixture.originalDraft)
    }

    @Test func finalFlushTurnsMicrophoneOffWhileRecognizerStillFinishes() async throws {
        let backend = HoldVoiceBackend()
        let voice = LocalVoiceInput(backend: backend, sleepNotificationCenter: NotificationCenter())
        await voice.start()
        backend.emit(.partial("A partial."))
        let pending = Task { await voice.finishCapture(timeout: .milliseconds(200)) }
        for _ in 0..<1_000 where backend.finishes == 0 { await Task.yield() }
        try #require(backend.finishes == 1)
        #expect(!backend.running && voice.isBusy && !voice.transcriptIsFinal)
        backend.emit(.final("Final Café 🌍."))
        #expect(await pending.value)
        #expect(voice.transcriptIsFinal && voice.transcript == "Final Café 🌍.")
        #expect(!voice.isBusy && !backend.running)
        voice.cancel()
    }

    @Test func previousReleaseCannotSubmitOrStopANewerCaptureFinal() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.beginRecording()
        let oldID = try #require(fixture.voice.captureID)
        fixture.backend.emit(.partial("Old capture."))
        fixture.controller.endNotchVoiceHold(cancelled: false)
        try await fixture.wait { fixture.backend.finishes == 1 }
        fixture.voice.cancel()
        await fixture.voice.start()
        let newID = try #require(fixture.voice.captureID)
        #expect(newID != oldID)
        fixture.backend.emit(.final("A newer final must remain unsent."))
        await fixture.yieldJobs()
        #expect(fixture.voice.captureID == newID && fixture.voice.transcriptIsFinal)
        #expect(fixture.voice.transcript == "A newer final must remain unsent.")
        #expect(fixture.userMessages.isEmpty && fixture.calls.local == 0 && fixture.calls.hosted == 0)
    }

    @Test func canceledFinalWaitCannotTearDownANewerRecording() async throws {
        let backend = HoldVoiceBackend()
        let voice = LocalVoiceInput(backend: backend, sleepNotificationCenter: NotificationCenter())
        await voice.start()
        let pending = Task { await voice.finishCapture(timeout: .seconds(1)) }
        for _ in 0..<1_000 where backend.finishes == 0 { await Task.yield() }
        try #require(backend.finishes == 1)
        pending.cancel()
        voice.cancel()
        await voice.start()
        let newer = try #require(voice.captureID)
        #expect(await pending.value == false)
        #expect(voice.captureID == newer && voice.isRecording && backend.running)
        voice.cancel()
    }

    @Test func holdOptInAndOwnerStopAreIsolatedAndCannotAffectAnotherStore() async throws {
        let disabled = try Fixture(holdEnabled: false)
        defer { disabled.close() }
        #expect(!disabled.controller.beginNotchVoiceHold())
        #expect(disabled.backend.permissionRequests == 0 && disabled.backend.starts == 0)
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.beginRecording()
        let unrelated = AssistantStore(persistenceURL: nil)
        fixture.controller.cancelOwnedDictation(for: unrelated)
        #expect(fixture.voice.isRecording && fixture.backend.running)
        // This is the controller's same owned-cancel path used for Stop/sleep,
        // exercised directly instead of posting a real workspace sleep event.
        fixture.controller.cancelOwnedDictation(for: fixture.store)
        #expect(!fixture.backend.running && !fixture.voice.isBusy && fixture.voice.transcript.isEmpty)
    }

    @Test(arguments: [true, false])
    func reconnectOrDisableStopsPreviousOwnedCaptureWithoutTouchingAnotherStoresVoice(reconnect: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.beginRecording()
        fixture.backend.emit(.partial("Old store's unfinished hold."))
        let oldFinal = try #require(fixture.backend.callback)
        let newBackend = HoldVoiceBackend()
        let newVoice = LocalVoiceInput(backend: newBackend, sleepNotificationCenter: NotificationCenter())
        let newStore = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            Issue.record("Reconnecting a voice owner must never start a task in the new store.")
            return .init(content: "Unexpected new-store task", toolCalls: [])
        }, voiceInput: newVoice)
        await newVoice.start()
        newBackend.emit(.partial("Independent capture in the new store."))
        let newID = try #require(newVoice.captureID)
        defer {
            newVoice.cancel()
            fixture.controller.connect(store: newStore, available: false, openWorkspace: {})
        }
        if reconnect {
            fixture.controller.connect(store: newStore, available: true, openWorkspace: {})
        } else {
            fixture.controller.connect(store: fixture.store, available: false, openWorkspace: {})
        }
        #expect(!fixture.backend.running && !fixture.voice.isBusy && fixture.voice.transcript.isEmpty)
        #expect(!fixture.controller.ownsDictation)
        #expect(newBackend.running && newVoice.isRecording && newVoice.captureID == newID)
        #expect(newVoice.transcript == "Independent capture in the new store.")
        // A stale physical release and recognizer result belong to the old owner.
        fixture.controller.endNotchVoiceHold(cancelled: false)
        oldFinal(.final("Old final must never be submitted in either store."))
        await fixture.yieldJobs()
        #expect(fixture.userMessages.isEmpty && newStore.messages.isEmpty && fixture.calls.local == 0 && fixture.calls.hosted == 0)
        #expect(newBackend.running && newVoice.isRecording && newVoice.captureID == newID)
        #expect(fixture.store.draft == fixture.originalDraft)
    }

    @MainActor private final class Calls { var local = 0; var hosted = 0 }
    @MainActor private final class Origin { var pid: Int32? = 4_242 }

    @MainActor private final class Fixture {
        let suite: String
        let preferences: UserDefaults
        let backend: HoldVoiceBackend
        let voice: LocalVoiceInput
        let store: AssistantStore
        let controller: NotchOverlayController
        let calls: Calls
        let origin: Origin
        let originalDraft = "Keep the independent workspace draft — e\u{301} 🌍."
        var userMessages: [ChatMessage] { store.messages.filter { $0.role == "user" } }

        init(releaseEnabled: Bool = true, holdEnabled: Bool = true) throws {
            let suite = "relay.notch-voice-test." + UUID().uuidString
            self.suite = suite
            let preferences = try #require(UserDefaults(suiteName: suite))
            self.preferences = preferences
            preferences.set(holdEnabled, forKey: "relay.sidekick.holdForVoice")
            preferences.set(releaseEnabled, forKey: "relay.sidekick.releaseVoiceToSend")
            preferences.set(false, forKey: "relay.sidekick.showInNotch")
            preferences.set("", forKey: SidekickTaskContext.instructionsPreference)
            let backend = HoldVoiceBackend()
            self.backend = backend
            let voice = LocalVoiceInput(backend: backend, sleepNotificationCenter: NotificationCenter())
            self.voice = voice
            let calls = Calls()
            self.calls = calls
            let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
                calls.local += 1
                return .init(content: "Synthetic voice task completed.", toolCalls: [])
            }, voiceInput: voice, codexComplete: { _, _ in
                calls.hosted += 1
                return .init(content: "Unexpected hosted voice task.", toolCalls: [])
            }, codexCheck: {})
            self.store = store
            let origin = Origin()
            self.origin = origin
            let controller = NotchOverlayController(preferences: preferences, presentsPanels: false, frontmostPID: { origin.pid })
            self.controller = controller
            store.actionsReady = true
            store.draft = originalDraft
            controller.connect(store: store, available: true, openWorkspace: { Issue.record("A synthetic voice test must not open the real workspace.") })
        }

        func beginRecording() async throws {
            try #require(controller.beginNotchVoiceHold(), "Explicit fake hold opt-in must work without OS monitors or permission grants.")
            try await wait { voice.isRecording }
            #expect(backend.running && backend.requiresOnDevice == true)
        }
        func wait(timeout: Duration = .seconds(2), until predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate(), "Synthetic voice work must settle within its bounded wait.")
        }
        func yieldJobs() async { for _ in 0..<100 { await Task.yield() } }
        func close() {
            backend.completePermissions()
            controller.cancelOwnedDictation(for: store)
            controller.connect(store: store, available: false, openWorkspace: {})
            store.focusedDraft.setHoldForVoiceEnabled(false)
            store.stop()
            preferences.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
private final class HoldVoiceBackend: LocalVoiceBackend {
    var permissionRequests = 0
    var starts = 0
    var finishes = 0
    var stops = 0
    var running = false
    var requiresOnDevice: Bool?
    var holdPermissions = false
    var finalOnFinish: String?
    var callback: (@MainActor @Sendable (LocalSpeechEvent) -> Void)?
    var historicalCallbacks: [@MainActor @Sendable (LocalSpeechEvent) -> Void] = []
    private var permissionContinuation: CheckedContinuation<Void, Never>?

    func capability(localeIdentifier: String) -> LocalVoiceCapability { .init(localeSupported: true, onDeviceSupported: true) }
    func requestPermissions() async throws {
        permissionRequests += 1
        if holdPermissions { await withCheckedContinuation { permissionContinuation = $0 } }
        try Task.checkCancellation()
    }
    func completePermissions() { permissionContinuation?.resume(); permissionContinuation = nil }
    func begin(localeIdentifier: String, requiresOnDeviceRecognition: Bool,
               onEvent: @escaping @MainActor @Sendable (LocalSpeechEvent) -> Void) throws {
        starts += 1
        running = true
        requiresOnDevice = requiresOnDeviceRecognition
        callback = onEvent
        historicalCallbacks.append(onEvent)
    }
    func emit(_ event: LocalSpeechEvent) { callback?(event) }
    func finish() {
        finishes += 1
        running = false
        if let finalOnFinish { callback?(.final(finalOnFinish)) }
    }
    func stop() { stops += 1; running = false; callback = nil }
}
