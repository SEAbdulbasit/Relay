import Foundation
import Testing
@testable import Relay

/// Actual metadata comparison rules with inert node IDs, not AX objects,
/// field contents, saved-message receipts or input/completion capabilities.
@MainActor @Suite struct NativeExactUnsentInvocationTests {
    private let application = DesktopApplicationIdentity(processID: 42, launchedAt: Date(timeIntervalSince1970: 1),
        bundleID: "test.original", bundleURL: URL(fileURLWithPath: "/Original.app"))
    private func snapshot(application: DesktopApplicationIdentity? = nil, window: Int = 10, editor: Int = 20,
        selectedWindow: Int = 10, selectedEditor: Int = 20, editorWindow: Int = 10, windows: [Int] = [10],
        rootPID: Int32 = 42, windowPID: Int32 = 42, editorPID: Int32 = 42,
        hidden: Bool = false, minimized: Bool = false, enabled: Bool = true,
        windowRole: String = "AXWindow", editorRole: String = "AXTextField",
        subrole: NativeExactUnsentOptionalFact<String> = .noValue,
        modal: NativeExactUnsentOptionalFact<Bool> = .unsupported,
        protection: [NativeExactUnsentOptionalFact<Bool>] = Array(repeating: .unsupported, count: 6)) -> NativeExactUnsentTechnicalSnapshot<Int> {
        .init(application: application ?? self.application, window: window, editor: editor, selectedWindow: selectedWindow,
            selectedEditor: selectedEditor, editorWindow: editorWindow, windows: windows, rootPID: rootPID,
            windowPID: windowPID, editorPID: editorPID, applicationHidden: hidden, minimized: minimized,
            enabled: enabled, windowRole: windowRole, editorRole: editorRole, editorSubrole: subrole,
            modal: modal, protection: protection)
    }

    @Test func exactTechnicalIdentitySupportsStatusBearingAbsenceWithoutInventingPrivacyFalse() throws {
        let initial = snapshot(), current = snapshot(windows: [9,10,11])
        try current.validate(original: initial, identical: ==)
        #expect(initial.protection == Array(repeating: .unsupported, count: 6))
        #expect(initial.protection.allSatisfy { $0.reported == nil })
        #expect(NativeExactUnsentOptionalFact<Bool>.unsupported != .reported(false))
        #expect(NativeExactUnsentOptionalFact<Bool>.noValue != .unsupported)
        // This comparison grants no field/private-read/ordinary-role authority.
        #expect(throws: NativeExactUnsentFailure.changedOriginal) {
            try snapshot(protection: Array(repeating: .reported(false), count: 6)).validate(original: initial, identical: ==)
        }
    }

    @Test func exactOriginalMembershipRejectsLookalikeSelectionDuplicateAndForeignPID() {
        let original = snapshot()
        let changed = [snapshot(window: 11, selectedWindow: 11, editorWindow: 11, windows: [11]),
            snapshot(editor: 21, selectedEditor: 21), snapshot(selectedWindow: 11), snapshot(selectedEditor: 21),
            snapshot(editorWindow: 11), snapshot(windows: []), snapshot(windows: [10,10]),
            snapshot(rootPID: 99), snapshot(windowPID: 99), snapshot(editorPID: 99)]
        for value in changed {
            #expect(throws: NativeExactUnsentFailure.changedOriginal) { try value.validate(original: original, identical: ==) }
        }
    }

    @Test func processLifetimePathAndBundleArePartOfOriginalIdentity() {
        let original = snapshot()
        for changed in [
            DesktopApplicationIdentity(processID: 42, launchedAt: Date(timeIntervalSince1970: 2), bundleID: application.bundleID, bundleURL: application.bundleURL),
            DesktopApplicationIdentity(processID: 42, launchedAt: application.launchedAt, bundleID: "test.other", bundleURL: application.bundleURL),
            DesktopApplicationIdentity(processID: 42, launchedAt: application.launchedAt, bundleID: application.bundleID, bundleURL: URL(fileURLWithPath: "/Other.app"))
        ] {
            #expect(throws: NativeExactUnsentFailure.changedOriginal) {
                try snapshot(application: changed).validate(original: original, identical: ==)
            }
        }
    }

    @Test func allActualAncestorProtectionAliasesAndSecureModalMetadataRefuse() {
        for index in 0..<6 {
            var flags = Array<NativeExactUnsentOptionalFact<Bool>>(repeating: .unsupported, count: 6)
            flags[index] = .reported(true)
            #expect(throws: NativeExactUnsentFailure.protectedContext) { try snapshot(protection: flags).validate(identical: ==) }
        }
        for subrole in ["AXSecureTextField", "PasswordEditor", "AXSearchField"] {
            #expect(throws: NativeExactUnsentFailure.protectedContext) {
                try snapshot(subrole: .reported(subrole)).validate(identical: ==)
            }
        }
        #expect(throws: NativeExactUnsentFailure.protectedContext) { try snapshot(modal: .reported(true)).validate(identical: ==) }
    }

    @Test func hiddenMinimizedDisabledUnknownRoleAndIncompleteTechnicalCoverageRefuse() {
        for value in [snapshot(hidden: true), snapshot(minimized: true), snapshot(enabled: false),
                      snapshot(windowRole: "AXSheet"), snapshot(editorRole: "AXWebArea"), snapshot(protection: [])] {
            #expect(throws: NativeExactUnsentFailure.changedOriginal) { try value.validate(identical: ==) }
        }
    }

    @Test func metadataCancellationCannotBecomeSuccessfulIdentityValidation() async {
        let original = snapshot()
        let child = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try original.validate(identical: ==) }
        }
        await child.value
    }

    @Test func literalValidationPreservesExactUnicodeAndWhitespaceWithoutParsing() throws {
        let nfc = "\u{00E9}", nfd = "e\u{0301}"
        for literal in [nfc, nfd, "  literal  ", "漢字🙂", String(repeating: "x", count: 4_096)] {
            try NativeAcknowledgedExactUnsentObjective.requireLiteral(literal)
        }
        #expect(Data(nfc.utf8) != Data(nfd.utf8))
        for literal in ["", "line\nnext", "tab\tvalue", String(repeating: "x", count: 4_097)] {
            #expect(throws: NativeExactUnsentFailure.invalidLiteral) { try NativeAcknowledgedExactUnsentObjective.requireLiteral(literal) }
        }
    }

    @Test func messageComparisonUsesFullNamespaceAndExactRequestBytesButMintsNoReceipt() throws {
        let message = UUID(), task = UUID(), run = UUID(), attempt = UUID()
        let anchor = UUID(), origin = UUID(), bytes = Data("e\u{0301}".utf8)
        func binding(messageID: UUID? = nil, taskID: UUID? = nil, runID: UUID? = nil, attemptID: UUID? = nil,
            anchorID: UUID? = nil, originID: UUID? = nil, revision: Int = 1,
            request: Data? = nil, literal: Data? = nil) -> NativeExactUnsentMessageBinding {
            .init(messageID: messageID ?? message, logicalTaskID: taskID ?? task, runID: runID ?? run,
                attemptID: attemptID ?? attempt, anchorID: anchorID ?? anchor, originID: originID ?? origin,
                originRevision: revision, exactRequestUTF8: request ?? bytes, literalUTF8: literal ?? bytes)
        }
        let original = binding()
        try original.requireSame(original)
        for changed in [
            binding(messageID: UUID()), binding(taskID: UUID()), binding(runID: UUID()), binding(attemptID: UUID()),
            binding(anchorID: UUID()), binding(originID: UUID()), binding(revision: 2),
            binding(request: Data("\u{00E9}".utf8)), binding(literal: Data("\u{00E9}".utf8))
        ] {
            #expect(throws: NativeExactUnsentFailure.wrongMessage) { try original.requireSame(changed) }
        }
    }
}
