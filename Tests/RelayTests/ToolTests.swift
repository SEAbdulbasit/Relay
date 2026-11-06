import Foundation
import AppKit
import CoreText
import Testing
@testable import Relay

@MainActor
struct ToolTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-tools-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func scopeRejectsTraversalAndSiblingPrefix() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let grants = [ScopeGrant(path: folder.path)]
        #expect(throws: (any Error).self) { try ToolPolicy.scopedURL(folder.appendingPathComponent("../secret.txt").path, grants: grants) }
        #expect(throws: (any Error).self) { try ToolPolicy.scopedURL(folder.path + "-other/file.txt", grants: grants) }
        #expect(throws: (any Error).self) { try ToolPolicy.scopedURL("relative.txt", grants: grants) }
    }

    @Test func scopeRejectsEscapingSymlink() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("allowed", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try ToolPolicy.scopedURL(folder.appendingPathComponent("escape/secret.txt").path, grants: [ScopeGrant(path: folder.path, writable: true)], writing: true)
        }
    }

    @Test func readonlyGrantCannotWrite() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path)]
        let target = folder.appendingPathComponent("draft.md")
        await #expect(throws: (any Error).self) {
            try await tools.execute(ToolCall(name: "write_file", arguments: ["path": .string(target.path), "content": .string("hello")]))
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func writeHasExactReadbackAndOverwriteRequiresBoundReview() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        let target = folder.appendingPathComponent("draft.md")
        let create = ToolCall(name: "write_file", arguments: ["path": .string(target.path), "content": .string("original")])
        let result = try await tools.execute(create)
        #expect(result.verified)
        #expect(result.artifactPath == (try ToolPolicy.canonicalURL(target.path).path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        let replacement = ToolCall(name: "write_file", arguments: ["path": .string(target.path), "content": .string("replacement")])
        #expect(tools.reviewReason(for: replacement) != nil)
        await #expect(throws: (any Error).self) { try await tools.execute(replacement) }
        try tools.prepareReview(replacement)
        try tools.authorize(replacement)
        try Data("outside change".utf8).write(to: target)
        await #expect(throws: (any Error).self) { try await tools.execute(replacement) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside change")
        try tools.prepareReview(replacement)
        try tools.authorize(replacement)
        #expect(try await tools.execute(replacement).verified)
        #expect(try String(contentsOf: target, encoding: .utf8) == "replacement")
        await #expect(throws: (any Error).self) { try await tools.execute(replacement) }
    }

    @Test func authorizationDoesNotCoverChangedPayload() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("data.csv")
        try Data("old".utf8).write(to: target)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        let call = ToolCall(name: "write_file", arguments: ["path": .string(target.path), "content": .string("approved")])
        try tools.prepareReview(call)
        try tools.authorize(call)
        var changed = call
        changed.arguments["content"] = .string("unapproved")
        await #expect(throws: (any Error).self) { try await tools.execute(changed) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    }

    @Test func schemaRejectsUnknownToolExtraAndWrongType() throws {
        #expect(throws: (any Error).self) { try ToolPolicy.validate(ToolCall(name: "shell", arguments: [:]), against: MacTools.definitions) }
        #expect(throws: (any Error).self) { try ToolPolicy.validate(ToolCall(name: "open_app", arguments: ["app": .string("VLC"), "command": .string("bad")]), against: MacTools.definitions) }
        #expect(throws: (any Error).self) { try ToolPolicy.validate(ToolCall(name: "read_file", arguments: ["path": .number(7)]), against: MacTools.definitions) }
    }

    @Test func invalidOrCredentialURLsCannotOpen() throws {
        for value in ["file:///etc/passwd", "javascript:alert(1)", "https://user:password@example.com", "ftp://example.com", "not a url"] {
            #expect(throws: (any Error).self) { try ToolPolicy.webURL(value) }
        }
        #expect(try ToolPolicy.webURL("https://example.com/path").host == "example.com")
    }

    @Test func stoppedTaskCannotDispatchWrite() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        let file = folder.appendingPathComponent("never-created.txt")
        let task = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            return try await tools.execute(ToolCall(name: "write_file", arguments: ["path": .string(file.path), "content": .string("must not write")]))
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test func PDFTextIsExtractedLocallyWithPageEvidence() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("local.pdf")
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 20, y: 100)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Locally extracted project notes", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: file)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path)]
        let result = try await tools.execute(ToolCall(name: "read_file", arguments: ["path": .string(file.path)]))
        #expect(result.summary.contains("Locally extracted project notes"))
        #expect(result.summary.contains("[Page 1]"))
        #expect(result.evidence.contains("PDFKit"))
        #expect(result.verified)
    }

    @Test func onlyExactKnownPlayerButtonsAreRoutine() {
        #expect(MacTools.isRoutineMediaLabel(bundleID: "org.videolan.vlc", role: "AXButton", label: "Play"))
        #expect(MacTools.isRoutineMediaLabel(bundleID: "com.apple.QuickTimePlayerX", role: "AXButton", label: "Pause"))
        #expect(!MacTools.isRoutineMediaLabel(bundleID: "com.apple.Safari", role: "AXButton", label: "Play"))
        #expect(!MacTools.isRoutineMediaLabel(bundleID: "org.videolan.vlc", role: "AXButton", label: "Play and purchase"))
        #expect(!MacTools.isRoutineMediaLabel(bundleID: "org.videolan.vlc", role: "AXMenuItem", label: "Play"))
    }

    @Test func excludedConsequentialControlsRemainUnsupported() {
        for label in ["Buy now", "Confirm payment", "Transfer money", "Delete selected files", "Save and delete originals", "Change password", "Disable security", "Empty Trash", "Send", "Submit application", "Publish post", "Send…", "Submit ✓", "Publish!"] {
            #expect(MacTools.isExcludedControlLabel(label))
        }
        for label in ["Play", "Pause", "Next", "Save draft", "Open file"] {
            #expect(!MacTools.isExcludedControlLabel(label))
        }
    }

    @Test func stopInvalidatesPreparedApproval() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("draft.txt")
        try Data("before".utf8).write(to: file)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        let call = ToolCall(name: "write_file", arguments: ["path": .string(file.path), "content": .string("after")])
        try tools.prepareReview(call)
        try tools.authorize(call)
        tools.invalidateApprovals()
        await #expect(throws: (any Error).self) { try await tools.execute(call) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "before")
    }

    @Test func unicodeFileOutputStaysWithinContextBudgetAndDisclosesOmission() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("large.txt")
        try Data(String(repeating: "مرحبا🌍 ", count: 4000).utf8).write(to: file)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path)]
        let result = try await tools.execute(ToolCall(name: "read_file", arguments: ["path": .string(file.path)]))
        #expect(result.summary.utf8.count < 12_000)
        #expect(result.summary.contains("Content truncated"))
        #expect(result.summary.contains("Omitted text has not been inspected"))
        #expect(!result.summary.contains("�"))
        #expect(MacTools.boundedText("🌍", utf8Limit: 3).isEmpty)
        #expect(MacTools.boundedText("a🌍b", utf8Limit: 5) == "a🌍")
    }

    @Test func fileEditedDuringPendingReviewCannotBeOverwritten() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pending.txt")
        try Data("reviewed before".utf8).write(to: file)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        let call = ToolCall(name: "write_file", arguments: ["path": .string(file.path), "content": .string("replacement")])
        try tools.prepareReview(call)
        try Data("edited during review".utf8).write(to: file)
        #expect(throws: (any Error).self) { try tools.authorize(call) }
        await #expect(throws: (any Error).self) { try await tools.execute(call) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "edited during review")
    }

    @Test func sameContentSymlinkRetargetInvalidatesPendingReview() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.txt")
        let second = folder.appendingPathComponent("second.txt")
        let link = folder.appendingPathComponent("active.txt")
        try Data("identical".utf8).write(to: first)
        try Data("identical".utf8).write(to: second)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        let call = ToolCall(name: "write_file", arguments: ["path": .string(link.path), "content": .string("replacement")])
        try tools.prepareReview(call)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        #expect(throws: (any Error).self) { try tools.authorize(call) }
        #expect(try String(contentsOf: first, encoding: .utf8) == "identical")
        #expect(try String(contentsOf: second, encoding: .utf8) == "identical")
    }

    @Test func reviewMustBePreparedAndSurvivesNeitherStopNorPayloadDrift() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("review.txt")
        try Data("before".utf8).write(to: file)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        let call = ToolCall(name: "write_file", arguments: ["path": .string(file.path), "content": .string("after")])
        #expect(throws: (any Error).self) { try tools.authorize(call) }
        try tools.prepareReview(call)
        tools.invalidateApprovals()
        #expect(throws: (any Error).self) { try tools.authorize(call) }
        try tools.prepareReview(call)
        var changed = call
        changed.arguments["content"] = .string("different")
        #expect(throws: (any Error).self) { try tools.authorize(changed) }
    }

    @Test func fileHandlersAreAllowlistedForDefaultAndExplicitSelection() {
        #expect(MacTools.isSupportedDocumentHandler(bundleID: "org.videolan.vlc", appName: "VLC"))
        #expect(MacTools.isSupportedDocumentHandler(bundleID: "com.apple.TextEdit", appName: "TextEdit"))
        #expect(MacTools.isSupportedDocumentHandler(bundleID: "com.apple.Preview", appName: "Preview"))
        for (bundle, name) in [("com.apple.Terminal", "Terminal"), ("com.googlecode.iterm2", "iTerm"), ("com.apple.ScriptEditor2", "Script Editor"), ("com.apple.Automator", "Automator"), ("com.apple.shortcuts", "Shortcuts"), ("org.custom.Interpreter", "Custom interpreter")] {
            #expect(!MacTools.isSupportedDocumentHandler(bundleID: bundle, appName: name))
        }
        #expect(!MacTools.isSupportedDocumentHandler(bundleID: "com.apple.TextEdit", appName: "Terminal"))
    }

    @Test func reviewContextBindsWindowPayloadAndEnabledStateNotOnlyButton() {
        let original = AXReviewContext(windowIdentity: "app|pid|window1|documentA", title: "Draft", buttonFingerprint: "unchanged apply button", fields: [AXReviewField(identity: "0.0|recipient", label: "Recipient", value: "first@example.test", enabled: true), AXReviewField(identity: "0.1|body", label: "Body", value: "Approved text", enabled: true)])
        var recipientChanged = original
        recipientChanged.fields[0].value = "different@example.test"
        var bodyChanged = original
        bodyChanged.fields[1].value = "Unreviewed text"
        var windowChanged = original
        windowChanged.windowIdentity = "app|pid|window2|documentB"
        var fieldDisabled = original
        fieldDisabled.fields[0].enabled = false
        var fieldAdded = original
        fieldAdded.fields.append(AXReviewField(identity: "0.2|new", label: "Extra", value: "New payload", enabled: true))
        #expect(original.fingerprint != recipientChanged.fingerprint)
        #expect(original.fingerprint != bodyChanged.fingerprint)
        #expect(original.fingerprint != windowChanged.fingerprint)
        #expect(original.fingerprint != fieldDisabled.fingerprint)
        #expect(original.fingerprint != fieldAdded.fingerprint)
        #expect(original.fingerprint == original.fingerprint)
    }

    @Test func recorderNamesResolveWithoutFuzzyMatchingUnrelatedApps() {
        #expect(MacTools.applicationAliasBundleID("Voice Recorder") == "com.apple.VoiceMemos")
        #expect(MacTools.applicationAliasBundleID("  voice   memos  ") == "com.apple.VoiceMemos")
        #expect(MacTools.applicationAliasBundleID("audio recorder") == "com.apple.VoiceMemos")
        #expect(MacTools.applicationAliasBundleID("Calculator") == "com.apple.calculator")
        #expect(MacTools.applicationAliasBundleID("Apple Notes") == "com.apple.Notes")
        #expect(MacTools.applicationAliasBundleID("System Settings") == "com.apple.systempreferences")
        #expect(MacTools.applicationAliasBundleID("screen recorder") == nil)
        #expect(MacTools.applicationAliasBundleID("Voice Recorder Pro") == nil)
        #expect(MacTools.applicationAliasBundleID("../Voice Recorder") == nil)
    }

}
