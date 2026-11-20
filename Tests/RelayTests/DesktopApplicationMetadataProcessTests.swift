import Foundation
import Testing
@testable import Relay

/// Actual-used raw-fact/lifetime predicates only. These tests create no
/// NSRunningApplication binding, lexical process lease, AX source or input grant.
nonisolated struct DesktopApplicationMetadataProcessTests {
    private typealias Facts = DesktopApplicationTarget.MetadataProcessFacts
    private typealias State = DesktopApplicationTarget.MetadataProcessState
    private typealias Failure = DesktopApplicationTarget.MetadataProcessFailure
    private func facts(pid: Int32 = 42, start: Double = 10,
                       bundle: String = "com.example.Owned", rawURL: String = "file:///Applications/Owned.app/",
                       file: Bool = true, terminated: Bool = false) -> Facts {
        Facts(processID: pid, launchedAt: Date(timeIntervalSince1970: start),
            bundleIDUTF8: Data(bundle.utf8), rawBundleURLUTF8: Data(rawURL.utf8),
            isFileURL: file, terminated: terminated)
    }
    @Test func unchangedActualPredicateDoesNotSpendAnActionOrImposeAQueryCountLimit() throws {
        let original = facts(), state = State()
        for _ in 0..<1_100 { try state.validate(expected: original, retained: original, secondRead: original) }
        try state.requireActive()
    }
    enum Change: CaseIterable, Sendable { case pid, reusedPIDStart, bundle, rawPath, rawAlias, nonFile, terminated, missingLaunch, invalidPID }
    @Test(arguments: Change.allCases)
    func eitherIndependentRetainedPropertyReadDriftRefuses(_ change: Change) throws {
        let original = facts(), state = State()
        let changed: Facts = switch change {
        case .pid: facts(pid: 43)
        case .reusedPIDStart: facts(start: 11)
        case .bundle: facts(bundle: "com.example.Other")
        case .rawPath: facts(rawURL: "file:///Applications/Other.app/")
        case .rawAlias: facts(rawURL: "file:///Applications/../Applications/Owned.app/")
        case .nonFile: facts(file: false)
        case .terminated: facts(terminated: true)
        case .missingLaunch: facts(start: .nan)
        case .invalidPID: facts(pid: 0)
        }
        #expect(throws: Failure.changed) { try state.validate(expected: original, retained: changed, secondRead: original) }
        #expect(throws: Failure.changed) { try state.validate(expected: original, retained: original, secondRead: changed) }
        // Refusing a mismatch supplies no new process/source and does not
        // silently change the immutable expected original to the replacement.
        try state.validate(expected: original, retained: original, secondRead: original)
    }
    @Test(arguments: [true, false])
    func missingEitherActualPropertySampleNeverBecomesSupportedAbsence(_ retainedMissing: Bool) {
        let original = facts(), state = State()
        #expect(throws: Failure.changed) {
            try state.validate(expected: original, retained: retainedMissing ? nil : original,
                secondRead: retainedMissing ? original : nil)
        }
    }
    @Test func canonicalEquivalentStringsCannotReplaceExactRawBundleFacts() throws {
        let nfc = "file:///Applications/Caf\u{00e9}.app/", nfd = "file:///Applications/Cafe\u{0301}.app/"
        #expect(nfc == nfd && !Data(nfc.utf8).elementsEqual(Data(nfd.utf8)))
        let original = facts(rawURL: nfc), changed = facts(rawURL: nfd), state = State()
        #expect(throws: Failure.changed) { try state.validate(expected: original, retained: changed, secondRead: changed) }
        let bundleNFC = facts(bundle: "com.example.Caf\u{00e9}"), bundleNFD = facts(bundle: "com.example.Cafe\u{0301}")
        #expect(throws: Failure.changed) { try state.validate(expected: bundleNFC, retained: bundleNFD, secondRead: bundleNFD) }
    }
    @Test func retirementRefusesBeforeAnotherFactsReadAndNeverRenewsTheSameState() throws {
        let original = facts(); var state = State(); var reads = 0
        try state.requireActive(); reads += 1
        try state.validate(expected: original, retained: original, secondRead: original)
        state.retire()
        #expect(throws: Failure.expired) { try state.requireActive(); reads += 1 }
        #expect(throws: Failure.expired) { try state.validate(expected: original, retained: original, secondRead: original) }
        state.retire()
        #expect(throws: Failure.expired) { try state.requireActive() }
        #expect(reads == 1)
    }
    @Test func invalidExpectedMetadataCannotBecomeAProcessIdentityEvenWhenBothReadersAgree() {
        let invalid = facts(pid: 0), state = State()
        #expect(throws: Failure.changed) { try state.validate(expected: invalid, retained: invalid, secondRead: invalid) }
    }
    @Test(arguments: [UInt64(0), 10, 11])
    func exactLiveKernelStartCannotBeMissingZeroOrReplaced(_ observed: UInt64) {
        let state = State()
        if observed == 10 { #expect(throws: Never.self) { try state.validateKernel(expected: 10, observed: observed) } }
        else { #expect(throws: Failure.changed) { try state.validateKernel(expected: 10, observed: observed) } }
        #expect(throws: Failure.changed) { try state.validateKernel(expected: 10, observed: nil) }
        #expect(throws: Failure.changed) { try state.validateKernel(expected: 0, observed: observed) }
        var retired = State(); retired.retire()
        #expect(throws: Failure.expired) { try retired.validateKernel(expected: 10, observed: 10) }
    }

}
