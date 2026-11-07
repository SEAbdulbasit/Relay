import Foundation
import AppKit
import Testing
@testable import Relay

@MainActor
private final class SyntheticBoundEditor {
    var value: String
    var range: NSRange
    var processID: Int32 = 4242
    var bundleID = "test.synthetic.editor"
    var webContent = false
    var launchedAt = Date(timeIntervalSince1970: 1)
    var windowID = "original-window"
    var editorID = "original-editor"
    var enabled = true
    var writable = true
    var formattingSafe = true
    var secure = false
    var omitFullValue = false
    var writeFails = false
    var readbackFails = false
    var cancelDuringWrite = false
    var corruptReadback = false
    var driftImmediatelyBeforeWrite = false
    private(set) var writeInvocations = 0
    private(set) var writes: [String] = []

    init(value: String = "Private outside. teh selected sentence. Untouched tail.", selected: String = "teh selected sentence.") {
        self.value = value
        self.range = (value as NSString).range(of: selected)
    }

    var state: BoundTextSelection.State {
        let selected = Range(range, in: value).map { String(value[$0]) } ?? ""
        return .init(processID: processID, launchedAt: launchedAt, bundleID: bundleID,
            sourceAppName: "Synthetic Editor", windowTitle: "Disposable text", windowIdentity: windowID, editorIdentity: editorID,
            fullValue: omitFullValue ? nil : value, range: range, selectedText: selected,
            enabled: enabled, writable: writable, formattingSafe: formattingSafe, secure: secure, webContent: webContent)
    }

    func binding() throws -> BoundTextSelection {
        let expected = state
        return try BoundTextSelection(state: expected, readCurrent: { [self] in
            if readbackFails, !writes.isEmpty { throw RelayError.message("Synthetic readback unavailable") }
            return state
        }, writeSelection: { [self] text in
            writeInvocations += 1
            if driftImmediatelyBeforeWrite { range = NSRange(location: range.location + 1, length: range.length - 1) }
            try BoundTextSelection.requireReplacementState(expected: expected, current: state)
            writes.append(text)
            if writeFails { throw RelayError.message("Synthetic uncertain write") }
            if let indices = Range(range, in: value) { value.replaceSubrange(indices, with: text) }
            range = NSRange(location: range.location + text.utf16.count, length: 0)
            if corruptReadback { value += "Unexpected extra text" }
            if cancelDuringWrite { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
}

@MainActor
struct BoundTextSelectionTests {
    @Test func reviewedReplacementUsesUTF16OffsetsAndPreservesLiteralDecomposedTextOutsideSelection() throws {
        let editor = SyntheticBoundEditor(value: "🌍 Cafe\u{301} — teh selected sentence. tail 🌍", selected: "teh selected sentence.")
        let target = try editor.binding()
        #expect(target.canReplace)
        #expect(try target.replaceReviewed(with: "the selected sentence.") == .replaced)
        #expect(editor.value.utf16.elementsEqual("🌍 Cafe\u{301} — the selected sentence. tail 🌍".utf16))
        #expect(editor.writes == ["the selected sentence."])
        #expect(!target.canReplace)
        guard case .copyOnly = try target.replaceReviewed(with: "another edit") else { Issue.record("A binding must not dispatch twice"); return }
        #expect(editor.writes.count == 1)
    }

    @Test(arguments: ["value", "canonical", "range", "window", "editor", "process", "launch", "disabled", "readonly", "formatting", "secure"])
    func driftRequiresCopyAndCannotDispatch(change: String) throws {
        let editor = SyntheticBoundEditor(value: "Cafe\u{301} — teh selected sentence.", selected: "teh selected sentence.")
        let target = try editor.binding()
        switch change {
        case "value": editor.value += " A new edit."
        case "canonical": editor.value = editor.value.precomposedStringWithCanonicalMapping
        case "range": editor.range = NSRange(location: editor.range.location + 1, length: editor.range.length - 1)
        case "window": editor.windowID = "another-window"
        case "editor": editor.editorID = "another-editor"
        case "process": editor.processID += 1
        case "launch": editor.launchedAt.addTimeInterval(1)
        case "disabled": editor.enabled = false
        case "readonly": editor.writable = false
        case "formatting": editor.formattingSafe = false
        case "secure": editor.secure = true
        default: Issue.record("Unknown synthetic change")
        }
        guard case .copyOnly = try target.replaceReviewed(with: "the selected sentence.") else { Issue.record("Changed target must be copy-only"); return }
        #expect(editor.writes.isEmpty)
    }

    @Test(arguments: ["readonly", "formatting", "unbounded"])
    func unsupportedEditorsStillExposeTheSelectionForCopyOnlyWorkflows(kind: String) throws {
        let editor = SyntheticBoundEditor()
        if kind == "readonly" { editor.writable = false }
        if kind == "formatting" { editor.formattingSafe = false }
        if kind == "unbounded" { editor.omitFullValue = true }
        let target = try editor.binding()
        #expect(target.selectedText == "teh selected sentence.")
        #expect(!target.canReplace)
        guard case .copyOnly = try target.replaceReviewed(with: "the selected sentence.") else { Issue.record("Unsupported editor must be copy-only"); return }
        #expect(editor.writes.isEmpty)
    }

    @Test(arguments: ["write", "readback", "corrupt", "cancel"])
    func uncertainWriteIsNeverRepeated(failure: String) async throws {
        let editor = SyntheticBoundEditor()
        editor.writeFails = failure == "write"
        editor.readbackFails = failure == "readback"
        editor.corruptReadback = failure == "corrupt"
        editor.cancelDuringWrite = failure == "cancel"
        let target = try editor.binding()
        let operation = Task { try target.replaceReviewed(with: "the selected sentence.") }
        guard case .uncertain = try await operation.value else { Issue.record("An unconfirmed write must remain uncertain"); return }
        guard case .copyOnly = try target.replaceReviewed(with: "the selected sentence.") else { Issue.record("An uncertain write must not be replayed"); return }
        #expect(editor.writes.count == 1)
    }

    @Test func cancellationBeforeWriteAndUnchangedTextDispatchNothing() async throws {
        let editor = SyntheticBoundEditor()
        let target = try editor.binding()
        #expect(try target.replaceReviewed(with: target.selectedText) == .unchanged)
        let operation = Task { try target.replaceReviewed(with: "the selected sentence.") }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(editor.writes.isEmpty)
        target.clear()
        #expect(target.selectedText.isEmpty)
        #expect(target.sourceAppName.isEmpty)
        #expect(!target.canReplace)
    }

    @Test(arguments: ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.dia", "web-area"])
    func browserOrEmbeddedWebSelectionsRemainCopyOnly(origin: String) throws {
        let editor = SyntheticBoundEditor()
        if origin == "web-area" { editor.webContent = true }
        else { editor.bundleID = origin }
        let target = try editor.binding()
        #expect(!target.canReplace)
        #expect(!target.selectedText.isEmpty)
        guard case .copyOnly = try target.replaceReviewed(with: "the selected sentence.") else { Issue.record("Unbound web origin must remain copy-only"); return }
        #expect(editor.writes.isEmpty)
    }

    @Test(arguments: ["AXLink", "AXAttachment", "NSLink", "NSAttachment"])
    func linkedAndAttachedAttributedSelectionsAreNeverReplaceable(attribute: String) {
        let text = NSAttributedString(string: "Uniform attributed selection", attributes: [.init(attribute): "Synthetic semantic value"])
        #expect(!BoundTextSelection.replacementFormattingIsSafe(text, selected: text.string))
    }

    @Test func mixedFormattingAndFinalPrewriteDriftCannotDispatch() throws {
        let mixed = NSMutableAttributedString(string: "Mixed text", attributes: [.init("AXFont"): "First"])
        mixed.addAttribute(.init("AXFont"), value: "Second", range: NSRange(location: 6, length: 4))
        #expect(!BoundTextSelection.replacementFormattingIsSafe(mixed, selected: mixed.string))
        let plain = NSAttributedString(string: "Uniform text", attributes: [.init("AXFont"): "First"])
        #expect(BoundTextSelection.replacementFormattingIsSafe(plain, selected: plain.string))
        let editor = SyntheticBoundEditor()
        let target = try editor.binding()
        editor.driftImmediatelyBeforeWrite = true
        guard case .uncertain = try target.replaceReviewed(with: "the selected sentence.") else { Issue.record("A consumed prewrite guard failure must not be retried"); return }
        #expect(editor.writeInvocations == 1 && editor.writes.isEmpty)
        guard case .copyOnly = try target.replaceReviewed(with: "the selected sentence.") else { Issue.record("A consumed target must not retry"); return }
        #expect(editor.writeInvocations == 1 && editor.writes.isEmpty)
    }

    @Test func replacementThatWouldExceedWholeFieldReadbackLimitDispatchesNothing() throws {
        let editor = SyntheticBoundEditor(value: String(repeating: "x", count: 15_990) + "teh", selected: "teh")
        let target = try editor.binding()
        #expect(target.canReplace)
        guard case .copyOnly = try target.replaceReviewed(with: "the corrected selected words") else { Issue.record("Known unbounded readback must be copy-only"); return }
        #expect(editor.writeInvocations == 0 && editor.writes.isEmpty)
    }
}

@MainActor
struct QuickTextActionSessionTests {
    @Test(arguments: [QuickTextActionSession.Kind.summarize, .proofread])
    func inferenceSeesOnlySelectionAndReplacementRequiresSeparateReviewedCall(kind: QuickTextActionSession.Kind) async throws {
        let editor = SyntheticBoundEditor()
        let target = try editor.binding()
        var inputs: [[ModelMessage]] = []
        let session = QuickTextActionSession(generate: { messages in
            inputs.append(messages)
            #expect(messages.count == 2)
            #expect(messages.last?.content.contains("teh selected sentence.") == true)
            #expect(messages.allSatisfy { !$0.content.contains("Private outside") && !$0.content.contains("Untouched tail") })
            return ModelReply(content: kind == .proofread ? "{\"corrected_text\":\"the selected sentence.\"}" : "One selected sentence.", toolCalls: [])
        })
        try session.start(kind: kind, selection: target)
        await settle(session)
        #expect(session.phase == .ready)
        #expect(inputs.count == 1)
        #expect(editor.writes.isEmpty)
        #expect(session.canReplace == (kind == .proofread))
        if kind == .proofread {
            #expect(try session.replaceReviewedSelection() == .replaced)
            #expect(editor.writes == ["the selected sentence."])
            #expect(throws: RelayError.self) { try session.replaceReviewedSelection() }
        } else {
            #expect(throws: RelayError.self) { try session.replaceReviewedSelection() }
        }
        session.close()
        #expect(session.phase == .closed)
        #expect(session.sourceText.isEmpty && session.resultText.isEmpty && session.sourceAppName.isEmpty && session.windowTitle.isEmpty)
        #expect(target.selectedText.isEmpty)
    }

    @Test(arguments: ["{\"corrected_text\":\"the sentence\",\"extra\":true}",
                      "{\"corrected_text\":\"first\",\"corrected_text\":\"second\"}",
                      "{\"corrected_text\":\"unterminated", "{\"corrected_text\":12}",
                      "```json\n{\"corrected_text\":\"the sentence\"}\n```", "I cannot correct this.",
                      "{\"corrected_text\":\"the sentence\"} additional text", "{\"corrected_text\":\"one line\"}"])
    func malformedOrStructurallyChangedCorrectionCannotBecomeReplaceable(response: String) async throws {
        let editor = SyntheticBoundEditor(value: "teh sentence\nsecond line", selected: "teh sentence\nsecond line")
        let session = QuickTextActionSession(generate: { _ in ModelReply(content: response, toolCalls: []) })
        try session.start(kind: .proofread, selection: editor.binding())
        await settle(session)
        #expect(session.phase == .failed)
        #expect(session.resultText.isEmpty && !session.canReplace)
        #expect(editor.writes.isEmpty)
        #expect(throws: RelayError.self) { try session.replaceReviewedSelection() }
    }

    @Test func correctionRestoresBoundaryWhitespaceAndPreservesLineEndingSequence() throws {
        let original = "  teh first\r\nsecond line\n  "
        let response = JSONValue.object(["corrected_text": .string("the first\r\nsecond line")]).pretty
        let result = try QuickTextActionSession.validatedResult(response, kind: .proofread, original: original)
        #expect(result.utf16.elementsEqual("  the first\r\nsecond line\n  ".utf16))
        #expect(throws: (any Error).self) {
            try QuickTextActionSession.validatedResult("{\"corrected_text\":\"the first\\nsecond line\"}", kind: .proofread, original: original)
        }
    }

    @Test(arguments: [false, true])
    func stopOrCloseClearsImmediatelyFencesLateResultsAndPreventsOverlappingInference(close: Bool) async throws {
        let editor = SyntheticBoundEditor()
        let target = try editor.binding()
        var continuation: CheckedContinuation<ModelReply, Never>?
        var calls = 0
        let session = QuickTextActionSession(generate: { _ in
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        })
        try session.start(kind: .proofread, selection: target)
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        let completion = try #require(continuation)
        if close { session.close() } else { session.stop() }
        #expect(session.sourceText.isEmpty && session.resultText.isEmpty && target.selectedText.isEmpty)
        #expect(session.isBusy)
        #expect(throws: RelayError.self) { try session.start(kind: .summarize, selection: editor.binding()) }
        completion.resume(returning: ModelReply(content: "{\"corrected_text\":\"Late private result\"}", toolCalls: []))
        await settle(session)
        #expect(session.phase == (close ? .closed : .stopped))
        #expect(session.sourceText.isEmpty && session.resultText.isEmpty && session.errorMessage == nil)
        #expect(calls == 1 && editor.writes.isEmpty)
    }

    @Test func closedSessionAcceptsFreshCaptureWithoutReusingTheOldResultOrBinding() async throws {
        let firstEditor = SyntheticBoundEditor()
        let first = try firstEditor.binding()
        let session = QuickTextActionSession(generate: { _ in ModelReply(content: "A private first summary.", toolCalls: []) })
        try session.start(kind: .summarize, selection: first)
        await settle(session)
        #expect(session.resultText == "A private first summary.")
        session.close()
        #expect(throws: RelayError.self) { try session.start(kind: .summarize, selection: first) }
        let secondEditor = SyntheticBoundEditor(value: "New distinct selection", selected: "New distinct selection")
        session.generate = { input in
            #expect(input.allSatisfy { !$0.content.contains("private first") && !$0.content.contains("teh selected") })
            return ModelReply(content: "Second summary.", toolCalls: [])
        }
        try session.start(kind: .summarize, selection: secondEditor.binding())
        #expect(session.resultText.isEmpty)
        await settle(session)
        #expect(session.resultText == "Second summary.")
        #expect(session.sourceText == "New distinct selection")
    }

    @Test func toolRequestAndModelFailureNeverEditOrExposeErrorPayloads() async throws {
        let editor = SyntheticBoundEditor()
        let session = QuickTextActionSession(generate: { _ in
            ModelReply(content: "{\"corrected_text\":\"Changed\"}", toolCalls: [ToolCall(name: "write_file", arguments: [:])])
        })
        try session.start(kind: .proofread, selection: editor.binding())
        await settle(session)
        #expect(session.phase == .failed && !session.canReplace && editor.writes.isEmpty)
        session.generate = { _ in throw RelayError.message("Sensitive exception payload") }
        try session.start(kind: .proofread, selection: editor.binding())
        await settle(session)
        #expect(session.errorMessage?.contains("Sensitive exception payload") == false)
        #expect(session.resultText.isEmpty && editor.writes.isEmpty)
    }

    private func settle(_ session: QuickTextActionSession) async {
        for _ in 0..<2_000 where session.isBusy { await Task.yield() }
        #expect(!session.isBusy, "Synthetic generation should settle within the bounded yield budget")
    }
}
