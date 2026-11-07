import Foundation
import Testing
@testable import Relay

@MainActor
struct QuickTextStoreIntegrationTests {
    @Test func selectionActionsUseNoToolsOrChatHistoryAndNeverPersistTheirText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-selected-text-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appending(path: "state.json")
        let selected = "This are a synthetic sentnce."
        let corrected = "This is a synthetic sentence."
        let fullValue = "UNSELECTED_PREFIX_MUST_STAY_LOCAL " + selected + " UNSELECTED_SUFFIX_MUST_STAY_LOCAL"
        let range = (fullValue as NSString).range(of: selected)
        var inferenceCount = 0
        let store = AssistantStore(persistenceURL: stateURL, complete: { messages, tools, _ in
            inferenceCount += 1
            #expect(tools.isEmpty)
            let input = messages.map(\.content).joined(separator: "\n")
            #expect(input.contains(selected))
            #expect(!input.contains("UNSELECTED_PREFIX_MUST_STAY_LOCAL"))
            #expect(!input.contains("UNSELECTED_SUFFIX_MUST_STAY_LOCAL"))
            return ModelReply(content: "{\"corrected_text\":\"\(corrected)\"}", toolCalls: [])
        }, execute: { _ in
            Issue.record("Selected-text inference must not dispatch a computer tool.")
            throw CancellationError()
        }, codexComplete: { _, _ in
            Issue.record("A private selected-text action must use the local model path.")
            throw CancellationError()
        })
        let state = BoundTextSelection.State(processID: 123, launchedAt: Date(), bundleID: "dev.relay.synthetic",
            sourceAppName: "Synthetic editor", windowTitle: "Synthetic selection", windowIdentity: "window", editorIdentity: "editor",
            fullValue: fullValue, range: range, selectedText: selected, enabled: true, writable: false, formattingSafe: false, secure: false)
        let selection = try BoundTextSelection(state: state, readCurrent: { state }, writeSelection: { _ in
            Issue.record("Generating a correction must not change a field.")
        })
        try store.quickText.start(kind: .proofread, selection: selection)
        for _ in 0..<100 where store.quickText.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.quickText.isBusy)
        #expect(store.quickText.resultText == corrected)
        #expect(inferenceCount == 1)
        #expect(store.messages.isEmpty)
        #expect(store.activity.isEmpty)
        store.saveConfiguration()
        let saved = try String(contentsOf: stateURL, encoding: .utf8)
        #expect(!saved.contains(selected))
        #expect(!saved.contains(corrected))
        #expect(!saved.contains("UNSELECTED_"))
        store.stop()
        #expect(store.quickText.sourceText.isEmpty)
        #expect(store.quickText.resultText.isEmpty)
        #expect(store.messages.isEmpty)
    }
}
