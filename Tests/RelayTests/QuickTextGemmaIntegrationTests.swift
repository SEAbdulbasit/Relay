import Foundation
import Testing
@testable import Relay

/// Explicit, synthetic CPU qualification. No native editor, tool or file write
/// receives the model result; this exercises the production session prompt/parser.
@MainActor
struct QuickTextGemmaIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"] != nil), .timeLimit(.minutes(5)))
    func actualGemmaProofreadsSelectedTextWithStrictJSONParagraphsAndUnicode() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"])
        let configuration = ModelConfiguration(modelPath: path, computeBackend: "cpu", model: "Gemma 4 E2B")
        let client = LocalModelClient()
        defer { client.unload() }
        let original = "Ths is a synthetc sentnce.\n\nCafé 🌍."
        let expected = "This is a synthetic sentence.\n\nCafé 🌍."
        let state = BoundTextSelection.State(processID: 4242, launchedAt: Date(timeIntervalSince1970: 1),
            bundleID: "test.synthetic.editor", sourceAppName: "Synthetic Editor", windowTitle: "Synthetic selection",
            windowIdentity: "fixture-window", editorIdentity: "fixture-editor", fullValue: original,
            range: NSRange(location: 0, length: original.utf16.count), selectedText: original,
            enabled: true, writable: false, formattingSafe: true, secure: false)
        let selection = try BoundTextSelection(state: state, readCurrent: { state }, writeSelection: { _ in
            Issue.record("Real-model qualification must never dispatch a native edit.")
        })
        var modelCalls = 0
        var syntheticResponse = ""
        let session = QuickTextActionSession(generate: { messages in
            modelCalls += 1
            let reply = try await client.complete(messages: messages, tools: [], configuration: configuration)
            syntheticResponse = reply.content
            #expect(reply.toolCalls.isEmpty)
            return reply
        })
        let started = ContinuousClock.now
        try session.start(kind: .proofread, selection: selection)
        let deadline = started.advanced(by: .seconds(185))
        while session.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!session.isBusy)
        if session.phase != .ready { print("Synthetic proofreading response: \(syntheticResponse.debugDescription)") }
        #expect(session.phase == .ready, "The real local model must produce complete strict correction JSON.")
        #expect(session.resultText.utf16.elementsEqual(expected.utf16))
        #expect(modelCalls == 1)
        #expect(!session.canReplace)
        session.close()
        #expect(session.sourceText.isEmpty && session.resultText.isEmpty && selection.selectedText.isEmpty)
        let elapsed = started.duration(to: .now).components
        print("Synthetic QuickText proofreading: CPU, one tool-free generation, \(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) seconds. No native edit dispatched.")
    }
}
