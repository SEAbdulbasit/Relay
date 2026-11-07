import AppKit
@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation
import Observation

nonisolated struct LocalVoiceCapability: Sendable {
    let localeSupported: Bool
    let onDeviceSupported: Bool
}
nonisolated enum LocalSpeechEvent: Sendable {
    case partial(String)
    case final(String)
    case failure(String)
    case interrupted
}

/// Legacy consent APIs invoke their completion on arbitrary queues. Keep the entire
/// continuation callback nonisolated and transfer only the authorization's integer value.
nonisolated enum LocalVoiceAuthorizationBridge {
    static func status(
        request: @Sendable (@escaping @Sendable (Int) -> Void) -> Void
    ) async -> Int {
        await withCheckedContinuation { continuation in
            request { @Sendable status in continuation.resume(returning: status) }
        }
    }
}

/// Injectable so tests never ask for permissions or activate the user's microphone.
@MainActor
protocol LocalVoiceBackend: AnyObject {
    func capability(localeIdentifier: String) -> LocalVoiceCapability
    func requestPermissions() async throws
    func begin(localeIdentifier: String, requiresOnDeviceRecognition: Bool,
               onEvent: @escaping @MainActor @Sendable (LocalSpeechEvent) -> Void) throws
    func stop()
    func finish()
}

extension LocalVoiceBackend {
    func finish() { stop() }
}

/// Explicit, bounded dictation into a separate reviewable transcript. No initialization-time
/// permission requests, microphone access, automatic draft writes or chat submission occur.
@Observable @MainActor
final class LocalVoiceInput {
    enum Phase { case idle, requestingPermission, recording, finishing, stopped, failed }
    var localeIdentifier: String {
        didSet {
            if localeIdentifier != oldValue, isBusy {
                stop()
                status = "Voice input stopped because its locale changed. Review any transcript and start again explicitly."
            }
        }
    }
    private(set) var transcript = ""
    private(set) var status = "Voice input is off. Start explicitly to dictate on this Mac."
    private(set) var errorMessage: String?
    private(set) var phase: Phase = .idle
    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .requestingPermission || phase == .recording || phase == .finishing }
    private(set) var transcriptIsFinal = false
    private(set) var captureID: UUID?
    private(set) var maximumDuration: TimeInterval
    /// Session-only upper-bound timing, including native startup/teardown; never persisted.
    private(set) var lastCaptureElapsedSeconds: TimeInterval?
    let maximumTextBytes: Int

    @ObservationIgnored private let backend: any LocalVoiceBackend
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var captureStarted: ContinuousClock.Instant?
    @ObservationIgnored private let sleepNotificationCenter: NotificationCenter
    @ObservationIgnored private var inactiveObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var sessionState = WorkspaceSessionState()

    init(localeIdentifier: String = Locale.current.identifier,
         maximumDuration: TimeInterval = 30, maximumTextBytes: Int = 8_000,
         backend: (any LocalVoiceBackend)? = nil,
         sleepNotificationCenter: NotificationCenter? = nil) {
        self.localeIdentifier = localeIdentifier
        self.maximumDuration = maximumDuration.isFinite ? min(60, max(1, maximumDuration)) : 30
        self.maximumTextBytes = min(8_000, max(1, maximumTextBytes))
        self.backend = backend ?? AppleOnDeviceVoiceBackend()
        let sleepCenter = sleepNotificationCenter ?? NSWorkspace.shared.notificationCenter
        self.sleepNotificationCenter = sleepCenter
        // Tear down synchronously for lock/user switching as well as sleep. A
        // queued Task must not leave audio live or accept late permission consent.
        for name in WorkspaceSessionState.notifications {
            inactiveObservers.append(sleepCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sessionState.consume(name)
                    guard !self.sessionState.isActive, self.isBusy else { return }
                    self.stop()
                    self.status = name == NSWorkspace.willSleepNotification
                        ? "Voice input stopped before sleep. Review any transcript; start again explicitly when ready."
                        : "Voice input stopped because this Mac session became inactive. Review any transcript; start again explicitly."
                }
            })
        }
    }

    @discardableResult
    func setMaximumDuration(_ seconds: TimeInterval) -> Bool {
        guard !isBusy, seconds.isFinite, (1...60).contains(seconds) else { return false }
        maximumDuration = seconds
        return true
    }

    func start() async {
        guard !isBusy else { return }
        guard sessionState.isActive else {
            status = "Voice input is off while this Mac session is inactive. Start explicitly after unlocking."
            return
        }
        revision += 1
        let expected = revision
        transcript = ""
        transcriptIsFinal = false
        captureID = UUID()
        lastCaptureElapsedSeconds = nil
        errorMessage = nil
        phase = .requestingPermission
        status = "Checking on-device speech and permissions…"
        let pending = Task { [weak self] in
            guard let self else { return }
            await self.prepareAndStart(expected)
        }
        preparation = pending
        await withTaskCancellationHandler {
            await pending.value
        } onCancel: {
            pending.cancel()
        }
        if revision == expected { preparation = nil }
    }

    private func prepareAndStart(_ expected: Int) async {
        do {
            try gate(expected)
            let locale = try Self.validatedLocale(localeIdentifier)
            let capability = backend.capability(localeIdentifier: locale)
            guard capability.localeSupported else { throw RelayError.message("Speech recognition does not support this locale. Choose a supported language; no microphone capture started.") }
            guard capability.onDeviceSupported else { throw RelayError.message("On-device recognition is unavailable for this locale on this Mac. Voice input remains off; there is no hosted fallback.") }
            try await backend.requestPermissions()
            try gate(expected)
            // Consent wait is not capture time. Take the monotonic start before begin()
            // so native startup cannot add an extra full duration to microphone access.
            let started = ContinuousClock.now
            let captureDeadline = started.advanced(by: .seconds(maximumDuration))
            captureStarted = started
            phase = .recording
            status = "Listening on this Mac. Stop within \(Int(maximumDuration)) seconds, then review the transcript."
            try backend.begin(localeIdentifier: locale, requiresOnDeviceRecognition: true) { [weak self] event in
                self?.receive(event, revision: expected)
            }
            try gate(expected)
            // A synchronous backend failure/final callback may have already stopped the run.
            guard phase == .recording else { return }
            if ContinuousClock.now >= captureDeadline {
                stopAtDurationLimit(expected)
                return
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(until: captureDeadline, clock: .continuous) }
                catch { return }
                self?.stopAtDurationLimit(expected)
            }
        } catch is CancellationError {
            guard revision == expected else { return }
            endCapture()
            phase = .stopped
            status = "Voice input canceled before it became ready. Nothing was sent."
        } catch {
            guard revision == expected else { return }
            endCapture()
            phase = .failed
            errorMessage = String(error.localizedDescription.prefix(500))
            status = "Voice input could not start. Nothing was sent."
        }
    }

    func stop() {
        guard isBusy else { return }
        revision += 1
        endCapture()
        phase = .stopped
        status = transcript.isEmpty ? "Voice input stopped. No transcript was captured." : "Voice input stopped. Review the transcript before using it; nothing was sent."
    }

    func cancel() {
        revision += 1
        endCapture()
        transcript = ""
        transcriptIsFinal = false
        captureID = nil
        errorMessage = nil
        phase = .idle
        status = "Voice input canceled and transcript cleared. Nothing was sent."
    }

    /// End microphone input immediately, then allow a bounded on-device final
    /// result. A partial transcript is retained for review, never auto-submitted.
    func finishCapture(timeout: Duration = .milliseconds(1_500)) async -> Bool {
        guard let id = beginFinishingCapture() else { return false }
        return await finishCapture(expectedCaptureID: id, timeout: timeout)
    }

    /// Called synchronously at pointer-up so audio does not continue until an
    /// asynchronous final-transcript task gets its next actor turn.
    func beginFinishingCapture() -> UUID? {
        guard let id = captureID else { return nil }
        if phase == .stopped { return transcriptIsFinal ? id : nil }
        if phase == .finishing { return id }
        guard phase == .recording else { stop(); return nil }
        phase = .finishing
        status = "Microphone off. Finishing the on-device transcript…"
        deadline?.cancel()
        deadline = nil
        backend.finish()
        return id
    }

    func finishCapture(expectedCaptureID id: UUID, timeout: Duration = .milliseconds(1_500)) async -> Bool {
        guard captureID == id else { return false }
        guard !Task.isCancelled else {
            if phase == .finishing { stop() }
            return false
        }
        if phase == .stopped { return transcriptIsFinal }
        guard phase == .finishing else { return false }
        let expected = revision
        let until = ContinuousClock.now.advanced(by: min(.seconds(2), max(.milliseconds(20), timeout)))
        while revision == expected, phase == .finishing, ContinuousClock.now < until {
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { if captureID == id { stop() }; return false }
        }
        guard captureID == id else { return false }
        guard !Task.isCancelled else {
            if phase == .finishing { stop() }
            return false
        }
        if phase == .finishing {
            stop()
            status = "A final transcript was not available in time. Review the captured words before sending."
        }
        return phase == .stopped && transcriptIsFinal
    }

    private func receive(_ event: LocalSpeechEvent, revision expected: Int) {
        guard revision == expected, phase == .recording || phase == .finishing else { return }
        switch event {
        case .partial(let text), .final(let text):
            guard !text.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && !["\n", "\r", "\t"].contains(String($0))
            }) else {
                revision += 1
                endCapture()
                phase = .failed
                errorMessage = "Speech returned embedded control characters. Voice input stopped; the last ordinary transcript remains available."
                status = "Transcript could not be accepted. Review the retained text; nothing was sent."
                return
            }
            guard text.utf8.count <= maximumTextBytes else {
                revision += 1
                endCapture()
                phase = .failed
                errorMessage = "The transcript exceeded \(maximumTextBytes) UTF-8 bytes. Voice input stopped; the last bounded transcript remains available."
                status = "Transcript limit reached. Review the retained text; nothing was sent."
                return
            }
            transcript = text
            transcriptIsFinal = false
            if case .final = event {
                transcriptIsFinal = true
                revision += 1
                endCapture()
                phase = .stopped
                status = "On-device transcript ready for review. Nothing was sent."
            }
        case .failure(let message):
            revision += 1
            endCapture()
            phase = .failed
            errorMessage = String(message.prefix(500))
            status = "Speech recognition stopped with an error. Review any partial transcript; nothing was sent."
        case .interrupted:
            revision += 1
            endCapture()
            phase = .stopped
            status = "Voice input was interrupted by a device or system change. Review any partial transcript; nothing was sent."
        }
    }

    private func endCapture() {
        preparation?.cancel(); preparation = nil
        deadline?.cancel(); deadline = nil
        backend.stop()
        if let captureStarted {
            let elapsed = captureStarted.duration(to: ContinuousClock.now).components
            lastCaptureElapsedSeconds = max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            self.captureStarted = nil
        }
    }
    private func stopAtDurationLimit(_ expected: Int) {
        guard revision == expected, phase == .recording else { return }
        stop()
        status = "Voice input stopped at its duration limit. Review the transcript; nothing was sent."
    }
    private func gate(_ expected: Int) throws {
        try Task.checkCancellation()
        guard revision == expected else { throw CancellationError() }
    }
    nonisolated static func validatedLocale(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw RelayError.message("Choose a plain speech locale identifier, such as en-US. No microphone capture started.")
        }
        let pieces = value.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count), let language = pieces.first,
              (2...8).contains(language.count), language.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              pieces.allSatisfy({ (1...8).contains($0.count) }) else {
            throw RelayError.message("Choose a supported speech locale, such as en-US. No microphone capture started.")
        }
        return pieces.joined(separator: "-").lowercased()
    }

    isolated deinit {
        for observer in inactiveObservers { sleepNotificationCenter.removeObserver(observer) }
        preparation?.cancel()
        deadline?.cancel()
        backend.stop()
    }
}

/// Capture resources are created only after explicit start, local capability checks and
/// authorization. Audio is never written to disk by this implementation.
@MainActor
private final class AppleOnDeviceVoiceBackend: LocalVoiceBackend {
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sink: VoiceAudioSink?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?

    func capability(localeIdentifier: String) -> LocalVoiceCapability {
        let locale = Locale(identifier: localeIdentifier)
        let supported = SFSpeechRecognizer.supportedLocales().contains { (try? LocalVoiceInput.validatedLocale($0.identifier)) == localeIdentifier }
        guard supported, let candidate = SFSpeechRecognizer(locale: locale) else {
            recognizer = nil
            return .init(localeSupported: false, onDeviceSupported: false)
        }
        recognizer = candidate
        return .init(localeSupported: true, onDeviceSupported: candidate.supportsOnDeviceRecognition)
    }

    func requestPermissions() async throws {
        guard let microphoneUsage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String, !microphoneUsage.isEmpty,
              let speechUsage = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String, !speechUsage.isEmpty else {
            throw RelayError.message("This app build is missing microphone or speech permission descriptions. Rebuild Relay before using voice input.")
        }
        // When launched as a child process of a terminal/IDE (getppid() != 1), macOS TCC checks the parent IDE's Info.plist,
        // which may lack NSSpeechRecognitionUsageDescription and abort the child. Guard against .notDetermined under non-launchd parent.
        let launchedViaLaunchServices = (getppid() == 1)
        try Task.checkCancellation()
        let microphoneAllowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneAllowed = true
        case .notDetermined:
            guard launchedViaLaunchServices else {
                throw RelayError.message("Launch Relay.app via Finder or 'open build/Relay.app' to grant Microphone & Speech Recognition permissions.")
            }
            microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: microphoneAllowed = false
        }
        try Task.checkCancellation()
        guard microphoneAllowed else { throw RelayError.message("Microphone access is not allowed. Enable it for Relay in macOS settings if you want voice input.") }
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            guard launchedViaLaunchServices else {
                throw RelayError.message("Launch Relay.app via Finder or 'open build/Relay.app' to grant Speech Recognition permission.")
            }
            let rawStatus = await LocalVoiceAuthorizationBridge.status { @Sendable reply in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in reply(status.rawValue) }
            }
            speechStatus = SFSpeechRecognizerAuthorizationStatus(rawValue: rawStatus) ?? .denied
        } else { speechStatus = SFSpeechRecognizer.authorizationStatus() }
        try Task.checkCancellation()
        guard speechStatus == .authorized else { throw RelayError.message("Speech recognition access is not allowed. Enable it for Relay in macOS settings if you want on-device dictation.") }
    }

    func begin(localeIdentifier: String, requiresOnDeviceRecognition: Bool,
               onEvent: @escaping @MainActor @Sendable (LocalSpeechEvent) -> Void) throws {
        guard requiresOnDeviceRecognition, let recognizer,
              (try? LocalVoiceInput.validatedLocale(recognizer.locale.identifier)) == localeIdentifier,
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw RelayError.message("On-device speech recognition is unavailable right now. No hosted fallback or microphone capture was started.")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else { throw RelayError.message("Voice permissions changed before capture could start.") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let sink = VoiceAudioSink(request: request)
        let engine = AVAudioEngine()
        self.engine = engine
        self.sink = sink
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { stop(); throw RelayError.message("No working microphone input format is available.") }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, _ in sink.append(buffer) }
        tapInstalled = true
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable result, error in
            // Convert framework objects to Sendable values before crossing to the UI actor.
            if let result {
                let text = result.bestTranscription.formattedString
                let final = result.isFinal
                Task { @MainActor in onEvent(final ? .final(text) : .partial(text)) }
            }
            if let error {
                let message = error.localizedDescription
                Task { @MainActor in onEvent(.failure(message)) }
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable _ in
            Task { @MainActor in onEvent(.interrupted) }
        }
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw error }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        sink?.endAudio(); sink = nil
        recognitionTask?.cancel(); recognitionTask = nil
        engine = nil
        recognizer = nil
    }

    func finish() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        sink?.endAudio()
        recognitionTask?.finish()
        engine = nil
    }
}

/// AVAudioEngine invokes its tap away from MainActor. Serialize append/endAudio so teardown
/// cannot append after the request has ended. No audio buffers are retained or persisted here.
nonisolated private final class VoiceAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var ended = false
    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { if !ended { request.append(buffer) } }
    }
    func endAudio() {
        lock.withLock {
            guard !ended else { return }
            ended = true
            request.endAudio()
        }
    }
}
