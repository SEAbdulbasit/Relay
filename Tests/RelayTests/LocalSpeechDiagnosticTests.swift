import AppKit
import Foundation
import Testing
@testable import Relay

@MainActor
struct LocalSpeechDiagnosticTests {
    private final class Backend: LocalSpeechDiagnosticBackend {
        var renderedFrames = 0
        var begins = 0
        var stops = 0
        var failure: LocalSpeechDiagnosticFailure?
        var initial: LocalSpeechDiagnosticEvent?
        var callbacks: [@MainActor @Sendable (LocalSpeechDiagnosticEvent) -> Void] = []
        func begin(onEvent: @escaping @MainActor @Sendable (LocalSpeechDiagnosticEvent) -> Void) throws {
            begins += 1; callbacks.append(onEvent)
            if let failure { throw failure }
            if let initial { onEvent(initial) }
        }
        func stop() { stops += 1 }
        func emit(_ event: LocalSpeechDiagnosticEvent, index: Int? = nil) {
            if case .rendered(let frames) = event { renderedFrames = frames }
            callbacks[index ?? (callbacks.count - 1)](event)
        }
    }

    @Test func initializationIsSilentAndUnavailablePermissionNeverImpliesSuccess() {
        let backend = Backend()
        let diagnostic = LocalSpeechDiagnostic(backend: backend)
        #expect(!diagnostic.isBusy && diagnostic.phase == .idle)
        #expect(diagnostic.audioFrames == 0 && diagnostic.elapsedSeconds == nil)
        #expect(backend.begins == 0 && backend.stops == 0)
        backend.failure = .permission(.denied)
        let denied = LocalSpeechDiagnostic(backend: backend)
        denied.start()
        #expect(denied.phase == .failed)
        #expect(denied.status.contains("does not request permission"))
        #expect(backend.begins == 1 && backend.stops == 1)
    }

    @Test func permissionDiagnosticPreservesTypedStateWithoutGuessingConsent() {
        #expect(LocalSpeechDiagnosticPermissionState(.notDetermined) == .notDetermined)
        #expect(LocalSpeechDiagnosticPermissionState(.denied) == .denied)
        #expect(LocalSpeechDiagnosticPermissionState(.restricted) == .restricted)
        #expect(LocalSpeechDiagnosticPermissionState(.authorized) == .authorized)
        for state in [LocalSpeechDiagnosticPermissionState.notDetermined, .denied, .restricted, .unknown] {
            let backend = Backend()
            backend.failure = .permission(state)
            let check = LocalSpeechDiagnostic(backend: backend)
            check.start()
            #expect(check.phase == .failed)
            #expect(check.status.contains("\(state.label) for this app process"))
            #expect(check.audioFrames == 0)
            #expect(check.status.contains("does not request permission"))
        }
    }

    @Test func explicitSpeechAuthorizationDoesNotStartSyntheticCheckAfterApproval() async {
        let backend = Backend()
        backend.renderedFrames = 50_000 // Prior check counts cannot leak into consent status.
        let check = LocalSpeechDiagnostic(backend: backend, authorize: { .authorized })
        check.recheckSpeechAccess()
        await check.waitForSpeechAccessRecheck()
        #expect(check.phase == .idle && !check.isBusy)
        #expect(check.status.contains("authorized for this app process"))
        #expect(backend.begins == 0)
        #expect(check.audioFrames == 0 && check.elapsedSeconds == nil)
    }

    @Test func explicitDeniedSpeechAuthorizationReportsStateWithoutStartingCheck() async {
        let backend = Backend()
        let check = LocalSpeechDiagnostic(backend: backend, authorize: { .denied })
        check.recheckSpeechAccess()
        await check.waitForSpeechAccessRecheck()
        #expect(check.phase == .failed && !check.isBusy)
        #expect(check.status.contains("denied for this app process"))
        #expect(backend.begins == 0)
        #expect(check.audioFrames == 0)
    }

    @Test func canceledSpeechAuthorizationCannotStartCheckOrOverwriteStoppedStateAfterLateApproval() async {
        let backend = Backend(), gate = AuthorizationGate()
        let check = LocalSpeechDiagnostic(backend: backend, authorize: { await gate.wait() })
        check.recheckSpeechAccess()
        for _ in 0..<100 where !(await gate.isWaiting) { await Task.yield() }
        #expect(check.phase == .authorizing && check.isBusy)
        check.stop()
        #expect(check.phase == .stopped && !check.isBusy)
        await gate.complete(.authorized)
        await check.waitForSpeechAccessRecheck()
        #expect(check.phase == .stopped)
        #expect(check.status.contains("A macOS prompt may remain"))
        #expect(backend.begins == 0)
        #expect(check.audioFrames == 0)
    }

    @Test func onlyFinalExactNormalizedPhraseWithActualFramesPasses() {
        let backend = Backend()
        let check = LocalSpeechDiagnostic(backend: backend)
        check.start()
        backend.emit(.rendered(frames: 40_000))
        backend.emit(.recognized("Local voice check one two three", final: false))
        #expect(check.isBusy)
        backend.emit(.recognized("LOCAL voice check: 1, 2, 3.", final: true))
        #expect(check.phase == .passed && !check.isBusy)
        #expect(check.audioFrames == 40_000 && check.elapsedSeconds != nil)
        #expect(!check.status.contains("LOCAL voice"))
        #expect(backend.stops == 1)
        backend.emit(.failure(.recognition))
        #expect(check.phase == .passed)
    }

    @Test func wrongTextOrNoAudioCannotPassAndRawRecognitionIsNotExposed() {
        let backend = Backend()
        let check = LocalSpeechDiagnostic(backend: backend)
        check.start()
        backend.emit(.rendered(frames: 1_000))
        backend.emit(.recognized("Private raw recognizer text sentinel", final: true))
        #expect(check.phase == .failed)
        #expect(!check.status.contains("sentinel"))
        check.start()
        backend.renderedFrames = 0
        backend.emit(.recognized(LocalSpeechDiagnostic.phrase, final: true))
        #expect(check.phase == .failed)
        #expect(!check.status.contains("passed"))
    }

    @Test func stopAndRestartInvalidateEveryOldCallbackAndRejectDuplicateStart() {
        let backend = Backend()
        let diagnostic = LocalSpeechDiagnostic(backend: backend)
        diagnostic.start(); diagnostic.start()
        #expect(backend.begins == 1)
        diagnostic.stop()
        #expect(diagnostic.phase == .stopped && backend.stops == 1)
        diagnostic.start()
        #expect(backend.begins == 2)
        backend.emit(.recognized(LocalSpeechDiagnostic.phrase, final: true), index: 0)
        backend.emit(.failure(.recognition), index: 0)
        #expect(diagnostic.isBusy)
        backend.emit(.rendered(frames: 900))
        backend.emit(.recognized(LocalSpeechDiagnostic.phrase, final: true))
        #expect(diagnostic.phase == .passed)
    }

    @Test func frameLimitsAndMalformedTranscriptsRefuseSuccess() {
        for text in ["Local voice check one two three extra", "Local voice check one two three\u{0}", String(repeating: "a", count: 513)] {
            #expect(!LocalSpeechDiagnostic.matchesExpectedPhrase(text))
        }
        #expect(LocalSpeechDiagnostic.matchesExpectedPhrase("Local voice check 123."))
        for frames in [-1, LocalSpeechDiagnostic.maximumFrames + 1] {
            let backend = Backend()
            let diagnostic = LocalSpeechDiagnostic(backend: backend)
            diagnostic.start(); backend.emit(.rendered(frames: frames))
            #expect(diagnostic.phase == .failed)
            #expect(!diagnostic.isBusy)
        }
    }

    @Test func timeoutStopsOwnedResourcesWithoutARecognitionResult() async {
        let backend = Backend()
        let check = LocalSpeechDiagnostic(backend: backend, maximumDuration: 0.05)
        check.start()
        await check.waitForCurrentCheck()
        #expect(check.phase == .failed && !check.isBusy)
        #expect(check.status.contains("time limit"))
        #expect(backend.stops == 1)
    }

    @Test func sleepNotificationStopsSynchronouslyAndLateResultCannotPass() {
        let backend = Backend(), center = NotificationCenter()
        let check = LocalSpeechDiagnostic(backend: backend, sleepNotificationCenter: center)
        check.start()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(check.phase == .stopped && backend.stops == 1)
        backend.emit(.rendered(frames: 1_000))
        backend.emit(.recognized(LocalSpeechDiagnostic.phrase, final: true))
        #expect(check.phase == .stopped)
    }

    @Test func synchronousFinalAndPartialStartFailureAlwaysCleanResources() {
        let backend = Backend()
        backend.renderedFrames = 100
        backend.initial = .recognized(LocalSpeechDiagnostic.phrase, final: true)
        let check = LocalSpeechDiagnostic(backend: backend)
        check.start()
        #expect(check.phase == .passed && backend.stops == 1)
        backend.initial = nil; backend.failure = .recognition
        check.start()
        #expect(check.phase == .failed && backend.stops == 2)
    }
}

private actor AuthorizationGate {
    private var continuation: CheckedContinuation<LocalSpeechDiagnosticPermissionState, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async -> LocalSpeechDiagnosticPermissionState {
        await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ state: LocalSpeechDiagnosticPermissionState) {
        continuation?.resume(returning: state)
        continuation = nil
    }
}
