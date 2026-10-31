import Foundation
import AppKit
import Testing
@testable import Relay

@MainActor
struct LocalSpeechOutputTests {
    private final class FakeBackend: LocalSpeechOutputBackend {
        var voices = [LocalSpeechOutput.VoiceInfo(id: "com.apple.voice.fixture", name: "Local fixture", language: "en-US")]
        var discoveryCount = 0
        var requests: [(text: String, voice: String)] = []
        var handlers: [@MainActor (LocalSpeechOutput.Event) -> Void] = []
        var stopCount = 0
        var fails = false
        var failsAfterStarting = false
        func availableVoices() -> [LocalSpeechOutput.VoiceInfo] { discoveryCount += 1; return voices }
        func speak(text: String, voiceIdentifier: String, onEvent: @escaping @MainActor (LocalSpeechOutput.Event) -> Void) throws {
            if fails { throw RelayError.message("Synthetic unavailable voice") }
            requests.append((text, voiceIdentifier)); handlers.append(onEvent)
            if failsAfterStarting {
                onEvent(.started)
                throw RelayError.message("Synthetic audio device failure after start")
            }
        }
        func stop() { stopCount += 1 }
    }
    private func ready(_ backend: FakeBackend) -> LocalSpeechOutput {
        let output = LocalSpeechOutput(backend: backend)
        output.isEnabled = true
        output.refreshVoices()
        output.selectedVoiceID = backend.voices.first?.id
        return output
    }

    @Test func defaultSilentControllerDoesNotDiscoverOrSpeak() {
        let backend = FakeBackend(), response = ChatMessage(role: "assistant", text: "Hello")
        let output = LocalSpeechOutput(backend: backend)
        #expect(!output.isEnabled)
        #expect(!output.isBusy)
        #expect(backend.discoveryCount == 0)
        #expect(backend.requests.isEmpty)
        #expect(!output.readAloud(response))
        #expect(backend.discoveryCount == 0)
        #expect(backend.requests.isEmpty)
    }

    @Test func explicitSelectedAssistantResponseUsesExplicitVoiceAndDelegateState() {
        let backend = FakeBackend(), output = ready(backend)
        let response = ChatMessage(role: "assistant", text: "مرحبا 🌍")
        #expect(output.readAloud(response))
        #expect(backend.requests.count == 1)
        #expect(backend.requests[0].text == "مرحبا 🌍")
        #expect(backend.requests[0].voice == "com.apple.voice.fixture")
        #expect(output.isBusy && !output.isSpeaking)
        backend.handlers[0](.started)
        #expect(output.isSpeaking)
        #expect(output.activeMessageID == response.id)
        backend.handlers[0](.finished)
        #expect(!output.isBusy && !output.isSpeaking)
    }

    @Test func stopAndDisableInvalidateLateCallbacksWithoutRestartingAudio() {
        let backend = FakeBackend(), output = ready(backend)
        #expect(output.readAloud(ChatMessage(role: "assistant", text: "First")))
        backend.handlers[0](.started)
        output.stop()
        #expect(!output.isBusy && !output.isSpeaking)
        backend.handlers[0](.started)
        #expect(!output.isBusy && !output.isSpeaking)
        #expect(output.readAloud(ChatMessage(role: "assistant", text: "Second")))
        backend.handlers[1](.started)
        backend.handlers[0](.finished)
        #expect(output.isSpeaking)
        output.isEnabled = false
        backend.handlers[1](.started)
        #expect(!output.isBusy && !output.isSpeaking)
        #expect(backend.requests.count == 2)
        #expect(backend.stopCount >= 2)
    }

    @Test func unavailableVoiceWrongRoleAndLargeTextNeverDispatch() {
        let backend = FakeBackend(), output = ready(backend)
        #expect(!output.readAloud(ChatMessage(role: "user", text: "Do not read user input")))
        #expect(!output.readAloud(ChatMessage(role: "assistant", text: String(repeating: "é", count: 4001))))
        output.selectedVoiceID = "com.apple.voice.notinstalled"
        #expect(!output.readAloud(ChatMessage(role: "assistant", text: "No fallback")))
        #expect(backend.requests.isEmpty)
        output.selectedVoiceID = "com.apple.voice.fixture"
        backend.fails = true
        #expect(!output.readAloud(ChatMessage(role: "assistant", text: "Synthetic failure")))
        #expect(!output.isBusy && !output.isSpeaking)
        #expect(output.errorMessage?.contains("Synthetic") == true)
    }

    @Test func qualificationExcludesMissingPersonalAndThirdPartyVoices() {
        #expect(LocalSpeechOutput.isQualifiedVoice(identifier: "com.apple.voice.compact.fixture", isPersonalVoice: false, isAvailableOnDevice: true))
        #expect(!LocalSpeechOutput.isQualifiedVoice(identifier: "com.apple.voice.compact.fixture", isPersonalVoice: false, isAvailableOnDevice: false))
        #expect(!LocalSpeechOutput.isQualifiedVoice(identifier: "com.apple.voice.personal.fixture", isPersonalVoice: true, isAvailableOnDevice: true))
        #expect(!LocalSpeechOutput.isQualifiedVoice(identifier: "third.party.networkvoice", isPersonalVoice: false, isAvailableOnDevice: true))
    }

    @Test func partialStartFailureStopsResourcesAndInvalidatesItsCallbacks() {
        let backend = FakeBackend(), output = ready(backend)
        backend.failsAfterStarting = true
        let stopsBefore = backend.stopCount
        #expect(!output.readAloud(ChatMessage(role: "assistant", text: "Synthetic playback")))
        #expect(backend.requests.count == 1)
        #expect(backend.stopCount == stopsBefore + 2) // Replace previous playback, then clean failed start.
        #expect(!output.isBusy && !output.isSpeaking)
        #expect(output.errorMessage?.contains("after start") == true)
        backend.handlers[0](.started)
        #expect(!output.isBusy && !output.isSpeaking)
        backend.failsAfterStarting = false
        #expect(output.readAloud(ChatMessage(role: "assistant", text: "Explicit retry")))
        backend.handlers[1](.started)
        backend.handlers[0](.cancelled)
        #expect(output.isBusy && output.isSpeaking)
        backend.handlers[1](.finished)
        #expect(!output.isBusy && !output.isSpeaking)
    }

    @Test func disappearingSelectedVoiceStopsPlaybackAndDoesNotChooseFallback() {
        let backend = FakeBackend(), output = ready(backend)
        #expect(output.readAloud(ChatMessage(role: "assistant", text: "Selected voice")))
        backend.handlers[0](.started)
        backend.voices = [.init(id: "com.apple.voice.other", name: "Other", language: "en-US")]
        output.refreshVoices()
        #expect(output.selectedVoiceID == nil)
        #expect(!output.isBusy && !output.isSpeaking)
        #expect(!output.readAloud(ChatMessage(role: "assistant", text: "No fallback")))
        #expect(backend.requests.count == 1)
        backend.handlers[0](.started)
        #expect(!output.isBusy)
    }

    @Test func sleepNotificationStopsAudioSynchronouslyAndInvalidatesLateCallbacks() {
        let backend = FakeBackend(), notifications = NotificationCenter()
        let output = LocalSpeechOutput(backend: backend, sleepNotificationCenter: notifications)
        output.isEnabled = true
        output.refreshVoices()
        output.selectedVoiceID = "com.apple.voice.fixture"
        #expect(output.readAloud(ChatMessage(role: "assistant", text: "Synthetic local speech")))
        backend.handlers[0](.started)
        #expect(output.isSpeaking)
        let stopsBefore = backend.stopCount
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        // No actor yield: teardown must complete before notification delivery returns.
        #expect(backend.stopCount == stopsBefore + 1)
        #expect(!output.isBusy && !output.isSpeaking)
        #expect(output.status.contains("before sleep"))
        backend.handlers[0](.started)
        backend.handlers[0](.finished)
        #expect(!output.isBusy && !output.isSpeaking)
        #expect(output.status.contains("before sleep"))
        #expect(backend.requests.count == 1)
    }

    @Test func boundedOrdinaryTextIsNeverSilentlyTruncatedOrParsedAsMarkup() throws {
        #expect(try LocalSpeechOutput.validatedText("  Hello\nworld 🌍  ") == "Hello\nworld 🌍")
        #expect(try LocalSpeechOutput.validatedText("<speak>Literal text</speak>") == "<speak>Literal text</speak>")
        for text in ["", "  \n", "Hello\u{0}", String(repeating: "a", count: 8001)] {
            #expect(throws: (any Error).self) { try LocalSpeechOutput.validatedText(text) }
        }
    }
}
