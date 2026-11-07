import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Opt-in qualification against the signed, inert fixture only. Generation is
/// synthetic; the fixture's own timer writes an independent text/selection oracle.
@Suite(.serialized)
@MainActor
struct QuickTextActionDesktopTests {
    private struct Oracle: Decodable {
        struct Draft: Decodable {
            let text: String
            let focused: Bool
            let selectionLocation: Int
            let selectionLength: Int
        }
        let launchToken: String
        let clickCount: Int
        let result: String
        let focusedWindow: String?
        let draft: Draft?
    }

    private let selected = "Ths selected café 👩‍💻 sentence."
    private let correction = "This selected café 👩‍💻 sentence."
    private var original: String {
        "Untouched Cafe\u{301} 🌍 prefix.\n" + selected + "\nUntouched العربية suffix."
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_AX_TESTS"] == "1"))
    func reviewedNativeSelectionChangesOnlyItsUTF16RangeAndCannotReplay() async throws {
        try requireExistingAccess()
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            let editor = try await prepareEditor(fixture)
            let range = (original as NSString).range(of: selected)
            try setSelection(range, in: editor)
            _ = try await expectOracle(fixture, text: original, range: range)
            let binding = try BoundTextSelection.capture(application: fixture.application)
            defer { binding.clear() }
            #expect(binding.selectedText.utf16.elementsEqual(selected.utf16))
            try #require(binding.canReplace, "The fixture's ordinary plain NSTextView should support reviewed replacement.")
            let session = proofreadSession()
            defer { session.close() }
            try session.start(kind: .proofread, selection: binding)
            try await awaitReady(session)
            #expect(session.sourceText.utf16.elementsEqual(selected.utf16))
            #expect(session.resultText.utf16.elementsEqual(correction.utf16))
            try #require(session.canReplace)
            // Generation must finish with the original editor still untouched.
            _ = try await expectOracle(fixture, text: original, range: range)

            #expect(try session.replaceReviewedSelection() == .replaced)
            let expected = (original as NSString).replacingCharacters(in: range, with: correction)
            let after = try await expectOracle(fixture, text: expected)
            #expect(after.draft?.text.utf16.elementsEqual(expected.utf16) == true)
            #expect(!session.canReplace && !binding.canReplace)
            #expect(throws: RelayError.self) { try session.replaceReviewedSelection() }
            guard case .copyOnly = try binding.replaceReviewed(with: correction) else {
                Issue.record("An already used native binding must not dispatch another write.")
                return
            }
            _ = try await expectOracle(fixture, text: expected)
            session.close()
            #expect(session.sourceText.isEmpty && session.resultText.isEmpty && binding.selectedText.isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_AX_TESTS"] == "1"),
          arguments: ["field", "range", "window"])
    func changedNativeFieldSelectionOrWindowRequiresCopyOnly(change: String) async throws {
        try requireExistingAccess()
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1", "RELAY_FIXTURE_INCLUDE_SECOND_WINDOW": "1"]) { fixture in
            let editor = try await prepareEditor(fixture)
            let range = (original as NSString).range(of: selected)
            try setSelection(range, in: editor)
            _ = try await expectOracle(fixture, text: original, range: range)
            let binding = try BoundTextSelection.capture(application: fixture.application)
            defer { binding.clear() }
            let session = proofreadSession()
            defer { session.close() }
            try session.start(kind: .proofread, selection: binding)
            try await awaitReady(session)

            var expected = original
            var currentRange: NSRange? = range
            switch change {
            case "field":
                expected += " Additional external edit."
                try setValue(expected, in: editor)
                try setSelection(range, in: editor)
            case "range":
                currentRange = NSRange(location: range.location + 1, length: range.length - 1)
                try setSelection(try #require(currentRange), in: editor)
            case "window":
                try await focusSecondWindow(in: fixture)
                currentRange = nil
            default:
                Issue.record("Unknown native drift case.")
            }
            _ = try await expectOracle(fixture, text: expected, range: currentRange)
            guard case .copyOnly = try session.replaceReviewedSelection() else {
                Issue.record("A changed native target must refuse replacement and retain the correction for copying.")
                return
            }
            #expect(!session.canReplace)
            #expect(session.resultText.utf16.elementsEqual(correction.utf16))
            #expect(throws: RelayError.self) { try session.replaceReviewedSelection() }
            _ = try await expectOracle(fixture, text: expected, range: currentRange)
        }
    }

    private func requireExistingAccess() throws {
        try #require(AXIsProcessTrusted(), "The native test requires existing Accessibility access and never requests it.")
        _ = try #require(ProcessInfo.processInfo.environment["RELAY_AX_FIXTURE_APP"], "Use an explicitly supplied signed fixture.")
    }

    private func prepareEditor(_ fixture: DesktopFixtureProcess) async throws -> AXUIElement {
        try fixture.requireExclusiveProcess()
        for _ in 0..<40 {
            if try oracle(fixture).draft?.focused == true,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(try oracle(fixture).draft?.focused == true)
        try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier)
        let root = AXUIElementCreateApplication(fixture.application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        var raw: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &raw) == .success)
        let value = try #require(raw)
        try #require(CFGetTypeID(value) == AXUIElementGetTypeID())
        let editor = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(editor, 0.3)
        var identifier: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(editor, kAXIdentifierAttribute as CFString, &identifier) == .success)
        try #require(identifier as? String == "relay.fixture.draft")
        var pid: pid_t = 0
        try #require(AXUIElementGetPid(editor, &pid) == .success && pid == fixture.application.processIdentifier)
        try setValue(original, in: editor)
        return editor
    }

    private func setValue(_ text: String, in editor: AXUIElement) throws {
        try #require(AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, text as CFString) == .success)
    }

    private func setSelection(_ selectedRange: NSRange, in editor: AXUIElement) throws {
        var range = CFRange(location: selectedRange.location, length: selectedRange.length)
        let value = try #require(AXValueCreate(.cfRange, &range))
        try #require(AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, value) == .success)
    }

    private func proofreadSession() -> QuickTextActionSession {
        QuickTextActionSession(generate: { messages in
            #expect(messages.count == 2 && messages.map(\.role) == ["system", "user"])
            let content = try #require(messages.last?.content)
            let payload = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: String])
            #expect(Set(payload.keys) == ["selected_text"])
            #expect(payload["selected_text"]?.utf16.elementsEqual(selected.utf16) == true)
            #expect(messages.allSatisfy { !$0.content.contains("Untouched") && !$0.content.contains("العربية suffix") })
            let data = try JSONEncoder().encode(["corrected_text": correction])
            return ModelReply(content: String(decoding: data, as: UTF8.self), toolCalls: [])
        })
    }

    private func awaitReady(_ session: QuickTextActionSession) async throws {
        for _ in 0..<40 where session.isBusy { try await Task.sleep(for: .milliseconds(25)) }
        try #require(!session.isBusy && session.phase == .ready, Comment(rawValue: session.errorMessage ?? "Synthetic proofreading must complete."))
    }

    private func oracle(_ fixture: DesktopFixtureProcess) throws -> Oracle {
        let value = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: fixture.oracleURL))
        try #require(value.launchToken == fixture.token)
        return value
    }

    @discardableResult
    private func expectOracle(_ fixture: DesktopFixtureProcess, text: String, range: NSRange? = nil) async throws -> Oracle {
        var value = try oracle(fixture)
        func matches(_ value: Oracle) -> Bool {
            guard let draft = value.draft, draft.text.utf16.elementsEqual(text.utf16) else { return false }
            return range == nil || (draft.selectionLocation == range?.location && draft.selectionLength == range?.length)
        }
        for _ in 0..<40 where !matches(value) {
            try await Task.sleep(for: .milliseconds(25))
            value = try oracle(fixture)
        }
        try #require(matches(value), "The fixture's independent text/selection oracle must match literally.")
        #expect(value.clickCount == 0 && value.result == "Not applied")
        return value
    }

    private func focusSecondWindow(in fixture: DesktopFixtureProcess) async throws {
        try fixture.requireExclusiveProcess()
        let tools = MacTools()
        defer { tools.invalidateApprovals() }
        let windows = try await tools.execute(ToolCall(name: "observe_app", arguments: [
            "bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID), "mode": .string("windows")
        ]))
        let title = "Relay Fixture Second Window"
        let matches = windows.summary.split(separator: "\n").filter { $0.contains(" role=AXWindow title=\(title) description=") }
        try #require(matches.count == 1)
        let first = try #require(matches.first?.split(separator: " ").first)
        try #require(first.hasPrefix("element_id="))
        let id = String(first.dropFirst("element_id=".count))
        let focused = try await tools.execute(ToolCall(name: "press_control", arguments: [
            "bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID), "element_id": .string(id), "action": .string("focus")
        ]))
        try #require(focused.verified)
        for _ in 0..<40 where try oracle(fixture).focusedWindow != title { try await Task.sleep(for: .milliseconds(25)) }
        try #require(try oracle(fixture).focusedWindow == title)
    }
}
