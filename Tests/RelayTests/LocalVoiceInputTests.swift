import Foundation
import AppKit
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct LocalVoiceInputTests {
    @Test func legacyAuthorizationCallbackCanResumeFromBackgroundQueueWithoutActorAssertion() async {
        let result = await LocalVoiceAuthorizationBridge.status { @Sendable reply in
            DispatchQueue.global(qos: .userInitiated).async {
                // Match Speech/TCC callback delivery, not the MainActor fake backend.
                reply(Thread.isMainThread ? -1 : 3)
            }
        }
        #expect(result == 3)
        // The caller resumes on its original actor after the nonisolated bridge returns.
        MainActor.assertIsolated()
    }

    @Test func initializationDoesNotProbeAuthorizeRecordOrSendAnything() {
        let backend = VoiceBackendFixture()
        let voice = LocalVoiceInput(backend: backend)
        #expect(voice.phase == .idle)
        #expect(!voice.isBusy)
        #expect(voice.transcript.isEmpty)
        #expect(backend.capabilityChecks == 0)
        #expect(backend.permissionRequests == 0)
        #expect(backend.starts == 0)
        #expect(!backend.running)
        #expect(voice.maximumDuration == 30)
        #expect(voice.lastCaptureElapsedSeconds == nil)
    }

    @Test func recordingLimitAcceptsOnlyFiniteBoundsAndIsNotPersistedAcrossControllers() {
        let voice = LocalVoiceInput(backend: VoiceBackendFixture())
        for invalid in [0.0, -1, 60.01, .infinity, -.infinity, .nan] {
            #expect(!voice.setMaximumDuration(invalid))
            #expect(voice.maximumDuration == 30)
        }
        for valid in [1.0, 10, 30, 60] {
            #expect(voice.setMaximumDuration(valid))
            #expect(voice.maximumDuration == valid)
        }
        #expect(LocalVoiceInput(backend: VoiceBackendFixture()).maximumDuration == 30)
    }

    @Test func recordingLimitCannotChangeDuringPermissionWaitOrCapture() async {
        let backend = VoiceBackendFixture()
        backend.holdPermissions = true
        let voice = LocalVoiceInput(backend: backend)
        #expect(voice.setMaximumDuration(10))
        let pending = Task { await voice.start() }
        for _ in 0..<100 where backend.permissionRequests == 0 { await Task.yield() }
        #expect(!voice.setMaximumDuration(60))
        #expect(voice.maximumDuration == 10)
        backend.completePermissions()
        await pending.value
        #expect(voice.isRecording)
        #expect(!voice.setMaximumDuration(30))
        #expect(voice.maximumDuration == 10)
        voice.stop()
        #expect(voice.setMaximumDuration(30))
        #expect(voice.lastCaptureElapsedSeconds != nil)
    }

    @Test func permissionWaitDoesNotConsumeCaptureDeadlineOrElapsedMetric() async throws {
        let backend = VoiceBackendFixture()
        backend.holdPermissions = true
        let voice = LocalVoiceInput(maximumDuration: 1, backend: backend)
        let pending = Task { await voice.start() }
        for _ in 0..<100 where backend.permissionRequests == 0 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(voice.phase == .requestingPermission)
        #expect(voice.lastCaptureElapsedSeconds == nil)
        backend.completePermissions()
        await pending.value
        #expect(voice.isRecording)
        voice.stop()
        #expect(try #require(voice.lastCaptureElapsedSeconds) < 1)
    }

    @Test func slowNativeStartCannotAddAnotherFullDurationBeforeStopping() async {
        let backend = VoiceBackendFixture()
        backend.beginDelay = 1.05
        let voice = LocalVoiceInput(maximumDuration: 1, backend: backend)
        await voice.start()
        // Simulated synchronous native startup already used the entire budget. No yield.
        #expect(voice.phase == .stopped)
        #expect(!backend.running)
        #expect(voice.status.contains("duration limit"))
        #expect((voice.lastCaptureElapsedSeconds ?? 0) >= 1)
    }

    @Test func unsupportedLocaleAndDeviceRefuseBeforeRequestingPermissions() async {
        let unsupported = VoiceBackendFixture()
        unsupported.capabilityValue = .init(localeSupported: false, onDeviceSupported: false)
        let first = LocalVoiceInput(localeIdentifier: "xx-ZZ", backend: unsupported)
        await first.start()
        #expect(first.phase == .failed)
        #expect(unsupported.permissionRequests == 0)
        #expect(unsupported.starts == 0)
        let noLocal = VoiceBackendFixture()
        noLocal.capabilityValue = .init(localeSupported: true, onDeviceSupported: false)
        let second = LocalVoiceInput(backend: noLocal)
        await second.start()
        #expect(second.phase == .failed)
        #expect(second.errorMessage?.contains("no hosted fallback") == true)
        #expect(noLocal.permissionRequests == 0)
        #expect(noLocal.starts == 0)
    }

    @Test func explicitStartAlwaysRequiresLocalRecognitionAndStopKeepsReviewableText() async throws {
        let backend = VoiceBackendFixture()
        let voice = LocalVoiceInput(localeIdentifier: "en-US", backend: backend)
        await voice.start()
        #expect(voice.isRecording)
        #expect(backend.permissionRequests == 1)
        #expect(backend.requiresOnDevice == true)
        backend.emit(.partial("A café note 🌍"))
        #expect(voice.transcript == "A café note 🌍")
        let lateCallback = try #require(backend.callback)
        voice.stop()
        #expect(!voice.isRecording)
        #expect(!backend.running)
        #expect(voice.transcript == "A café note 🌍")
        lateCallback(.final("Late stale text"))
        #expect(voice.transcript == "A café note 🌍")
        voice.cancel()
        #expect(voice.transcript.isEmpty)
        #expect(voice.phase == .idle)
    }

    @Test func cancelDuringPermissionPromptCannotStartCaptureAfterLateApproval() async {
        let backend = VoiceBackendFixture()
        backend.holdPermissions = true
        let voice = LocalVoiceInput(backend: backend)
        let pending = Task { await voice.start() }
        for _ in 0..<100 where backend.permissionRequests == 0 { await Task.yield() }
        #expect(voice.phase == .requestingPermission)
        voice.cancel()
        backend.completePermissions()
        await pending.value
        #expect(voice.phase == .idle)
        #expect(backend.starts == 0)
        #expect(!backend.running)
        #expect(voice.transcript.isEmpty)
    }

    @Test func permissionAndCaptureErrorsAreActionableAndCleanedUp() async {
        let denied = VoiceBackendFixture()
        denied.permissionError = "Microphone permission denied"
        let first = LocalVoiceInput(backend: denied)
        await first.start()
        #expect(first.phase == .failed)
        #expect(first.errorMessage == "Microphone permission denied")
        #expect(denied.starts == 0)
        let broken = VoiceBackendFixture()
        broken.beginError = "No audio input"
        let second = LocalVoiceInput(backend: broken)
        await second.start()
        #expect(second.phase == .failed)
        #expect(!broken.running)
        #expect(broken.stops > 0)
    }

    @Test func finalErrorInterruptionAndTextLimitAllStopResources() async {
        let backend = VoiceBackendFixture()
        let voice = LocalVoiceInput(maximumTextBytes: 32, backend: backend)
        await voice.start()
        backend.emit(.partial("Keep this bounded text"))
        backend.emit(.partial(String(repeating: "🌍", count: 9)))
        #expect(voice.phase == .failed)
        #expect(!backend.running)
        #expect(voice.transcript == "Keep this bounded text")
        await voice.start()
        backend.emit(.final("Final transcript"))
        #expect(voice.phase == .stopped)
        #expect(!backend.running)
        #expect(voice.transcript == "Final transcript")
        await voice.start()
        backend.emit(.partial("Partial"))
        backend.emit(.failure("Recognizer interrupted"))
        #expect(voice.phase == .failed)
        #expect(!backend.running)
        #expect(voice.transcript == "Partial")
        await voice.start()
        backend.emit(.interrupted)
        #expect(voice.phase == .stopped)
        #expect(!backend.running)
    }

    @Test func changingLocaleStopsCurrentCaptureAndLateCallbacksCannotOverwriteTranscript() async throws {
        let backend = VoiceBackendFixture()
        let voice = LocalVoiceInput(localeIdentifier: "en-US", backend: backend)
        await voice.start()
        backend.emit(.partial("Keep this partial"))
        let stale = try #require(backend.callback)
        voice.localeIdentifier = "fr-FR"
        #expect(voice.phase == .stopped)
        #expect(!backend.running)
        #expect(voice.transcript == "Keep this partial")
        stale(.final("Stale result"))
        #expect(voice.transcript == "Keep this partial")
        #expect(try LocalVoiceInput.validatedLocale("en_US") == LocalVoiceInput.validatedLocale("en-US"))
    }

    @Test func durationLimitStopsRecordingWithoutSendingText() async throws {
        let backend = VoiceBackendFixture()
        let voice = LocalVoiceInput(maximumDuration: 1, backend: backend)
        await voice.start()
        backend.emit(.partial("Review only"))
        try await Task.sleep(for: .milliseconds(1_150))
        #expect(voice.phase == .stopped)
        #expect(!backend.running)
        #expect(voice.transcript == "Review only")
        #expect(voice.status.contains("duration limit"))
    }

    @Test func malformedLocaleAndLimitConfigurationAreBounded() async {
        for locale in ["", "en_US@secret", "../en-US", String(repeating: "x", count: 65), "\nen-US"] {
            #expect(throws: (any Error).self) { try LocalVoiceInput.validatedLocale(locale) }
        }
        #expect((try? LocalVoiceInput.validatedLocale("en-US")) != nil)
        let backend = VoiceBackendFixture()
        let voice = LocalVoiceInput(localeIdentifier: "../en-US", maximumDuration: .infinity, maximumTextBytes: Int.max, backend: backend)
        #expect(voice.maximumDuration == 30)
        #expect(voice.maximumTextBytes == 8_000)
        await voice.start()
        #expect(voice.phase == .failed)
        #expect(backend.capabilityChecks == 0)
        #expect(backend.permissionRequests == 0)
    }

    @Test func duplicateStartWhilePermissionsPendingCannotCreateSecondCapture() async {
        let backend = VoiceBackendFixture()
        backend.holdPermissions = true
        let voice = LocalVoiceInput(backend: backend)
        let pending = Task { await voice.start() }
        for _ in 0..<100 where backend.permissionRequests == 0 { await Task.yield() }
        await voice.start()
        #expect(backend.permissionRequests == 1)
        #expect(backend.capabilityChecks == 1)
        backend.completePermissions()
        await pending.value
        #expect(backend.starts == 1)
        #expect(voice.isRecording)
        voice.cancel()
    }

    @Test func callerCancellationBeforePermissionReturnsCannotCaptureOrLeaveBusyState() async {
        let backend = VoiceBackendFixture()
        backend.holdPermissions = true
        let voice = LocalVoiceInput(backend: backend)
        let pending = Task { await voice.start() }
        for _ in 0..<100 where backend.permissionRequests == 0 { await Task.yield() }
        pending.cancel()
        backend.completePermissions()
        await pending.value
        #expect(voice.phase == .stopped)
        #expect(!voice.isBusy && !backend.running)
        #expect(backend.starts == 0)
        #expect(voice.transcript.isEmpty)
    }

    @Test func synchronousFinalDuringStartStaysStoppedAndRejectsLaterFailure() async throws {
        let backend = VoiceBackendFixture()
        backend.initialEvent = .final("Ready immediately 🌍")
        let voice = LocalVoiceInput(backend: backend)
        await voice.start()
        #expect(voice.phase == .stopped)
        #expect(!backend.running)
        #expect(voice.transcript == "Ready immediately 🌍")
        let stale = try #require(backend.historicalCallback)
        stale(.failure("Late callback"))
        #expect(voice.phase == .stopped)
        #expect(voice.errorMessage == nil)
        #expect(voice.transcript == "Ready immediately 🌍")
    }

    @Test func malformedRecognitionTextStopsWithoutReplacingLastBoundedTranscript() async {
        let backend = VoiceBackendFixture()
        let voice = LocalVoiceInput(backend: backend)
        await voice.start()
        backend.emit(.partial("Keep café\nمرحبا 🌍"))
        backend.emit(.final("Invalid\u{0}payload"))
        #expect(voice.phase == .failed)
        #expect(!backend.running)
        #expect(voice.transcript == "Keep café\nمرحبا 🌍")
        #expect(voice.errorMessage?.contains("control characters") == true)
    }

    @Test func sleepStopsCaptureSynchronouslyAndStaleEventsCannotResumeIt() async throws {
        let backend = VoiceBackendFixture(), notifications = NotificationCenter()
        let voice = LocalVoiceInput(backend: backend, sleepNotificationCenter: notifications)
        await voice.start()
        backend.emit(.partial("Review after wake"))
        let stale = try #require(backend.callback)
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        // No yield: the audio backend must be stopped before notification delivery returns.
        #expect(!backend.running)
        #expect(!voice.isBusy)
        #expect(voice.phase == .stopped)
        #expect(voice.transcript == "Review after wake")
        #expect(voice.status.contains("before sleep"))
        stale(.final("Late result after sleep"))
        #expect(voice.transcript == "Review after wake")
    }

    @Test func sleepInvalidatesPendingPermissionBeforeLateConsentCanStartCapture() async {
        let backend = VoiceBackendFixture(), notifications = NotificationCenter()
        backend.holdPermissions = true
        let voice = LocalVoiceInput(backend: backend, sleepNotificationCenter: notifications)
        let pending = Task { await voice.start() }
        for _ in 0..<100 where backend.permissionRequests == 0 { await Task.yield() }
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(voice.phase == .stopped)
        #expect(!voice.isBusy && !backend.running)
        backend.completePermissions()
        await pending.value
        #expect(backend.starts == 0)
        #expect(voice.status.contains("before sleep"))
    }
}

@MainActor
private final class VoiceBackendFixture: LocalVoiceBackend {
    var capabilityValue = LocalVoiceCapability(localeSupported: true, onDeviceSupported: true)
    var capabilityChecks = 0
    var permissionRequests = 0
    var starts = 0
    var stops = 0
    var requiresOnDevice: Bool?
    var running = false
    var holdPermissions = false
    var permissionError: String?
    var beginError: String?
    var beginDelay: TimeInterval = 0
    var callback: (@MainActor @Sendable (LocalSpeechEvent) -> Void)?
    var historicalCallback: (@MainActor @Sendable (LocalSpeechEvent) -> Void)?
    var initialEvent: LocalSpeechEvent?
    private var permissionContinuation: CheckedContinuation<Void, Never>?
    func capability(localeIdentifier: String) -> LocalVoiceCapability { capabilityChecks += 1; return capabilityValue }
    func requestPermissions() async throws {
        permissionRequests += 1
        if holdPermissions { await withCheckedContinuation { permissionContinuation = $0 } }
        try Task.checkCancellation()
        if let permissionError { throw RelayError.message(permissionError) }
    }
    func completePermissions() { permissionContinuation?.resume(); permissionContinuation = nil }
    func begin(localeIdentifier: String, requiresOnDeviceRecognition: Bool,
               onEvent: @escaping @MainActor @Sendable (LocalSpeechEvent) -> Void) throws {
        starts += 1
        requiresOnDevice = requiresOnDeviceRecognition
        callback = onEvent
        historicalCallback = onEvent
        running = true
        if beginDelay > 0 { Thread.sleep(forTimeInterval: beginDelay) }
        if let beginError { throw RelayError.message(beginError) }
        if let initialEvent { onEvent(initialEvent) }
    }
    func emit(_ event: LocalSpeechEvent) { callback?(event) }
    func stop() { stops += 1; running = false; callback = nil }
}
