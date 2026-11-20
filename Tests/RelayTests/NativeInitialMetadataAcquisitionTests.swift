import Foundation
import Testing
@testable import Relay

/// Actual acquisition/comparison/owner algorithms with inert metadata only.
/// No fake survey, source permission, AX object or input capability is minted.
@MainActor @Suite struct NativeInitialMetadataAcquisitionTests {
    private struct Row { let node: Int; let children: [Int] }
    private struct Snapshot {
        let digest: Data
        let rows: [Row]
        let capture: Int
    }
    private struct Source { let id: UUID; let app: Int; let window: Int; let imageRevision: Int }
    private final class Owner { let logicalID: UUID; init(_ id: UUID = UUID()) { logicalID = id } }
    private enum Failure: Error, Equatable { case source }

    private func snapshot(_ value: UInt8, capture: Int = 0) -> Snapshot {
        Snapshot(digest: Data([value]), rows: [Row(node: 0, children: [1]), Row(node: 1, children: [])], capture: capture)
    }
    private func comparison(_ first: Snapshot, _ second: Snapshot) -> NativeInitialMetadataAcquisition.CompletedComparison {
        NativeOrderedMetadataComparison.matches(firstDigest: first.digest, secondDigest: second.digest,
            firstRows: first.rows, secondRows: second.rows, node: { $0.node }, children: { $0.children },
            identical: { $0 == $1 }) ? .equal : .mismatch
    }
    private func sameWindow(_ first: Source, _ second: Source) -> Bool {
        first.app == second.app && first.window == second.window
    }

    @Test func equalConsecutivePairReturnsTheSecondCurrentCaptureAndCannotBeReused() throws {
        let acquisition = NativeInitialMetadataAcquisition()
        var calls = 0
        let current = try acquisition.acquire(validate: {}, capture: {
            calls += 1; return snapshot(1, capture: calls)
        }, compare: comparison)
        #expect(current.capture == 2 && calls == 2 && acquisition.captureCount == 2)
        #expect(acquisition.hasStarted)
        #expect(throws: NativeInitialMetadataAcquisition.Failure.alreadyUsed) {
            try acquisition.acquire(validate: {}, capture: { calls += 1; return snapshot(1) }, compare: comparison)
        }
        #expect(calls == 2)
    }

    @Test func completedMismatchMayUseOnlyOneThirdCaptureAndMustMatchItsImmediatePredecessor() throws {
        let acquisition = NativeInitialMetadataAcquisition()
        var calls = 0
        let current = try acquisition.acquire(validate: {}, capture: {
            calls += 1; return snapshot(calls == 1 ? 1 : 2, capture: calls)
        }, compare: comparison)
        #expect(current.capture == 3 && current.digest == Data([2]) && calls == 3)
        let unstableSequences: [[UInt8]] = [[1,2,3], [1,2,1]]
        for values in unstableSequences {
            let rejected = NativeInitialMetadataAcquisition()
            var index = 0
            #expect(throws: NativeInitialMetadataAcquisition.Failure.unstable) {
                try rejected.acquire(validate: {}, capture: {
                    let value = values[index]; index += 1; return snapshot(value)
                }, compare: comparison)
            }
            #expect(index == 3 && rejected.captureCount == 3)
        }
    }

    @Test func existingComparisonKeepsOrderedNodeAndChildIdentityAlongsideDigest() {
        let first = Snapshot(digest: Data([1]), rows: [Row(node: 0, children: [1,2]), Row(node: 1, children: []), Row(node: 2, children: [])], capture: 1)
        let variants = [
            Snapshot(digest: Data([1]), rows: [Row(node: 0, children: [1,2]), Row(node: 9, children: []), Row(node: 2, children: [])], capture: 2),
            Snapshot(digest: Data([1]), rows: [Row(node: 0, children: [2,1]), Row(node: 1, children: []), Row(node: 2, children: [])], capture: 2),
            Snapshot(digest: Data([1]), rows: [Row(node: 0, children: [1]), Row(node: 1, children: []), Row(node: 2, children: [])], capture: 2),
            Snapshot(digest: Data([1]), rows: Array(first.rows.reversed()), capture: 2),
            Snapshot(digest: Data([1]), rows: Array(first.rows.dropLast()), capture: 2),
            Snapshot(digest: Data([2]), rows: first.rows, capture: 2)
        ]
        for changed in variants {
            let changedMatches = NativeOrderedMetadataComparison.matches(firstDigest: first.digest, secondDigest: changed.digest,
                firstRows: first.rows, secondRows: changed.rows, node: { $0.node }, children: { $0.children }, identical: { $0 == $1 })
            #expect(!changedMatches)
        }
        let identicalMatches = NativeOrderedMetadataComparison.matches(firstDigest: first.digest, secondDigest: first.digest,
            firstRows: first.rows, secondRows: first.rows, node: { $0.node }, children: { $0.children }, identical: { $0 == $1 })
        #expect(identicalMatches)
    }

    @Test(arguments: [1,2,3])
    func everyCaptureErrorStopsImmediatelyAndNeverBecomesAComparisonMismatch(_ failingCapture: Int) {
        let errors: [NativeOrdinaryWindowPolicySource.Failure] = [.protectedContext, .dedicatedContext, .unavailable, .incomplete, .changedContext]
        for error in errors {
            let acquisition = NativeInitialMetadataAcquisition()
            var calls = 0, comparisons = 0
            #expect(throws: error) {
                try acquisition.acquire(validate: {}, capture: {
                    calls += 1
                    if calls == failingCapture { throw error }
                    return snapshot(UInt8(calls))
                }, compare: { first, second in comparisons += 1; return comparison(first, second) })
            }
            #expect(calls == failingCapture)
            #expect(comparisons == max(0, failingCapture - 2))
            #expect(acquisition.hasStarted)
        }
    }

    @Test func sourceBudgetAndOriginal750MillisecondDeadlineCannotRenewBetweenCandidates() {
        var alive = true, calls = 0
        let source = NativeInitialMetadataAcquisition()
        #expect(throws: Failure.source) {
            try source.acquire(validate: { guard alive else { throw Failure.source } }, capture: {
                calls += 1; alive = false; return snapshot(1)
            }, compare: comparison)
        }
        #expect(calls == 1)

        var clock: TimeInterval = 0
        let budget = TaskRunBudget(activeLimit: 1, lifetimeLimit: 10, now: { clock })
        let limited = NativeInitialMetadataAcquisition()
        #expect(throws: TaskRunBudget.Limit.activeWork) {
            try limited.acquire(validate: budget.check, capture: {
                clock = 1; return snapshot(1)
            }, compare: comparison)
        }
        #expect(limited.captureCount == 1)

        let started = ContinuousClock.now, deadline = started.advanced(by: .milliseconds(750))
        var now = started
        let timed = NativeInitialMetadataAcquisition()
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try timed.acquire(validate: {
                try NativeStandardControlSurvey.requireMetadataDeadline(deadline, now: now)
            }, capture: { now = deadline; return snapshot(1) }, compare: comparison)
        }
        #expect(timed.captureCount == 1)
    }

    @Test func currentTaskCancellationAfterCaptureIsNotSwallowedOrRetried() async {
        let acquisition = NativeInitialMetadataAcquisition()
        let child = Task { @MainActor in
            #expect(throws: CancellationError.self) {
                try acquisition.acquire(validate: { try Task.checkCancellation() }, capture: {
                    withUnsafeCurrentTask { $0?.cancel() }; return snapshot(1)
                }, compare: comparison)
            }
        }
        await child.value
        #expect(acquisition.captureCount == 1)
    }

    @Test func taskWindowOwnerUsesStrictInspectionAfterFactsRegardlessOfWrapperOrImageRevision() throws {
        let owner = Owner(), registry = NativeInitialMetadataOwners<Source>(owner: owner), id = UUID()
        var initial = 0, strict = 0, captures = 0
        func inspect(_ source: Source, failStrict: Bool = false) throws -> Int {
            try registry.withSource(source, sourceID: source.id, owner: owner,
                sameOriginalWindow: sameWindow, validate: {}, initial: { acquisition, check in
                    initial += 1
                    return try acquisition.acquire(validate: check, capture: {
                        captures += 1; return snapshot(1)
                    }, compare: comparison).capture
                }, strict: {
                    strict += 1
                    if failStrict { throw NativeOrdinaryWindowPolicySource.Failure.changedContext }
                    return 7
                })
        }
        _ = try inspect(Source(id: id, app: 1, window: 10, imageRevision: 0))
        _ = try inspect(Source(id: id, app: 1, window: 10, imageRevision: 1))
        _ = try inspect(Source(id: UUID(), app: 1, window: 10, imageRevision: 2))
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.changedContext) {
            try inspect(Source(id: id, app: 1, window: 10, imageRevision: 3), failStrict: true)
        }
        #expect(initial == 1 && captures == 2 && strict == 3)
        // Distinct later wrappers never obtain a fresh automatic opportunity.
        for revision in 4..<1_029 {
            _ = try inspect(Source(id: UUID(), app: 1, window: 10, imageRevision: revision))
        }
        #expect(initial == 1 && captures == 2 && strict == 1_028)
    }

    @Test func failedInitialValidationOrCaptureCannotRemintAndForeignTaskOrWindowRefuses() throws {
        let logical = UUID(), owner = Owner(logical), foreign = Owner(logical)
        let registry = NativeInitialMetadataOwners<Source>(owner: owner), id = UUID()
        let original = Source(id: id, app: 1, window: 10, imageRevision: 0)
        var initial = 0, strict = 0
        #expect(throws: Failure.source) {
            try registry.withSource(original, sourceID: id, owner: owner,
                sameOriginalWindow: sameWindow, validate: { throw Failure.source },
                initial: { _,_ in initial += 1; return 1 }, strict: { strict += 1; return 2 })
        }
        _ = try registry.withSource(original, sourceID: id, owner: owner,
            sameOriginalWindow: sameWindow, validate: {}, initial: { _,_ in initial += 1; return 1 },
            strict: { strict += 1; return 2 })
        #expect(initial == 0 && strict == 1)
        #expect(throws: NativeVisualTaskFailure.staleTask) {
            try registry.withSource(original, sourceID: id, owner: foreign,
                sameOriginalWindow: sameWindow, validate: {}, initial: { _,_ in 1 }, strict: { 2 })
        }
        for changed in [Source(id: id, app: 1, window: 99, imageRevision: 1), Source(id: id, app: 2, window: 10, imageRevision: 1)] {
            #expect(throws: NativeVisualTaskFailure.staleProposal) {
                try registry.withSource(changed, sourceID: id, owner: owner,
                    sameOriginalWindow: sameWindow, validate: {}, initial: { _,_ in 1 }, strict: { 2 })
            }
        }
        registry.revoke()
        #expect(throws: NativeVisualTaskFailure.stopped) {
            try registry.withSource(original, sourceID: id, owner: owner,
                sameOriginalWindow: sameWindow, validate: {}, initial: { _,_ in 1 }, strict: { 2 })
        }
    }

    @Test func everyObservedAliasRefusesWindowOrProcessRetargetBeforeCallerWork() throws {
        let owner = Owner(), registry = NativeInitialMetadataOwners<Source>(owner: owner)
        let firstID = UUID(), aliasID = UUID()
        var initial = 0, strict = 0, validations = 0
        func inspect(_ source: Source) throws -> Int {
            try registry.withSource(source, sourceID: source.id, owner: owner,
                sameOriginalWindow: sameWindow, validate: { validations += 1 },
                initial: { _,_ in initial += 1; return 1 }, strict: { strict += 1; return 2 })
        }
        let first = try inspect(Source(id: firstID, app: 1, window: 10, imageRevision: 0))
        let alias = try inspect(Source(id: aliasID, app: 1, window: 10, imageRevision: 1))
        #expect(first == 1 && alias == 2 && initial == 1 && strict == 1)
        let before = validations
        for changed in [Source(id: aliasID, app: 1, window: 20, imageRevision: 2),
                        Source(id: aliasID, app: 2, window: 10, imageRevision: 2)] {
            #expect(throws: NativeVisualTaskFailure.staleProposal) { try inspect(changed) }
        }
        #expect(validations == before && initial == 1 && strict == 1)
        let current = try inspect(Source(id: aliasID, app: 1, window: 10, imageRevision: 3))
        #expect(current == 2 && initial == 1 && strict == 2)
    }

    @Test func failedAliasValidationCannotFreeItsIdentityOrRenewAcquisition() throws {
        let owner = Owner(), registry = NativeInitialMetadataOwners<Source>(owner: owner)
        let firstID = UUID(), aliasID = UUID()
        var initial = 0, strict = 0, validations = 0
        func inspect(_ source: Source, fail: Bool = false) throws -> Int {
            try registry.withSource(source, sourceID: source.id, owner: owner,
                sameOriginalWindow: sameWindow, validate: {
                    validations += 1
                    if fail { throw Failure.source }
                }, initial: { _,_ in initial += 1; return 1 }, strict: { strict += 1; return 2 })
        }
        _ = try inspect(Source(id: firstID, app: 1, window: 10, imageRevision: 0))
        #expect(throws: Failure.source) {
            try inspect(Source(id: aliasID, app: 1, window: 10, imageRevision: 1), fail: true)
        }
        let before = validations
        #expect(throws: NativeVisualTaskFailure.staleProposal) {
            try inspect(Source(id: aliasID, app: 1, window: 20, imageRevision: 2))
        }
        #expect(validations == before && initial == 1 && strict == 0)
        let current = try inspect(Source(id: aliasID, app: 1, window: 10, imageRevision: 3))
        #expect(current == 2 && initial == 1 && strict == 1)
    }

    @Test func aliasesRemainBoundBeyondOneThousandWrappersAndRevocationStaysTerminal() throws {
        let owner = Owner(), registry = NativeInitialMetadataOwners<Source>(owner: owner)
        let firstID = UUID(), lastID = UUID()
        var initial = 0, strict = 0
        func inspect(_ source: Source) throws -> Int {
            try registry.withSource(source, sourceID: source.id, owner: owner,
                sameOriginalWindow: sameWindow, validate: {},
                initial: { _,_ in initial += 1; return 1 }, strict: { strict += 1; return 2 })
        }
        _ = try inspect(Source(id: firstID, app: 1, window: 10, imageRevision: 0))
        for revision in 1...1_025 {
            _ = try inspect(Source(id: revision == 1_025 ? lastID : UUID(), app: 1, window: 10, imageRevision: revision))
        }
        #expect(throws: NativeVisualTaskFailure.staleProposal) {
            try inspect(Source(id: lastID, app: 2, window: 10, imageRevision: 1_026))
        }
        #expect(initial == 1 && strict == 1_025)
        registry.revoke()
        #expect(throws: NativeVisualTaskFailure.stopped) {
            try inspect(Source(id: lastID, app: 1, window: 10, imageRevision: 1_027))
        }
        #expect(initial == 1 && strict == 1_025)
    }

    @Test func revocationOrReentrantCallbackDuringAcquisitionNeverStartsAnotherScan() throws {
        let owner = Owner(), registry = NativeInitialMetadataOwners<Source>(owner: owner)
        let source = Source(id: UUID(), app: 1, window: 10, imageRevision: 0)
        var calls = 0
        #expect(throws: NativeVisualTaskFailure.stopped) {
            try registry.withSource(source, sourceID: source.id, owner: owner,
                sameOriginalWindow: sameWindow, validate: {}, initial: { acquisition, check in
                    try acquisition.acquire(validate: check, capture: {
                        calls += 1; registry.revoke(); return snapshot(1)
                    }, compare: comparison)
                }, strict: { snapshot(1) })
        }
        #expect(calls == 1)

        let second = NativeInitialMetadataOwners<Source>(owner: owner)
        #expect(throws: NativeInitialMetadataAcquisition.Failure.alreadyUsed) {
            try second.withSource(source, sourceID: source.id, owner: owner,
                sameOriginalWindow: sameWindow, validate: {}, initial: { _,_ in
                    try second.withSource(source, sourceID: source.id, owner: owner,
                        sameOriginalWindow: sameWindow, validate: {}, initial: { _,_ in 1 }, strict: { 2 })
                }, strict: { 2 })
        }
    }
}
