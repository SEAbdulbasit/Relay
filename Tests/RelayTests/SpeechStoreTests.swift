import Foundation
import Testing
@testable import Relay

@MainActor
struct SpeechStoreTests {
    private final class Backend: LocalSpeechOutputBackend {
        var calls = 0
        var stopped = 0
        var callback: (@MainActor (LocalSpeechOutput.Event) -> Void)?
        func availableVoices() -> [LocalSpeechOutput.VoiceInfo] {
            [.init(id: "com.apple.voice.fixture", name: "Fixture", language: "en-US")]
        }
        func speak(text: String, voiceIdentifier: String, onEvent: @escaping @MainActor (LocalSpeechOutput.Event) -> Void) throws {
            calls += 1; callback = onEvent; onEvent(.started)
        }
        func stop() { stopped += 1 }
    }
    private func ready(_ backend: Backend) -> LocalSpeechOutput {
        let speech = LocalSpeechOutput(backend: backend)
        speech.isEnabled = true
        speech.refreshVoices()
        speech.selectedVoiceID = "com.apple.voice.fixture"
        return speech
    }
    @Test func audioOnlyStopDoesNotInventAStoppedComputerTask() {
        let backend = Backend(), speech = ready(backend)
        let store = AssistantStore(persistenceURL: nil, speechOutput: speech)
        let response = ChatMessage(role: "assistant", text: "Chosen response")
        store.messages = [response]
        store.readAloud(response)
        #expect(speech.isSpeaking)
        store.stop()
        #expect(!speech.isActive)
        #expect(store.messages.count == 1)
        #expect(store.phase == .idle)
        backend.callback?(.started)
        #expect(!speech.isActive)
    }
    @Test func newRequestStopsAudioAndNewAnswerDoesNotAutoSpeak() async {
        let backend = Backend(), speech = ready(backend)
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in .init(content: "New response stays silent", toolCalls: []) }, speechOutput: speech)
        let response = ChatMessage(role: "assistant", text: "Old response")
        store.messages = [response]
        store.readAloud(response)
        #expect(backend.calls == 1)
        store.draft = "A new request"
        store.send()
        for _ in 0..<100 where store.isRunning { await Task.yield() }
        #expect(!speech.isActive)
        #expect(backend.calls == 1)
        #expect(store.phase == .idle)
        #expect(store.messages.last?.text.hasPrefix("New response stays silent") == true)
    }
    @Test func fabricatedOrChangedResponseCannotStartAudio() {
        let backend = Backend(), speech = ready(backend)
        let store = AssistantStore(persistenceURL: nil, speechOutput: speech)
        let response = ChatMessage(role: "assistant", text: "Original")
        store.readAloud(response)
        store.messages = [response]
        var changed = response; changed.text = "Changed payload"
        store.readAloud(changed)
        store.readAloud(ChatMessage(role: "user", text: "User input"))
        #expect(backend.calls == 0)
    }
    @Test func sourceInvalidationAlsoStopsDerivedResponseAudio() {
        let backend = Backend(), speech = ready(backend)
        let store = AssistantStore(persistenceURL: nil, speechOutput: speech)
        let response = ChatMessage(role: "assistant", text: "Derived source content")
        store.messages = [response]
        store.readAloud(response)
        #expect(speech.isActive)
        store.invalidateDerivedContext(reason: "Source removed")
        #expect(!speech.isActive)
        #expect(store.messages.count == 1)
        #expect(store.phase == .idle)
    }
    @Test func forgettingMemoryDropsEarlierDerivedInferenceContext() async {
        var turn = 0
        var freshInput = ""
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turn += 1
            if turn == 1 { return .init(content: "Synthetic old memory-derived secret", toolCalls: []) }
            freshInput = input.map(\.content).joined(separator: "\n")
            return .init(content: "Fresh answer", toolCalls: [])
        })
        store.addMemory("Synthetic old private preference")
        store.draft = "First request"; store.send()
        for _ in 0..<100 where store.isRunning { await Task.yield() }
        store.deleteMemory(store.memories[0].id)
        store.draft = "New request"; store.send()
        for _ in 0..<100 where store.isRunning { await Task.yield() }
        #expect(!freshInput.contains("old memory-derived secret"))
        #expect(!freshInput.contains("old private preference"))
        #expect(freshInput.contains("New request"))
        #expect(store.messages.contains { $0.text.contains("old memory-derived secret") })
    }
}
