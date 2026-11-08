import AppKit
import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor struct NativeFocusedAXInsertionTests {
    @Test func exactUnicodeReplacesOnlyTheOriginalSelectionWithOneWrite() throws {
        let rig = FocusedInsertionRig(value: "ab🌍cd", selection: NSRange(location: 2, length: 2))
        let binding = try rig.binding(), literal = "cafe\u{301} 🌏"
        let insertion = try binding.prepare(literal)
        #expect(insertion.selection == NSRange(location: 2, length: 2))
        #expect(insertion.literalText?.utf16.elementsEqual(literal.utf16) == true)
        #expect(binding.execute(insertion, authorization: rig.authorization) == .inserted)
        #expect(rig.value.utf16.elementsEqual(("ab" + literal + "cd").utf16))
        #expect(rig.writes.count == 1 && rig.consumeCount == 1)
        #expect(insertion.literalText == nil)
        #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.consumed))
        #expect(rig.writes.count == 1 && rig.consumeCount == 1)
    }

    @Test func zeroLengthCaretCanInsertWithoutResettingTheSelection() throws {
        let rig = FocusedInsertionRig(value: "before🌍after", selection: NSRange(location: 6, length: 0))
        let binding = try rig.binding(), insertion = try binding.prepare("café")
        #expect(binding.execute(insertion, authorization: rig.authorization) == .inserted)
        #expect(rig.value.utf16.elementsEqual("beforecafé🌍after".utf16))
        #expect(rig.writes == ["café"])
    }

    @Test func UTF16RangeValidationRejectsBothHalvesOfASurrogatePair() {
        for range in [NSRange(location: 2, length: 0), NSRange(location: 1, length: 1), NSRange(location: 2, length: 1),
                      NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: Int.max)] {
            #expect(throws: NativeFocusedAXInsertion.Failure.invalidSelection) {
                try NativeFocusedAXInsertion.expectedValue(value: "a🌍b", selection: range, selectedText: "", literal: "x", multiline: true)
            }
        }
    }

    @Test func selectedTextMustMatchTheLiteralOriginalUTF16Slice() {
        #expect(throws: NativeFocusedAXInsertion.Failure.invalidSelection) {
            try NativeFocusedAXInsertion.expectedValue(value: "cafe\u{301}", selection: NSRange(location: 0, length: 5), selectedText: "café", literal: "x", multiline: true)
        }
    }

    @Test func exactComposedAndDecomposedInsertionsAreNeverNormalized() throws {
        for literal in ["café", "cafe\u{301}", "🌍", "你好"] {
            let expected = try NativeFocusedAXInsertion.expectedValue(value: "LR", selection: NSRange(location: 1, length: 0), selectedText: "", literal: literal, multiline: true)
            #expect(expected.utf16.elementsEqual(("L" + literal + "R").utf16))
        }
    }

    @Test func multilineSelectedTextIsLiteralAndNeverAKeyOrSubmitAction() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), literal = "café\n\t🌍"
        #expect(binding.execute(try binding.prepare(literal), authorization: rig.authorization) == .inserted)
        #expect(rig.writes == [literal] && rig.value.utf16.elementsEqual(literal.utf16))
        #expect(throws: NativeFocusedAXInsertion.Failure.invalidText) {
            try NativeFocusedAXInsertion.expectedValue(value: "", selection: .init(location: 0, length: 0), selectedText: "", literal: literal, multiline: false)
        }
    }

    @Test func controlCharactersEmptyAndOversizedInsertionsRefuseBeforeAuthorization() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding()
        for text in ["", "a\0b", "a\u{7f}b", "a\u{85}b", String(repeating: "a", count: 4097)] {
            #expect(throws: NativeFocusedAXInsertion.Failure.invalidText) { try binding.prepare(text) }
        }
        #expect(rig.writes.isEmpty && rig.consumeCount == 0)
    }

    @Test func protectedHiddenUnknownDisabledAndUnwritableMetadataRefuseBeforeContents() {
        for denied in [FocusedInsertionRig.metadata(protected: true), FocusedInsertionRig.metadata(protected: nil),
                       FocusedInsertionRig.metadata(hidden: true), FocusedInsertionRig.metadata(hidden: nil),
                       FocusedInsertionRig.metadata(enabled: false), FocusedInsertionRig.metadata(enabled: nil),
                       FocusedInsertionRig.metadata(writable: false), FocusedInsertionRig.metadata(role: "AXSecureTextField"),
                       FocusedInsertionRig.metadata(subrole: "AXSearchField"), FocusedInsertionRig.metadata(subrole: "AXPasswordField")] {
            let rig = FocusedInsertionRig(); rig.metadata = denied
            #expect(throws: NativeFocusedAXInsertion.Failure.unavailableEditor) { try rig.binding() }
            #expect(rig.contentReads == 0 && rig.writes.isEmpty)
        }
    }

    @Test func attributedSnapshotMustCoverTheExactWholeField() {
        let rig = FocusedInsertionRig(); rig.attributedOverride = NSAttributedString(string: "different")
        #expect(throws: NativeFocusedAXInsertion.Failure.unavailableEditor) { try rig.binding() }
        #expect(rig.writes.isEmpty)
    }

    @Test func hierarchyPrivacyRefusesBeforeDescriptionTitleOrPlaceholderReads() {
        for denied in [("AXTextArea", "", true, false), ("AXTextArea", "", false, true),
                       ("AXSecureTextField", "", false, false), ("AXTextField", "AXPasswordField", false, false)] {
            var labelReads = 0
            #expect(throws: NativeFocusedAXInsertion.Failure.unavailableEditor) {
                try NativeFocusedAXInsertion.hierarchyLabel(role: denied.0, subrole: denied.1, protected: denied.2, hidden: denied.3, readLabel: {
                    labelReads += 1; return "must not be read"
                })
            }
            #expect(labelReads == 0)
        }
    }

    @Test func admittedHierarchyNodesStillRequireTheProtectedControlLabelChecks() {
        var reads = 0
        #expect(throws: NativeFocusedAXInsertion.Failure.unavailableEditor) {
            try NativeFocusedAXInsertion.hierarchyLabel(role: "AXTextArea", subrole: "", protected: false, hidden: false, readLabel: {
                reads += 1; return "Recovery phrase"
            })
        }
        #expect(reads == 1)
    }

    @Test func captureRequiresTwoIdenticalOriginalReads() {
        let rig = FocusedInsertionRig()
        rig.onContents = { if rig.contentReads == 2 { rig.value = "changed" } }
        #expect(throws: NativeFocusedAXInsertion.Failure.changedSource) { try rig.binding() }
        #expect(rig.writes.isEmpty)
    }

    @Test func sourceBytesAndSelectionDriftBeforeDispatchRefuseWithoutConsumingReview() throws {
        for changesSelection in [false, true] {
            let rig = FocusedInsertionRig(value: "old", selection: NSRange(location: 3, length: 0))
            let binding = try rig.binding(), insertion = try binding.prepare("🌍")
            if changesSelection { rig.selection = NSRange(location: 0, length: 0) } else { rig.value = "new" }
            #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.changedSource))
            #expect(rig.writes.isEmpty && rig.consumeCount == 0)
        }
    }

    @Test func originalTargetValidationRefusesBeforeAnyFurtherFieldRead() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        let reads = rig.contentReads
        rig.identityCurrent = false
        #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.changedSource))
        #expect(rig.writes.isEmpty && rig.consumeCount == 0 && rig.contentReads == reads)
    }

    @Test func taskSourceAndExactReviewMustStillBeAuthorizedAtDispatch() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.authorized = false
        #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.authorizationChanged))
        #expect(rig.writes.isEmpty && rig.consumeCount == 0)
    }

    @Test func policyConsumptionCannotChangeSourceOrOutliveTheAdmissionDeadline() throws {
        for expires in [false, true] {
            let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
            rig.onConsume = { if expires { rig.clock = rig.clock.advanced(by: .seconds(3)) } else { rig.value = "other" } }
            #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(expires ? .expired : .changedSource))
            #expect(rig.writes.isEmpty && rig.consumeCount == 1)
            #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.consumed))
            #expect(rig.consumeCount == 1)
        }
    }

    @Test func stopOrInactiveSourceBeforeFinalAdmissionProducesNoWrite() throws {
        for stops in [false, true] {
            let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
            rig.onConsume = { if stops { binding.stop() } else { rig.active = false } }
            #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(stops ? .stopped : .inactive))
            #expect(rig.writes.isEmpty && insertion.literalText == nil)
        }
    }

    @Test func cancellationBeforeMainActorAdmissionMakesNoWriteOrPolicyConsumption() async throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        let operation = Task { @MainActor in binding.execute(insertion, authorization: rig.authorization) }
        operation.cancel()
        #expect(await operation.value == .notDispatched(.cancelled))
        #expect(rig.writes.isEmpty && rig.consumeCount == 0)
    }

    @Test func policyRevocationDuringConsumptionIsNotAnAttemptedEdit() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.onConsume = { rig.authorized = false }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.authorizationChanged))
        #expect(rig.writes.isEmpty && rig.consumeCount == 1)
    }

    @Test func consumedReviewIsNeverRevalidatedAsAnUnusedPermit() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        #expect(binding.execute(insertion, authorization: rig.authorization) == .inserted)
        #expect(rig.reviewConsumed && rig.consumeCount == 1 && rig.writes.count == 1)
    }

    @Test func canonicallyEquivalentSourceDriftIsStillDifferentLiteralBytes() throws {
        let rig = FocusedInsertionRig(value: "cafe\u{301}"), binding = try rig.binding(), insertion = try binding.prepare("x")
        rig.value = "café"
        #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.changedSource))
        #expect(rig.writes.isEmpty && rig.consumeCount == 0)
    }

    @Test func normalizedOrPartialReadbackIsUncertainAndNeverRetried() throws {
        for actual in ["café", "cafe"] {
            let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("cafe\u{301}")
            rig.afterWrite = { rig.value = actual; rig.selection = NSRange(location: actual.utf16.count, length: 0) }
            #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(.readbackMismatch))
            #expect(rig.writes.count == 1 && rig.consumeCount == 1)
            #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.consumed))
            #expect(rig.writes.count == 1)
        }
    }

    @Test func rejectedWriteOrLostReadbackCannotBeReportedAsNoEffect() throws {
        for rejectsWrite in [false, true] {
            let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
            if rejectsWrite { rig.rejectWrite = true } else { rig.afterWrite = { rig.identityCurrent = false } }
            #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(rejectsWrite ? .writeRejected : .readbackUnavailable))
            #expect(rig.writes.count == 1)
        }
    }

    @Test func postWriteEditorMetadataDriftCannotBecomeVerifiedSuccess() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.afterWrite = { rig.metadata = FocusedInsertionRig.metadata(role: "AXTextField") }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(.readbackUnavailable))
        #expect(rig.writes.count == 1 && rig.consumeCount == 1)
    }

    @Test func taskRevocationByTheWritePreventsAnyPrivateReadbackEvenWhenTheTextMatches() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        var readsAtWrite = -1
        rig.afterWrite = { readsAtWrite = rig.contentReads; rig.authorized = false }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(.readbackUnavailable))
        #expect(rig.value.utf16.elementsEqual("🌍".utf16) && rig.writes.count == 1)
        #expect(rig.contentReads == readsAtWrite)
        #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.consumed))
        #expect(rig.writes.count == 1)
    }

    @Test func revocationDuringReadbackCannotReturnInserted() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.afterWrite = { rig.onContents = { rig.authorized = false } }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(.readbackUnavailable))
        #expect(rig.writes.count == 1)
    }

    @Test func stopOrTimeoutAfterAdmittedWriteRemainsUncertain() throws {
        for stops in [false, true] {
            let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("🌍")
            rig.afterWrite = { if stops { binding.stop() } else { rig.clock = rig.clock.advanced(by: .seconds(3)) } }
            #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(stops ? .stoppedAfterDispatch : .expiredAfterDispatch))
            #expect(rig.writes.count == 1 && rig.consumeCount == 1)
        }
    }

    @Test func unchangedLiteralDoesNotDispatchOrConsumePolicy() throws {
        let rig = FocusedInsertionRig(value: "café", selection: NSRange(location: 0, length: 4)), binding = try rig.binding()
        #expect(binding.execute(try binding.prepare("café"), authorization: rig.authorization) == .unchanged)
        #expect(rig.writes.isEmpty && rig.consumeCount == 0)
    }

    @Test func foreignOrSupersededPreparedInsertionsCannotDispatch() throws {
        let rig = FocusedInsertionRig(), other = FocusedInsertionRig(), binding = try rig.binding(), otherBinding = try other.binding()
        let old = try binding.prepare("old"), current = try binding.prepare("new")
        #expect(old.literalText == nil)
        #expect(binding.execute(old, authorization: rig.authorization) == .notDispatched(.consumed))
        #expect(otherBinding.execute(current, authorization: other.authorization) == .notDispatched(.wrongOwner))
        #expect(binding.execute(current, authorization: rig.authorization) == .inserted)
        #expect(rig.writes == ["new"] && other.writes.isEmpty)
    }

    @Test func stopClearsPreparedSourceAndLiteralWithoutCapturingOnResume() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("synthetic")
        let reads = rig.contentReads
        binding.stop(); binding.stop()
        #expect(insertion.literalText == nil && rig.contentReads == reads && rig.writes.isEmpty)
        #expect(throws: NativeFocusedAXInsertion.Failure.stopped) { try binding.prepare("later") }
    }

    @Test func anInactiveSessionClearsThePendingLiteralAndRequiresAFreshBinding() throws {
        let rig = FocusedInsertionRig(), binding = try rig.binding(), insertion = try binding.prepare("synthetic")
        let reads = rig.contentReads
        rig.active = false
        #expect(throws: NativeFocusedAXInsertion.Failure.inactive) { try binding.prepare("other") }
        #expect(insertion.literalText == nil && rig.contentReads == reads && rig.writes.isEmpty)
        rig.active = true
        #expect(throws: NativeFocusedAXInsertion.Failure.stopped) { try binding.prepare("later") }
    }

    @Test func mixedFontsRemainExactOutsideTheSelectionWhileInsertedGlyphFallbackIsAllowed() throws {
        let rig = FocusedInsertionRig(value: "Left 🌍 right", selection: NSRange(location: 5, length: 2))
        rig.storage.addAttribute(.init("AXFont"), value: FocusedInsertionRig.font("Helvetica-Bold", size: 16), range: .init(location: 0, length: 4))
        rig.storage.addAttribute(.init("AXFont"), value: FocusedInsertionRig.font("Courier", size: 14), range: .init(location: 8, length: 5))
        let binding = try rig.binding(), literal = "cafe\u{301} 你好 🌏", insertion = try binding.prepare(literal)
        rig.afterWrite = {
            rig.storage.addAttribute(.init("AXFont"), value: FocusedInsertionRig.font("SyntheticFallback"), range: .init(location: 5, length: literal.utf16.count))
        }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .inserted)
        #expect(rig.value.utf16.elementsEqual(("Left " + literal + " right").utf16))
        #expect(binding.verifiedCaret == insertion.expectedCaret && rig.selection == insertion.expectedCaret)
        #expect(rig.writes.count == 1 && rig.consumeCount == 1)
    }

    @Test func preWriteStyleDriftRefusesWithoutInputOrReviewConsumption() throws {
        let rig = FocusedInsertionRig(value: "source", selection: .init(location: 3, length: 0)), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.storage.addAttribute(.init("AXFont"), value: FocusedInsertionRig.font("Helvetica-Bold"), range: .init(location: 0, length: 1))
        #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.changedSource))
        #expect(rig.writes.isEmpty && rig.consumeCount == 0)
    }

    @Test func reviewConsumptionCannotHideLateSourceStyleDrift() throws {
        let rig = FocusedInsertionRig(value: "source", selection: .init(location: 3, length: 0)), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.onConsume = { rig.storage.addAttribute(.init("AXUnderline"), value: NSNumber(value: 1), range: .init(location: 0, length: 1)) }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.changedSource))
        #expect(rig.writes.isEmpty && rig.consumeCount == 1)
    }

    @Test func changedPrefixOrShiftedSuffixFormattingIsUncertainWithNoReplay() throws {
        for changesPrefix in [true, false] {
            let rig = FocusedInsertionRig(value: "prefix old suffix", selection: .init(location: 7, length: 3)), binding = try rig.binding(), insertion = try binding.prepare("🌍")
            rig.afterWrite = {
                let index = changesPrefix ? 0 : 10
                rig.storage.addAttribute(.init("AXFont"), value: FocusedInsertionRig.font("Courier", size: 15), range: .init(location: index, length: 1))
            }
            #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(.formattingChanged))
            #expect(rig.writes.count == 1 && binding.verifiedCaret == nil)
            #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.consumed))
            #expect(rig.writes.count == 1)
        }
    }

    @Test func linksAttachmentsCustomAnnotationsAndUnknownAttributesCannotEnterTheBinding() {
        for key in ["AXLink", "NSLink", "AXAttachment", "NSAttachment", "AXAnnotation", "UnknownUnsafeAttribute"] {
            let rig = FocusedInsertionRig(value: "source")
            rig.storage.addAttribute(.init(key), value: "opaque unqualified metadata", range: .init(location: 0, length: 1))
            #expect(throws: NativeFocusedAXInsertion.Failure.unavailableEditor) { try rig.binding() }
            #expect(rig.writes.isEmpty)
        }
    }

    @Test func unsafeInsertedAttributesMakeTheAttemptUncertainEvenWhenTextMatches() throws {
        let rig = FocusedInsertionRig(value: "LR", selection: .init(location: 1, length: 0)), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.afterWrite = { rig.storage.addAttribute(.init("AXLink"), value: "unsafe", range: .init(location: 1, length: 2)) }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(.readbackUnavailable))
        #expect(rig.writes.count == 1 && binding.verifiedCaret == nil)
    }

    @Test func exactAttributeNumbersDoNotUseAFloatingPointTolerance() throws {
        let rig = FocusedInsertionRig(value: "source"), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.storage.addAttribute(.init("AXFont"), value: FocusedInsertionRig.font("Helvetica", size: Double(12).nextUp), range: .init(location: 0, length: 1))
        #expect(binding.execute(insertion, authorization: rig.authorization) == .notDispatched(.changedSource))
        #expect(rig.writes.isEmpty)
    }

    @Test func exactColorComponentsAndColorSpaceArePreserved() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let original = try #require(CGColor(colorSpace: space, components: [0.25, 0.5, 0.75, 1]))
        let changed = try #require(CGColor(colorSpace: space, components: [CGFloat(0.25).nextUp, 0.5, 0.75, 1]))
        let rig = FocusedInsertionRig(value: "LR", selection: .init(location: 1, length: 0))
        rig.storage.addAttribute(.init("AXForegroundColor"), value: original, range: .init(location: 0, length: 2))
        let binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.afterWrite = { rig.storage.addAttribute(.init("AXForegroundColor"), value: changed, range: .init(location: 0, length: 1)) }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(.formattingChanged))
        #expect(rig.writes.count == 1)
    }

    @Test func wrongResultingCaretIsRecordedAsUncertainWithoutResettingIt() throws {
        let rig = FocusedInsertionRig(value: "LR", selection: .init(location: 1, length: 0)), binding = try rig.binding(), insertion = try binding.prepare("🌍")
        rig.afterWrite = { rig.selection = .init(location: 0, length: 0) }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(.caretMismatch))
        #expect(rig.selection == NSRange(location: 0, length: 0) && binding.verifiedCaret == nil)
        #expect(rig.writes.count == 1)
    }

    @Test func fragmentedOversizedAndInvalidAttributeProofsRefuseBeforeInput() {
        let fragmented = FocusedInsertionRig(value: String(repeating: "a", count: 257))
        for index in 0..<257 {
            fragmented.storage.addAttribute(.init("AXFont"), value: FocusedInsertionRig.font(index.isMultiple(of: 2) ? "Helvetica" : "Courier"), range: .init(location: index, length: 1))
        }
        #expect(throws: NativeFocusedAXInsertion.Failure.unavailableEditor) { try fragmented.binding() }
        for font in [FocusedInsertionRig.font("Helvetica", size: .nan), FocusedInsertionRig.font(String(repeating: "x", count: 513)),
                     ["AXFontName": "Helvetica", "AXFontSize": NSNumber(value: true)]] {
            let rig = FocusedInsertionRig(value: "source")
            rig.storage.addAttribute(.init("AXFont"), value: font, range: .init(location: 0, length: 1))
            #expect(throws: NativeFocusedAXInsertion.Failure.unavailableEditor) { try rig.binding() }
            #expect(rig.writes.isEmpty)
        }
    }

    @Test func gateRevocationDuringMetadataPreventsAFieldReadAtCaptureAndAfterWriting() throws {
        let captureGate = NativeInputRevocation(), capture = FocusedInsertionRig()
        capture.onMetadata = { captureGate.revoke() }
        #expect(throws: NativeFocusedAXInsertion.Failure.stopped) { try capture.binding(gate: captureGate) }
        #expect(capture.contentReads == 0 && capture.writes.isEmpty)

        let gate = NativeInputRevocation(), rig = FocusedInsertionRig()
        let binding = try rig.binding(gate: gate), insertion = try binding.prepare("🌍")
        var readsAtWrite = -1
        rig.afterWrite = { readsAtWrite = rig.contentReads; rig.onMetadata = { gate.revoke() } }
        #expect(binding.execute(insertion, authorization: rig.authorization) == .uncertain(.readbackUnavailable))
        #expect(rig.writes.count == 1 && rig.contentReads == readsAtWrite && binding.verifiedCaret == nil)
    }
}

@MainActor private final class FocusedInsertionRig {
    let storage: NSMutableAttributedString
    var value: String {
        get { storage.string }
        set { storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newValue) }
    }
    var selection: NSRange
    var metadata = metadata()
    var active = true, identityCurrent = true, authorized = true, rejectWrite = false, reviewConsumed = false
    var attributedOverride: NSAttributedString?
    var contentReads = 0, metadataReads = 0, consumeCount = 0
    var writes: [String] = []
    var clock = ContinuousClock.now
    var onMetadata: (() -> Void)?, onContents: (() -> Void)?, onConsume: (() -> Void)?, afterWrite: (() -> Void)?
    init(value: String = "", selection: NSRange = NSRange(location: 0, length: 0)) {
        storage = NSMutableAttributedString(string: value, attributes: [NSAttributedString.Key("AXFont"): Self.font("Helvetica", size: 12)])
        self.selection = selection
    }
    static func font(_ name: String, size: Double = 12) -> [String: Any] {
        ["AXFontName": name, "AXFontSize": NSNumber(value: size)]
    }
    static func metadata(role: String = "AXTextArea", subrole: String = "", protected: Bool? = false,
                         hidden: Bool? = false, enabled: Bool? = true, writable: Bool = true) -> NativeFocusedAXInsertion.Metadata {
        .init(role: role, subrole: subrole, protected: protected, hidden: hidden, enabled: enabled, selectionWritable: writable)
    }
    var selectedText: String {
        let units = Array(value.utf16)
        guard selection.location >= 0, selection.length >= 0, selection.location <= units.count,
              selection.length <= units.count - selection.location else { return "" }
        return String(decoding: units[selection.location..<(selection.location + selection.length)], as: UTF16.self)
    }
    func binding(gate: NativeInputRevocation? = nil) throws -> NativeFocusedAXInsertion {
        try .init(access: .init(validateOriginalTarget: { [self] in
            guard identityCurrent else { throw NativeFocusedAXInsertion.Failure.changedSource }
        }, metadata: { [self] in metadataReads += 1; onMetadata?(); return metadata }, contents: { [self] in
            contentReads += 1; onContents?()
            return .init(value: value, selection: selection, selectedText: selectedText, attributedValue: attributedOverride ?? storage)
        }, writeSelectedText: { [self] literal in
            writes.append(literal)
            if rejectWrite { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
            let start = selection.location
            _ = try NativeFocusedAXInsertion.expectedValue(value: value, selection: selection, selectedText: selectedText, literal: literal, multiline: metadata.role == "AXTextArea")
            storage.replaceCharacters(in: selection, with: literal)
            selection = NSRange(location: start + literal.utf16.count, length: 0)
            afterWrite?()
        }), sessionIsActive: { [self] in active }, admissionGate: gate, now: { [self] in clock })
    }
    var authorization: NativeFocusedAXInsertion.Authorization {
        .init(validateTaskSource: { [self] in
            guard authorized else { throw TestAuthorization.denied }
        }, revalidate: { [self] in
            guard authorized, !reviewConsumed else { throw TestAuthorization.denied }
        }, consume: { [self] in
            guard authorized, !reviewConsumed else { throw TestAuthorization.denied }
            reviewConsumed = true; consumeCount += 1; onConsume?()
        })
    }
    enum TestAuthorization: Error { case denied }
}
