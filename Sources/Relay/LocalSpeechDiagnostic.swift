import AppKit
@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation
import Observation

nonisolated enum LocalSpeechDiagnosticPermissionState: Sendable, Equatable {
    case notDetermined, denied, restricted, authorized, unknown
    init(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .authorized: self = .authorized
        @unknown default: self = .unknown
        }
    }
    var label: String {
        switch self {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        case .unknown: "unknown"
        }
    }
}

nonisolated enum LocalSpeechDiagnosticFailure: Error, Sendable {
    case permission(LocalSpeechDiagnosticPermissionState)
    case localRecognition, installedVoice, audioFormat, recognition, renderLimit, timedOut
    var message: String {
        switch self {
        case .permission(let state): "Speech permission is \(state.label) for this app process. This check does not request permission or record a microphone."
        case .localRecognition: "On-device English recognition is unavailable on this Mac. No hosted fallback was used."
        case .installedVoice: "No installed, nonpersonal English Apple voice is available. No voice download was requested."
        case .audioFormat: "The generated speech had an unsupported audio format. The local check stopped."
        case .recognition: "The local speech recognizer could not complete the synthetic check. No microphone was used."
        case .renderLimit: "The generated speech exceeded the local check’s audio limit. The check stopped."
        case .timedOut: "The local speech check reached its time limit. No microphone was used."
        }
    }
}
nonisolated enum LocalSpeechDiagnosticEvent: Sendable {
    case rendered(frames: Int)
    case recognized(String, final: Bool)
    case failure(LocalSpeechDiagnosticFailure)
}

@MainActor
protocol LocalSpeechDiagnosticBackend: AnyObject {
    var renderedFrames: Int { get }
    func begin(onEvent: @escaping @MainActor @Sendable (LocalSpeechDiagnosticEvent) -> Void) throws
    func stop()
}

/// Explicit synthetic asset check with a separate Speech-consent action. The check never
/// captures microphone input, speaks through a speaker, requests permission, saves audio
/// or retains recognition text in observable state. Consent alone cannot start the check.
@Observable @MainActor
final class LocalSpeechDiagnostic {
    nonisolated static let phrase = "Local voice check one two three"
    nonisolated static let maximumFrames = 4_000_000
    enum Phase: Equatable { case idle, authorizing, checking, passed, failed, stopped }
    private(set) var phase: Phase = .idle
    private(set) var status = "Check local speech support using generated audio. No microphone or speaker is used."
    private(set) var audioFrames = 0
    private(set) var elapsedSeconds: Double?
    var isBusy: Bool { phase == .checking || phase == .authorizing }
    let maximumDuration: TimeInterval

    @ObservationIgnored private var backend: (any LocalSpeechDiagnosticBackend)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var authorization: Task<Void, Never>?
    @ObservationIgnored private let authorize: @Sendable () async -> LocalSpeechDiagnosticPermissionState
    @ObservationIgnored private var started: ContinuousClock.Instant?
    @ObservationIgnored private let sleepNotificationCenter: NotificationCenter
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?

    init(backend: (any LocalSpeechDiagnosticBackend)? = nil, maximumDuration: TimeInterval = 20,
         authorize: (@Sendable () async -> LocalSpeechDiagnosticPermissionState)? = nil,
         sleepNotificationCenter: NotificationCenter? = nil) {
        self.backend = backend
        self.maximumDuration = maximumDuration.isFinite ? min(20, max(0.05, maximumDuration)) : 20
        self.authorize = authorize ?? { await Self.requestSpeechAuthorization() }
        let center = sleepNotificationCenter ?? NSWorkspace.shared.notificationCenter
        self.sleepNotificationCenter = center
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        // Native framework objects and speech assets are not inspected at initialization.
    }

    /// This separate explicit action may show macOS consent. It never starts the
    /// synthetic check, microphone capture or playback, even after successful approval.
    func recheckSpeechAccess() {
        guard !isBusy else { return }
        generation += 1
        let expected = generation
        phase = .authorizing
        status = "Waiting for macOS Speech access. A permission prompt may appear. No microphone or speech check will start automatically."
        audioFrames = 0
        elapsedSeconds = nil
        started = nil
        let authorize = self.authorize
        authorization = Task { [weak self] in
            let state = await authorize()
            guard !Task.isCancelled, let self, self.generation == expected, self.phase == .authorizing else { return }
            self.finish(state == .authorized ? .idle : .failed,
                "Speech access is \(state.label) for this app process. No microphone was opened and no speech check was started. Run the local speech check separately when access is authorized.")
        }
    }

    func start() {
        guard !isBusy else { return }
        generation += 1
        let expected = generation
        phase = .checking
        audioFrames = 0
        elapsedSeconds = nil
        started = .now
        status = "Checking generated English speech with on-device recognition…"
        let finishBy = ContinuousClock.now.advanced(by: .seconds(maximumDuration))
        do {
            try resolvedBackend().begin { [weak self] event in self?.receive(event, generation: expected) }
            guard generation == expected, isBusy else { return }
            if ContinuousClock.now >= finishBy { finish(.failed, LocalSpeechDiagnosticFailure.timedOut.message); return }
            deadline = Task { [weak self] in
                do { try await Task.sleep(until: finishBy, clock: .continuous) }
                catch { return }
                guard let self, self.generation == expected, self.isBusy else { return }
                self.finish(.failed, LocalSpeechDiagnosticFailure.timedOut.message)
            }
        } catch let failure as LocalSpeechDiagnosticFailure {
            guard generation == expected else { return }
            finish(.failed, failure.message)
        } catch {
            guard generation == expected else { return }
            finish(.failed, "The local synthetic speech check could not start. No microphone or speaker was used.")
        }
    }

    func stop() {
        guard isBusy else { return }
        finish(.stopped, phase == .authorizing
            ? "Speech access recheck canceled in Relay. A macOS prompt may remain; completing it will not start a speech check or microphone."
            : "Local speech check stopped. No microphone recording or speaker playback was used.")
    }

    /// Await the currently owned check deadline (or its cancellation after completion).
    /// Capturing the handle prevents a later retry from extending a caller's wait.
    func waitForCurrentCheck() async {
        let pending = deadline
        await pending?.value
    }

    func waitForSpeechAccessRecheck() async {
        let pending = authorization
        await pending?.value
    }

    private func receive(_ event: LocalSpeechDiagnosticEvent, generation expected: Int) {
        guard generation == expected, isBusy else { return }
        switch event {
        case .rendered(let frames):
            guard frames >= 0, frames <= Self.maximumFrames, frames >= audioFrames else {
                finish(.failed, LocalSpeechDiagnosticFailure.renderLimit.message); return
            }
            audioFrames = frames
        case .recognized(let text, let final):
            guard final else { return }
            let matches = Self.matchesExpectedPhrase(text)
            let frames = max(audioFrames, backend?.renderedFrames ?? 0)
            guard frames > 0, frames <= Self.maximumFrames else {
                finish(.failed, LocalSpeechDiagnosticFailure.renderLimit.message); return
            }
            finish(matches ? .passed : .failed, matches
                ? "Local speech check passed: on-device recognition matched the generated phrase. Microphone, speaker and offline behavior were not tested."
                : "The recognizer finished, but did not match the generated phrase. Recognition text was discarded. Microphone and speaker were not tested.")
        case .failure(let failure): finish(.failed, failure.message)
        }
    }

    private func finish(_ next: Phase, _ message: String) {
        let wasChecking = phase == .checking
        generation += 1 // Invalidate native callbacks before cancellation can emit more events.
        deadline?.cancel(); deadline = nil
        // Keep the canceled handle until a later explicit recheck replaces it, so QA
        // can await late OS consent delivery without guessing callback timing.
        authorization?.cancel()
        backend?.stop()
        if wasChecking {
            audioFrames = min(Self.maximumFrames, max(audioFrames, max(0, backend?.renderedFrames ?? 0)))
        }
        if let started {
            let parts = started.duration(to: .now).components
            elapsedSeconds = max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
        started = nil
        phase = next
        status = message
    }

    nonisolated static func matchesExpectedPhrase(_ text: String) -> Bool {
        guard text.utf8.count <= 512,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let expanded = words.flatMap { word -> [String] in
            switch word {
            case "1": ["one"]
            case "2": ["two"]
            case "3": ["three"]
            case "123": ["one", "two", "three"]
            default: [word]
            }
        }
        return expanded == ["local", "voice", "check", "one", "two", "three"]
    }

    private func resolvedBackend() -> any LocalSpeechDiagnosticBackend {
        if let backend { return backend }
        let native = NativeLocalSpeechDiagnosticBackend()
        backend = native
        return native
    }

    nonisolated private static func requestSpeechAuthorization() async -> LocalSpeechDiagnosticPermissionState {
        let raw = await LocalVoiceAuthorizationBridge.status { @Sendable reply in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in reply(status.rawValue) }
        }
        guard let status = SFSpeechRecognizerAuthorizationStatus(rawValue: raw) else { return .unknown }
        return LocalSpeechDiagnosticPermissionState(status)
    }

    isolated deinit {
        deadline?.cancel()
        authorization?.cancel()
        backend?.stop()
        if let sleepObserver { sleepNotificationCenter.removeObserver(sleepObserver) }
    }
}

@MainActor
private final class NativeLocalSpeechDiagnosticBackend: LocalSpeechDiagnosticBackend {
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var synthesizer: AVSpeechSynthesizer?
    private var sink: DiagnosticAudioSink?
    private var retainedFrameCount = 0
    var renderedFrames: Int { max(retainedFrameCount, sink?.frameCount ?? 0) }

    func begin(onEvent: @escaping @MainActor @Sendable (LocalSpeechDiagnosticEvent) -> Void) throws {
        stop()
        retainedFrameCount = 0
        // Initialize the same client used by dictation before querying current consent.
        // This creates no recognition task or authorization request. The fixed state in
        // the result diagnoses OS authorization; initializer order is not a consent fix.
        let candidate = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let permission = LocalSpeechDiagnosticPermissionState(SFSpeechRecognizer.authorizationStatus())
        guard permission == .authorized else { throw LocalSpeechDiagnosticFailure.permission(permission) }
        guard let recognizer = candidate,
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw LocalSpeechDiagnosticFailure.localRecognition }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.identifier.hasPrefix("com.apple.") && !$0.voiceTraits.contains(.isPersonalVoice) && $0.language.lowercased().hasPrefix("en")
        }.sorted {
            let leftMatches = $0.language.replacingOccurrences(of: "_", with: "-").lowercased() == "en-us"
            let rightMatches = $1.language.replacingOccurrences(of: "_", with: "-").lowercased() == "en-us"
            return leftMatches != rightMatches ? leftMatches : $0.identifier < $1.identifier
        }
        guard let candidate = candidates.first,
              let voice = AVSpeechSynthesisVoice(identifier: candidate.identifier),
              !voice.voiceTraits.contains(.isPersonalVoice) else { throw LocalSpeechDiagnosticFailure.installedVoice }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        let deliver: @Sendable (LocalSpeechDiagnosticEvent) -> Void = { @Sendable event in
            Task { @MainActor in onEvent(event) }
        }
        let sink = DiagnosticAudioSink(request: request, report: deliver)
        self.sink = sink
        self.recognizer = recognizer
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable result, error in
            if let result { deliver(.recognized(result.bestTranscription.formattedString, final: result.isFinal)) }
            if error != nil { deliver(.failure(.recognition)) }
        }
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: LocalSpeechDiagnostic.phrase)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.write(utterance) { @Sendable buffer in sink.append(buffer) }
    }

    func stop() {
        sink?.endAudio()
        retainedFrameCount = max(retainedFrameCount, sink?.frameCount ?? 0)
        sink = nil
        recognitionTask?.cancel(); recognitionTask = nil
        synthesizer?.stopSpeaking(at: .immediate); synthesizer = nil
        recognizer = nil
    }
}

/// Native generated PCM is appended immediately, never retained or written. Teardown and
/// appends share one lock, ensuring endAudio occurs once and no append follows it.
nonisolated private final class DiagnosticAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let report: @Sendable (LocalSpeechDiagnosticEvent) -> Void
    private var ended = false
    private var frames = 0
    var frameCount: Int { lock.withLock { frames } }
    init(request: SFSpeechAudioBufferRecognitionRequest, report: @escaping @Sendable (LocalSpeechDiagnosticEvent) -> Void) {
        self.request = request; self.report = report
    }
    func append(_ audio: AVAudioBuffer) {
        let event: LocalSpeechDiagnosticEvent? = lock.withLock {
            guard !ended else { return nil }
            guard let buffer = audio as? AVAudioPCMBuffer else { finishLocked(); return .failure(.audioFormat) }
            let count = Int(buffer.frameLength)
            guard count > 0 else { finishLocked(); return nil }
            guard buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
                  (1...8).contains(Int(buffer.format.channelCount)), count <= LocalSpeechDiagnostic.maximumFrames - frames else {
                finishLocked(); return .failure(.renderLimit)
            }
            frames += count
            request.append(buffer)
            return .rendered(frames: frames)
        }
        if let event { report(event) }
    }
    func endAudio() { lock.withLock { finishLocked() } }
    private func finishLocked() {
        guard !ended else { return }
        ended = true
        request.endAudio()
    }
}
