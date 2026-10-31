import Testing
@testable import Relay

@MainActor
private final class StoreVoiceBackend: LocalVoiceBackend {
    var callback: (@MainActor @Sendable (LocalSpeechEvent) -> Void)?
    var stops = 0
    func capability(localeIdentifier: String) -> LocalVoiceCapability { .init(localeSupported: true, onDeviceSupported: true) }
    func requestPermissions() async throws {}
    func begin(localeIdentifier: String, requiresOnDeviceRecognition: Bool, onEvent: @escaping @MainActor @Sendable (LocalSpeechEvent) -> Void) throws { callback = onEvent }
    func stop() { stops += 1 }
}
@MainActor
struct VoiceStoreTests {
    @Test func taskStopAlsoStopsVoiceWhenNoModelTaskIsRunning() async {
        let backend = StoreVoiceBackend()
        let voice = LocalVoiceInput(localeIdentifier: "en-US", backend: backend)
        let store = AssistantStore(persistenceURL: nil, voiceInput: voice)
        await voice.start()
        #expect(voice.isRecording)
        #expect(!store.isRunning)
        store.stop()
        #expect(!voice.isBusy)
        #expect(backend.stops > 0)
        #expect(voice.transcript.isEmpty)
    }
    @Test func recordingBlocksSendAndExplicitTranscriptUsePreservesDraft() async {
        var modelCalls = 0
        let backend = StoreVoiceBackend()
        let voice = LocalVoiceInput(localeIdentifier: "en-US", backend: backend)
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in modelCalls += 1; return .init(content: "Unexpected", toolCalls: []) }, voiceInput: voice)
        store.draft = "Keep this exact draft 🌍"
        await voice.start()
        store.send()
        #expect(store.draft == "Keep this exact draft 🌍")
        #expect(modelCalls == 0)
        #expect(!store.useVoiceTranscript())
        backend.callback?(.final("Add this dictation"))
        #expect(store.useVoiceTranscript())
        #expect(store.draft == "Keep this exact draft 🌍\n\nAdd this dictation")
        #expect(modelCalls == 0)
        #expect(voice.transcript.isEmpty)
    }
}
