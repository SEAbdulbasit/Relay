import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor struct NativeControlFocusTests {
    @Test func protectedHiddenSecureDisabledOrUnverifiableEditorsRefuseBeforeValueRead() throws {
        for variant in 0..<10 {
            var reads = 0
            let access = NativeControlFocus.Access(validateIdentity: {}, validateInputIdentity: {}, metadata: {
                .init(role: variant == 0 ? "AXButton" : "AXTextArea", subrole: variant == 1 ? "AXSecureTextField" : "",
                    protected: variant == 2 ? true : variant == 3 ? nil : false,
                    hidden: variant == 4 ? true : variant == 5 ? nil : false,
                    enabled: variant == 6 ? false : variant == 7 ? nil : true,
                    valueWritable: variant != 8, selectionWritable: variant != 9)
            }, qualifiedLabels: { .init(label: nil, identifier: "owned.field") }, contents: { reads += 1; return .init(value: "Should not be read", selection: .init(location: 0, length: 0)) })
            #expect(throws: NativeControlSession.Failure.unavailableFocus) { try NativeControlFocus.capture(access) }
            #expect(reads == 0)
        }
    }
    @Test func conflictingProtectedFlagsAlwaysDenyAndMissingFlagsStayUnknown() {
        #expect(NativeControlFocus.protectedValue([false, true]) == true)
        #expect(NativeControlFocus.protectedValue([nil, false]) == false)
        #expect(NativeControlFocus.protectedValue([nil, nil]) == nil)
    }
    @Test func unavailableValueOrSelectionIsNotAnEqualMissingValueFingerprint() throws {
        for variant in 0..<3 {
            let access = NativeControlFocus.Access(validateIdentity: {}, validateInputIdentity: {}, metadata: { Self.valid }, qualifiedLabels: { .init(label: nil, identifier: "owned.field") }, contents: {
                if variant == 0 { throw NativeControlSession.Failure.unavailableFocus }
                return .init(value: "original", selection: .init(location: variant == 1 ? NSNotFound : 9, length: 0))
            })
            #expect(throws: NativeControlSession.Failure.unavailableFocus) { try NativeControlFocus.capture(access) }
        }
    }
    @Test func focusLeaseChecksPrivacyBeforeEachReadAndAllowsOnlyPostInputContentChange() throws {
        var protected = false, reads = 0, value = "original", selection = NSRange(location: 0, length: 0)
        let access = NativeControlFocus.Access(validateIdentity: {}, validateInputIdentity: {}, metadata: {
            .init(role: "AXTextArea", subrole: "", protected: protected,
                  hidden: false, enabled: true, valueWritable: true, selectionWritable: true)
        }, qualifiedLabels: { .init(label: nil, identifier: "owned.field") }, contents: { reads += 1; return .init(value: value, selection: selection) })
        let fence = try NativeControlFocus.capture(access)
        #expect(reads == 1)
        protected = true
        #expect(throws: NativeControlSession.Failure.unavailableFocus) { try fence.validateBeforeInput() }
        #expect(reads == 1)
        protected = false; value = "externally changed"; selection = NSRange(location: 2, length: 0)
        #expect(throws: NativeControlSession.Failure.changedFocus) { try fence.validateBeforeInput() }
        try fence.validateAfterInput()
        #expect(reads == 2)
    }
    private static var valid: NativeControlFocus.Metadata {
        .init(role: "AXTextArea", subrole: "", protected: false, hidden: false,
              enabled: true, valueWritable: true, selectionWritable: true)
    }
}
