import AVFoundation
import AppKit
import Foundation
import Observation

@MainActor
protocol LocalSpeechOutputBackend: AnyObject {
    func availableVoices() -> [LocalSpeechOutput.VoiceInfo]
    func speak(text: String, voiceIdentifier: String,
               onEvent: @escaping @MainActor (LocalSpeechOutput.Event) -> Void) throws
    func stop()
}

/// Optional local playback of one explicitly selected assistant response. Never auto-speaks.
@Observable @MainActor
final class LocalSpeechOutput {
    nonisolated struct VoiceInfo: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let language: String
    }
    nonisolated enum Event: Sendable, Equatable { case started, finished, cancelled }

    var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled { stop(); status = "Read aloud is off." }
            else { status = "Read aloud is ready. Choose a response explicitly." }
        }
    }
    var selectedVoiceID: String? {
        didSet { if oldValue != selectedVoiceID, isActive { stop() } }
    }
    private(set) var availableVoices: [VoiceInfo] = []
    private(set) var isSpeaking = false
    private(set) var activeMessageID: UUID?
    var status = "Silent by default. Read aloud only starts when you choose a response."
    var errorMessage: String?
    var isActive: Bool { activeMessageID != nil }
    var isBusy: Bool { isActive }

    @ObservationIgnored private var backend: (any LocalSpeechOutputBackend)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let sleepNotificationCenter: NotificationCenter
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?

    init(backend: (any LocalSpeechOutputBackend)? = nil,
         sleepNotificationCenter: NotificationCenter? = nil) {
        self.backend = backend
        let sleepCenter = sleepNotificationCenter ?? NSWorkspace.shared.notificationCenter
        self.sleepNotificationCenter = sleepCenter
        // The .main notification queue allows synchronous cancellation before sleep rather
        // than scheduling a Task that could remain queued until the machine wakes again.
        sleepObserver = sleepCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.stop()
                self.status = "Read aloud stopped before sleep. Start it again explicitly when ready."
            }
        }
        // No speech, voice discovery, permission prompt or audio session starts here.
    }

    isolated deinit {
        if let sleepObserver { sleepNotificationCenter.removeObserver(sleepObserver) }
        backend?.stop()
    }

    /// Refresh uses only installed on-device Apple voices. It does not request voice downloads.
    func refreshVoices() {
        let voices = resolvedBackend().availableVoices().filter { $0.id.hasPrefix("com.apple.") }
        var seen = Set<String>()
        availableVoices = voices.filter { seen.insert($0.id).inserted }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if let selectedVoiceID, !availableVoices.contains(where: { $0.id == selectedVoiceID }) { self.selectedVoiceID = nil }
        if availableVoices.isEmpty { status = "No qualified on-device Apple speech voice is available. No download or hosted fallback was requested." }
    }

    @discardableResult
    func readAloud(_ response: ChatMessage) -> Bool {
        guard isEnabled else { errorMessage = "Enable local read aloud explicitly before starting playback."; return false }
        guard response.role == "assistant" else { errorMessage = "Choose an assistant response to read aloud."; return false }
        let text: String
        do { text = try Self.validatedText(response.text) }
        catch { errorMessage = error.localizedDescription; return false }
        refreshVoices()
        guard let selectedVoiceID, availableVoices.contains(where: { $0.id == selectedVoiceID }) else {
            errorMessage = "Choose an installed on-device voice. No automatic voice, download or hosted fallback will be used."
            return false
        }
        stop()
        errorMessage = nil
        generation += 1
        let expected = generation
        activeMessageID = response.id
        status = "Preparing the selected response for local read aloud…"
        do {
            try resolvedBackend().speak(text: text, voiceIdentifier: selectedVoiceID) { [weak self] event in
                guard let self, self.generation == expected, self.isEnabled,
                      self.activeMessageID == response.id else { return }
                switch event {
                case .started:
                    self.isSpeaking = true
                    self.status = "Reading the selected response aloud on this Mac."
                case .finished:
                    self.isSpeaking = false
                    self.activeMessageID = nil
                    self.status = "Read aloud finished."
                case .cancelled:
                    self.isSpeaking = false
                    self.activeMessageID = nil
                    self.status = "Local read aloud was cancelled."
                }
            }
            return true
        } catch {
            generation += 1
            // A backend can fail after allocating or starting its audio resources. Invalidate
            // callbacks first, then release audio even when playback never became ready.
            backend?.stop()
            activeMessageID = nil
            isSpeaking = false
            status = "Read aloud could not start."
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Stops queued or active audio immediately and invalidates late backend callbacks.
    func stop() {
        generation += 1
        backend?.stop()
        isSpeaking = false
        activeMessageID = nil
        status = isEnabled ? "Read aloud stopped." : "Read aloud is off."
    }

    nonisolated static func validatedText(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && !["\n", "\r", "\t"].contains(String($0))
        }) else { throw RelayError.message("Read aloud accepts ordinary response text without embedded control characters.") }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8000 else {
            throw RelayError.message("Choose a nonempty assistant response up to 8 KB for read aloud. Longer responses are not silently truncated.")
        }
        return value
    }

    nonisolated static func isQualifiedVoice(identifier: String, isPersonalVoice: Bool, isAvailableOnDevice: Bool) -> Bool {
        identifier.hasPrefix("com.apple.") && !isPersonalVoice && isAvailableOnDevice
    }

    private func resolvedBackend() -> any LocalSpeechOutputBackend {
        if let backend { return backend }
        let native = NativeSpeechOutputBackend()
        backend = native
        return native
    }
}

@MainActor
private final class NativeSpeechOutputBackend: LocalSpeechOutputBackend {
    private var synthesizer: AVSpeechSynthesizer?
    private var bridge: SpeechOutputDelegate?
    private var utteranceID: ObjectIdentifier?
    private var requestToken: UUID?
    private var handler: (@MainActor (LocalSpeechOutput.Event) -> Void)?

    init() {
        let delegate = SpeechOutputDelegate { [weak self] token, event in
            Task { @MainActor [weak self] in
                guard let self, self.requestToken == token else { return }
                self.handler?(event)
                if event == .finished || event == .cancelled {
                    self.utteranceID = nil; self.requestToken = nil; self.handler = nil
                }
            }
        }
        bridge = delegate
    }

    func availableVoices() -> [LocalSpeechOutput.VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().compactMap { candidate in
            // Do not resolve third-party or personal voice implementations at all.
            guard candidate.identifier.hasPrefix("com.apple."), !candidate.voiceTraits.contains(.isPersonalVoice) else { return nil }
            // Apple's documented identifier lookup returns nil when a voice is not downloaded.
            let installed = AVSpeechSynthesisVoice(identifier: candidate.identifier)
            guard LocalSpeechOutput.isQualifiedVoice(identifier: candidate.identifier,
                isPersonalVoice: false, isAvailableOnDevice: installed != nil) else { return nil }
            return .init(id: candidate.identifier, name: candidate.name, language: candidate.language)
        }
    }

    func speak(text: String, voiceIdentifier: String,
               onEvent: @escaping @MainActor (LocalSpeechOutput.Event) -> Void) throws {
        guard voiceIdentifier.hasPrefix("com.apple."), let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier),
              LocalSpeechOutput.isQualifiedVoice(identifier: voice.identifier,
                  isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice), isAvailableOnDevice: true) else {
            throw RelayError.message("The chosen Apple voice is unavailable on this device. No download or fallback was requested.")
        }
        stop()
        let utterance = AVSpeechUtterance(string: text) // Plain text only, never SSML or remote markup.
        utterance.voice = voice // Always explicit; never let the framework choose another voice.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let token = UUID()
        utteranceID = ObjectIdentifier(utterance)
        requestToken = token
        bridge?.register(utterance: utterance, token: token)
        handler = onEvent
        let engine: AVSpeechSynthesizer
        if let synthesizer { engine = synthesizer }
        else {
            engine = AVSpeechSynthesizer()
            engine.delegate = bridge
            synthesizer = engine
        }
        engine.speak(utterance)
    }

    func stop() {
        if let utteranceID { bridge?.unregister(utteranceID) }
        utteranceID = nil
        requestToken = nil
        handler = nil
        synthesizer?.stopSpeaking(at: .immediate)
    }
}

/// Delegate arguments stay on their callback thread; only a Sendable request token/event crosses actors.
/// The lock protects the identity-to-token map from concurrent delegate/Stop callbacks.
nonisolated private final class SpeechOutputDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let callback: @Sendable (UUID, LocalSpeechOutput.Event) -> Void
    private let lock = NSLock()
    private var tokens: [ObjectIdentifier: UUID] = [:]
    init(callback: @escaping @Sendable (UUID, LocalSpeechOutput.Event) -> Void) { self.callback = callback }
    func register(utterance: AVSpeechUtterance, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        tokens[ObjectIdentifier(utterance)] = token
    }
    func unregister(_ identity: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        tokens.removeValue(forKey: identity)
    }
    private func emit(_ utterance: AVSpeechUtterance, event: LocalSpeechOutput.Event) {
        lock.lock()
        let identity = ObjectIdentifier(utterance)
        let token = tokens[identity]
        if event == .finished || event == .cancelled { tokens.removeValue(forKey: identity) }
        lock.unlock()
        if let token { callback(token, event) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { emit(utterance, event: .started) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { emit(utterance, event: .finished) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { emit(utterance, event: .cancelled) }
}
