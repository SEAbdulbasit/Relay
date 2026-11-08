import Foundation
import Testing
@testable import Relay

@Suite @MainActor struct NativeControlDescriptorTests {
    @MainActor private final class Editor {
        var foreground = false, identity = 1, originalIdentity = 1
        var protected: Bool? = false, hidden: Bool? = false, enabled: Bool? = true
        var role = "AXTextArea", subrole = ""
        var label: String? = "Synthetic editor", identifier: String? = "owned.editor"
        var value = "Original café 🌍", selection = NSRange(location: 0, length: 8)
        var labelReads = 0, valueReads = 0, inputChecks = 0
        var revoked = false, revokeDuringMetadata = false
        func capture() throws -> NativeControlSession.FocusFence {
            try NativeControlFocus.capture(.init(validateIdentity: {
                guard !self.revoked else { throw NativeControlSession.Failure.stopped }
                guard self.identity == self.originalIdentity else { throw NativeControlSession.Failure.changedFocus }
            }, validateInputIdentity: {
                self.inputChecks += 1
                guard self.foreground else { throw NativeControlSession.Failure.changedFocus }
            }, metadata: {
                if self.revokeDuringMetadata { self.revoked = true }
                return .init(role: self.role, subrole: self.subrole, protected: self.protected,
                    hidden: self.hidden, enabled: self.enabled, valueWritable: true, selectionWritable: true)
            }, qualifiedLabels: {
                self.labelReads += 1
                return .init(label: self.label, identifier: self.identifier)
            }, contents: {
                self.valueReads += 1
                return .init(value: self.value, selection: self.selection)
            }))
        }
    }

    @Test func sourcePreviewIsBackgroundReadableButInputStillRequiresForeground() throws {
        let editor = Editor(), focus = try editor.capture()
        #expect(editor.inputChecks == 0)
        #expect(focus.descriptor.role == "AXTextArea" && focus.descriptor.label == "Synthetic editor")
        #expect(focus.descriptor.selection?.originalUTF16Count == editor.value.utf16.count)
        try focus.validateSourceBeforeInput()
        let reads = editor.valueReads
        #expect(throws: NativeControlSession.Failure.changedFocus) { try focus.validateBeforeInput() }
        #expect(editor.valueReads == reads)
        editor.foreground = true
        try focus.validateBeforeInput()
    }
    @Test(arguments: ["secure-role", "secure-subrole", "protected", "hidden", "unknown-protection", "unknown-hidden"])
    func privacyRefusalOccursBeforeLabelsOrValues(_ cause: String) {
        let editor = Editor()
        switch cause {
        case "secure-role": editor.role = "AXSecureTextField"
        case "secure-subrole": editor.subrole = "AXSecureTextField"
        case "protected": editor.protected = true
        case "hidden": editor.hidden = true
        case "unknown-protection": editor.protected = nil
        default: editor.hidden = nil
        }
        #expect(throws: NativeControlSession.Failure.unavailableFocus) { try editor.capture() }
        #expect(editor.labelReads == 0 && editor.valueReads == 0)
    }
    @Test func revocationDuringMetadataCannotStartPrivateLabelOrValueReads() {
        let editor = Editor(); editor.revokeDuringMetadata = true
        #expect(throws: NativeControlSession.Failure.stopped) { try editor.capture() }
        #expect(editor.labelReads == 0 && editor.valueReads == 0)
    }
    @Test func aDifferentEditorCannotBeAdoptedAfterPlanning() throws {
        let editor = Editor(), focus = try editor.capture()
        let before = editor.valueReads
        editor.identity += 1
        #expect(throws: NativeControlSession.Failure.changedFocus) { try focus.validateSourceBeforeInput() }
        #expect(editor.valueReads == before)
    }
    @Test(arguments: ["value", "selection", "label", "identifier"])
    func frozenOriginalFieldFactsRefusePlanningDrift(_ cause: String) throws {
        let editor = Editor(), focus = try editor.capture()
        switch cause {
        case "value": editor.value = "Different value"
        case "selection": editor.selection = NSRange(location: 1, length: 7)
        case "label": editor.label = "Different editor label"
        default: editor.identifier = "other.editor"
        }
        #expect(throws: NativeControlSession.Failure.changedFocus) { try focus.validateSourceBeforeInput() }
    }
    @Test func labelsCompareLiteralUTF16AndCannotNormalizeAChangedTarget() throws {
        let first = try NativeControlTargetDescriptor(role: "AXTextArea", label: "caf\u{e9}", identifier: nil, selection: nil)
        let other = try NativeControlTargetDescriptor(role: "AXTextArea", label: "cafe\u{301}", identifier: nil, selection: nil)
        #expect(first != other)
    }
    @Test func targetDescriptorBoundsAndSelectionAreValidated() {
        #expect(throws: (any Error).self) { try NativeControlTargetDescriptor(role: "AXSecureTextField", label: nil, identifier: nil, selection: nil) }
        #expect(throws: (any Error).self) { try NativeControlTargetDescriptor(role: "AXTextArea", label: String(repeating: "a", count: 513), identifier: nil, selection: nil) }
        #expect(throws: (any Error).self) { try NativeControlTargetDescriptor(role: "AXTextArea", label: "bad\u{0}label", identifier: nil, selection: nil) }
        #expect(throws: (any Error).self) { try NativeControlTargetDescriptor(role: "AXTextArea", label: nil, identifier: nil,
            selection: .init(location: 2, length: 2, originalUTF16Count: 3)) }
    }
    @Test func requestAdmissionKeepsExactOpaqueBytesAndDoesNotConsumeWhileValidating() throws {
        var validations = 0, attempts = 0
        let bytes = Data("provider:e\u{301}:🌍".utf8)
        let request = NativeControlRequestAdmission(requestID: "app-owned-stable-key", originalProviderCallID: bytes,
            exactCallDigest: Data(repeating: 1, count: 32), validateAcceptedProposal: { validations += 1 },
            admitOneAttempt: { attempts += 1 })
        try request.validate()
        #expect(request.originalProviderCallID == bytes && validations == 1 && attempts == 0)
    }
}
