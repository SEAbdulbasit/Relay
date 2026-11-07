import AppKit
import Foundation
import Testing
@testable import Relay

/// Native recognizer ownership with synthetic state delivery. No real window,
/// mouse event, OS grant, speech recognizer or microphone is used.
@MainActor struct SidekickHoldGestureLifecycleTests {
    @MainActor private final class State {
        var begins = 0
        var running = false
        var endings: [Bool] = []
        weak var gesture: SidekickHoldGesture?
    }

    @Test func optedOutHoldDoesNotDelayAnOrdinaryClick() throws {
        let view = NSView()
        var enabled = false
        let gesture = SidekickHoldGesture(view: view, shouldBegin: { enabled }, begin: {
            Issue.record("A delegate preflight cannot start capture.")
            return true
        }, end: { _ in }, attached: { _ in true })
        let native = try #require(view.gestureRecognizers.first)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!gesture.gestureRecognizer(native, shouldAttemptToRecognizeWith: event))
        enabled = true
        #expect(gesture.gestureRecognizer(native, shouldAttemptToRecognizeWith: event))
        gesture.detach()
        #expect(!gesture.gestureRecognizer(native, shouldAttemptToRecognizeWith: event))
    }

    @Test func aViewWithoutAVisibleWindowCannotBegin() throws {
        let view = NSView()
        let state = State()
        let gesture = SidekickHoldGesture(view: view, shouldBegin: { true }, begin: { state.begins += 1; return true }, end: { state.endings.append($0) })
        let native = try #require(view.gestureRecognizers.first)
        #expect(!gesture.gestureRecognizerShouldBegin(native))
        gesture.receive(state: .began, location: .zero)
        #expect(state.begins == 0 && state.endings.isEmpty)
        gesture.detach()
    }

    @Test func detachAfterArmingRejectsEveryLateCallbackAndIsIdempotent() throws {
        let view = NSView()
        let state = State()
        let gesture = SidekickHoldGesture(view: view, shouldBegin: { true }, begin: { state.begins += 1; return true },
            end: { state.endings.append($0) }, attached: { _ in true })
        let native = try #require(view.gestureRecognizers.first)
        #expect(gesture.gestureRecognizerShouldBegin(native))
        gesture.detach()
        gesture.detach()
        gesture.cancel()
        #expect(view.gestureRecognizers.isEmpty && native.view == nil)
        #expect(native.target == nil && native.delegate == nil && !native.isEnabled)
        #expect(!gesture.gestureRecognizerShouldBegin(native))
        for state in [NSGestureRecognizer.State.began, .changed, .ended, .cancelled, .failed] {
            gesture.receive(state: state, location: .zero)
        }
        #expect(state.begins == 0 && state.endings.isEmpty)
    }

    @Test func cancellationEndsOnceAndRequiresANewDelegateBegin() throws {
        let view = NSView()
        let state = State()
        let gesture = SidekickHoldGesture(view: view, shouldBegin: { true }, begin: {
            state.begins += 1; state.running = true; return true
        }, end: { state.endings.append($0); state.running = false }, attached: { _ in true })
        let native = try #require(view.gestureRecognizers.first)
        #expect(gesture.gestureRecognizerShouldBegin(native))
        gesture.receive(state: .began, location: .zero)
        #expect(state.running)
        gesture.cancel()
        #expect(!state.running && state.endings == [true])
        gesture.cancel()
        gesture.receive(state: .began, location: .zero)
        gesture.receive(state: .ended, location: .zero)
        #expect(state.begins == 1 && state.endings == [true])
        #expect(gesture.gestureRecognizerShouldBegin(native))
        gesture.receive(state: .began, location: .zero)
        gesture.receive(state: .ended, location: .zero)
        #expect(state.begins == 2 && state.endings == [true, false])
        gesture.detach()
    }

    @Test func externallyRemovedRecognizerCannotDeliverALateBegin() throws {
        let view = NSView()
        let state = State()
        let gesture = SidekickHoldGesture(view: view, shouldBegin: { true }, begin: { state.begins += 1; return true },
            end: { state.endings.append($0) }, attached: { _ in true })
        let native = try #require(view.gestureRecognizers.first)
        #expect(gesture.gestureRecognizerShouldBegin(native))
        view.removeGestureRecognizer(native)
        gesture.receive(state: .began, location: .zero)
        #expect(state.begins == 0 && state.endings.isEmpty)
        gesture.detach()
    }

    @Test(arguments: ["detach", "cancel", "release"])
    func reentrantRemovalDuringBeginCancelsItsAcceptedResult(method: String) throws {
        let view = NSView()
        let state = State()
        let gesture = SidekickHoldGesture(view: view, shouldBegin: { true }, begin: {
            state.begins += 1; state.running = true
            switch method {
            case "detach": state.gesture?.detach()
            case "cancel": state.gesture?.cancel()
            default: state.gesture?.receive(state: .ended, location: .zero)
            }
            return true
        }, end: { state.endings.append($0); state.running = false }, attached: { _ in true })
        state.gesture = gesture
        let native = try #require(view.gestureRecognizers.first)
        #expect(gesture.gestureRecognizerShouldBegin(native))
        gesture.receive(state: .began, location: .zero)
        #expect(state.begins == 1 && !state.running && state.endings == [true])
        gesture.receive(state: .ended, location: .zero)
        #expect(state.endings == [true])
        gesture.detach()
    }

    @Test func deinitializingAnAcceptedOwnerStopsItsCaptureAndRemovesTheRecognizer() throws {
        let view = NSView()
        let state = State()
        var gesture: SidekickHoldGesture? = SidekickHoldGesture(view: view, shouldBegin: { true }, begin: {
            state.begins += 1; state.running = true; return true
        }, end: { state.endings.append($0); state.running = false }, attached: { _ in true })
        let native = try #require(view.gestureRecognizers.first)
        #expect(gesture?.gestureRecognizerShouldBegin(native) == true)
        gesture?.receive(state: .began, location: .zero)
        #expect(state.running)
        gesture = nil
        #expect(!state.running && state.endings == [true])
        #expect(view.gestureRecognizers.isEmpty && native.target == nil)
    }

    @Test(arguments: [true, false])
    func detachStopsCurrentVoiceAndBlocksADeferredPermissionStart(holdPermission: Bool) async throws {
        let backend = GestureVoiceBackend()
        backend.holdPermission = holdPermission
        let voice = LocalVoiceInput(backend: backend, sleepNotificationCenter: NotificationCenter())
        let fixture = GestureVoiceOwner(voice: voice)
        defer { fixture.gesture?.detach(); voice.cancel(); backend.completePermissions() }
        let view = NSView()
        let gesture = SidekickHoldGesture(view: view, shouldBegin: { true }, begin: {
            fixture.start = Task { @MainActor in await voice.start() }
            return true
        }, end: { cancelled in
            fixture.endings.append(cancelled)
            fixture.start?.cancel()
            voice.stop()
        }, attached: { _ in true })
        fixture.gesture = gesture
        let native = try #require(view.gestureRecognizers.first)
        #expect(gesture.gestureRecognizerShouldBegin(native))
        gesture.receive(state: .began, location: .zero)
        for _ in 0..<1_000 where backend.permissionRequests == 0 { await Task.yield() }
        try #require(backend.permissionRequests == 1)
        if !holdPermission {
            await fixture.start?.value
            try #require(voice.isRecording && backend.running)
        }
        gesture.detach()
        #expect(!backend.running && !voice.isBusy && fixture.endings == [true])
        backend.completePermissions()
        await fixture.start?.value
        gesture.receive(state: .began, location: .zero)
        gesture.receive(state: .ended, location: .zero)
        #expect(!backend.running && !voice.isBusy)
        #expect(backend.starts == (holdPermission ? 0 : 1))
        #expect(fixture.endings == [true])
    }
}

@MainActor private final class GestureVoiceOwner {
    let voice: LocalVoiceInput
    weak var gesture: SidekickHoldGesture?
    var start: Task<Void, Never>?
    var endings: [Bool] = []
    init(voice: LocalVoiceInput) { self.voice = voice }
}

@MainActor private final class GestureVoiceBackend: LocalVoiceBackend {
    var holdPermission = false
    var permissionRequests = 0
    var starts = 0
    var running = false
    private var permission: CheckedContinuation<Void, Never>?
    func capability(localeIdentifier: String) -> LocalVoiceCapability { .init(localeSupported: true, onDeviceSupported: true) }
    func requestPermissions() async throws {
        permissionRequests += 1
        if holdPermission { await withCheckedContinuation { permission = $0 } }
    }
    func completePermissions() { permission?.resume(); permission = nil }
    func begin(localeIdentifier: String, requiresOnDeviceRecognition: Bool,
               onEvent: @escaping @MainActor @Sendable (LocalSpeechEvent) -> Void) throws {
        starts += 1
        running = true
    }
    func stop() { running = false }
}
