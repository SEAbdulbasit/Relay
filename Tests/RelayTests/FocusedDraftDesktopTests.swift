import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct FocusedDraftDesktopTests {
    private struct Oracle: Decodable {
        struct Draft: Decodable { let text: String; let focused: Bool }
        let clickCount: Int
        let result: String
        let launchToken: String
        let draft: Draft?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_FOCUSED_DRAFT_TEST"] == "1"))
    func nativeDraftPreservesTextAndRefusesACaretChange() async throws {
        try #require(AXIsProcessTrusted(), "The test runner needs existing macOS Accessibility permission.")
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_AX_FIXTURE_APP"])
        try await DesktopFixtureProcess.withLaunch(path: path, environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            try await verifyDraft(in: fixture)
        }
    }

    private func verifyDraft(in fixture: DesktopFixtureProcess) async throws {
        let fixtureApp = fixture.application

        func read() -> Oracle? {
            guard let data = try? Data(contentsOf: fixture.oracleURL),
                  let value = try? JSONDecoder().decode(Oracle.self, from: data),
                  value.launchToken == fixture.token else { return nil }
            return value
        }
        for _ in 0..<30 {
            if read()?.draft?.focused == true,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == fixtureApp.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let initial = try #require(read()?.draft)
        try #require(initial.focused)
        try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixtureApp.processIdentifier)

        let controller = FocusedDraftController()
        controller.availability = { nil }
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        try #require(controller.enabled, Comment(rawValue: controller.status))
        let generated = "Thanks for confirming. شكرًا 👩‍💻"
        controller.generate = { messages in
            #expect(messages.count == 2)
            #expect(messages[1].content.contains("Existing draft"))
            return ModelReply(content: generated, toolCalls: [])
        }
        controller.activateFromGesture()
        try #require(controller.isBusy, Comment(rawValue: controller.status))
        for _ in 0..<30 {
            if !controller.isBusy, read()?.draft?.text != initial.text { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let completed = try #require(read())
        let updated = try #require(completed.draft)
        #expect(updated.text == initial.text + "\n\n" + generated, Comment(rawValue: controller.status))
        #expect(completed.clickCount == 0)
        #expect(completed.result == "Not applied")

        let root = AXUIElementCreateApplication(fixtureApp.processIdentifier)
        let editor = try focusedEditor(in: root)
        try setCaret(updated.text.utf16.count, editor: editor)
        controller.generate = { _ in
            try setCaret(0, editor: editor)
            return ModelReply(content: "This stale reply must not be inserted.", toolCalls: [])
        }
        controller.activateFromGesture()
        try #require(controller.isBusy, Comment(rawValue: controller.status))
        for _ in 0..<30 {
            if !controller.isBusy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let unchanged = try #require(read())
        #expect(unchanged.draft?.text == updated.text)
        #expect(unchanged.clickCount == 0)
        #expect(controller.status.contains("caret") || controller.status.contains("left alone"))
    }

    private func focusedEditor(in root: AXUIElement) throws -> AXUIElement {
        var raw: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &raw) == .success)
        let value = try #require(raw)
        try #require(CFGetTypeID(value) == AXUIElementGetTypeID())
        let editor = unsafeDowncast(value, to: AXUIElement.self)
        var identifier: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(editor, kAXIdentifierAttribute as CFString, &identifier) == .success)
        try #require(identifier as? String == "relay.fixture.draft")
        return editor
    }

    private func setCaret(_ location: Int, editor: AXUIElement) throws {
        var range = CFRange(location: location, length: 0)
        let value = try #require(AXValueCreate(.cfRange, &range))
        try #require(AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, value) == .success)
    }
}
