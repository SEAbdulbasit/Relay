import Foundation
import Testing
@testable import Relay

/// Actual verifier predicate/attributed parser only. No ACK, source capability,
/// effect, receipt, native window, permission, input or completion is fabricated.
@MainActor @Suite struct NativeExactUnsentVerificationTests {
    @Test(arguments: ["literal", "caf\u{e9}", "cafe\u{301}", "🧪 العربية\nsecond line", "   "])
    func exactUserBytesAndUTF16CaretAcceptActualAttributedCoverage(_ literal: String) throws {
        let sample = NativeExactUnsentOperation.ReadbackSample(value: literal, selectedText: "",
            caret: NSRange(location: literal.utf16.count, length: 0), attributed: NSAttributedString(string: literal))
        let first = try NativeExactUnsentOperation.requireExactReadback(sample, literal: literal)
        let second = try NativeExactUnsentOperation.requireExactReadback(sample, literal: literal)
        #expect(first.matches(second))
    }

    @Test func canonicalEquivalentStringDoesNotCountAsExactInsertedUTF8() throws {
        let original = "caf\u{e9}", changed = "cafe\u{301}"
        #expect(original == changed)
        #expect(Data(original.utf8) != Data(changed.utf8))
        let sample = NativeExactUnsentOperation.ReadbackSample(value: changed, selectedText: "",
            caret: NSRange(location: changed.utf16.count, length: 0), attributed: NSAttributedString(string: changed))
        #expect(throws: NativeExactUnsentOperation.Failure.readbackMismatch) {
            try NativeExactUnsentOperation.requireExactReadback(sample, literal: original)
        }
    }

    @Test(arguments: [RangeMismatch.graphemeCount, .selection, .selectedText, .extraText])
    func caretSelectionAndWholeValueAreVerifiedIndependently(_ change: RangeMismatch) throws {
        let literal = "🧪", value = change == .extraText ? literal + "!" : literal
        let sample = NativeExactUnsentOperation.ReadbackSample(value: value,
            selectedText: change == .selectedText ? literal : "",
            caret: NSRange(location: change == .graphemeCount ? literal.count : literal.utf16.count,
                length: change == .selection ? 1 : 0), attributed: NSAttributedString(string: value))
        #expect(throws: NativeExactUnsentOperation.Failure.readbackMismatch) {
            try NativeExactUnsentOperation.requireExactReadback(sample, literal: literal)
        }
    }

    @Test func attributedValueMustDescribeTheActualValueAndRejectUnknownAttributes() throws {
        let literal = "exact"
        let wrong = NativeExactUnsentOperation.ReadbackSample(value: literal, selectedText: "",
            caret: NSRange(location: literal.utf16.count, length: 0), attributed: NSAttributedString(string: "other"))
        #expect(throws: NativeFocusedAXInsertion.Failure.unavailableEditor) {
            try NativeExactUnsentOperation.requireExactReadback(wrong, literal: literal)
        }
        let unsupported = NSAttributedString(string: literal, attributes: [NSAttributedString.Key("unqualified-attribute"): "opaque"])
        let sample = NativeExactUnsentOperation.ReadbackSample(value: literal, selectedText: "",
            caret: NSRange(location: literal.utf16.count, length: 0), attributed: unsupported)
        #expect(throws: NativeFocusedAXInsertion.Failure.unavailableEditor) {
            try NativeExactUnsentOperation.requireExactReadback(sample, literal: literal)
        }
    }

    @Test func twoFreshReadsWithDifferentSupportedStylesCannotBeCalledCoherent() throws {
        let literal = "exact"
        let first = NativeExactUnsentOperation.ReadbackSample(value: literal, selectedText: "",
            caret: NSRange(location: literal.utf16.count, length: 0), attributed: NSAttributedString(string: literal))
        let changed = NSAttributedString(string: literal, attributes: [NSAttributedString.Key("AXUnderline"): NSNumber(value: 1)])
        let second = NativeExactUnsentOperation.ReadbackSample(value: literal, selectedText: "",
            caret: NSRange(location: literal.utf16.count, length: 0), attributed: changed)
        let a = try NativeExactUnsentOperation.requireExactReadback(first, literal: literal)
        let b = try NativeExactUnsentOperation.requireExactReadback(second, literal: literal)
        #expect(!a.matches(b))
    }

    @Test func focusCoverageRejectsMissingUnknownDuplicatedOrReorderedEffects() {
        typealias Focus = NativeOriginalWindowFocus
        let activated = Focus.ExactStepFact(step: .activateOriginal, state: .returned)
        let raised = Focus.ExactStepFact(step: .raiseOriginal, state: .returned)
        let pending = Focus.ExactStepFact(step: .raiseOriginal, state: .admitted)
        #expect(Focus.exactCoverageIsComplete(disposition: .alreadyFocused, steps: []))
        #expect(Focus.exactCoverageIsComplete(disposition: .restored, steps: [activated, raised]))
        #expect(Focus.exactCoverageIsComplete(disposition: .restored, steps: [raised]))
        #expect(!Focus.exactCoverageIsComplete(disposition: .alreadyFocused, steps: [raised]))
        #expect(!Focus.exactCoverageIsComplete(disposition: .restored, steps: []))
        #expect(!Focus.exactCoverageIsComplete(disposition: .restored, steps: [activated]))
        #expect(!Focus.exactCoverageIsComplete(disposition: .restored, steps: [raised, activated]))
        #expect(!Focus.exactCoverageIsComplete(disposition: .restored, steps: [activated, raised, raised]))
        #expect(!Focus.exactCoverageIsComplete(disposition: .restored, steps: [activated, pending]))
        #expect(!Focus.exactCoverageIsComplete(disposition: .uncertain, steps: [activated, raised]))
        #expect(!Focus.exactCoverageIsComplete(disposition: .refused, steps: []))
    }

    enum RangeMismatch: Sendable, Equatable { case graphemeCount, selection, selectedText, extraText }
}
