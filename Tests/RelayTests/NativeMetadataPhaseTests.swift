import Foundation
import Testing
@testable import Relay

/// The synchronous phase state machine, not a fabricated production AX source.
/// Actual MetadataBinding has no test/public initializer and must come from bind.
@MainActor @Suite struct NativeMetadataPhaseTests {
    private enum Refusal: Error, Equatable { case source, scope, metadata }
    @MainActor private final class State {
        var current = true, source = "original", selected = "original", document = "original"
        var boundaries = 0, queries = 0, metadata = 0, privateReads = 0, published = 0
        var escaped: NativeMetadataPhase?
        func boundary() throws {
            boundaries += 1
            guard current else { throw Refusal.scope }
            guard source == "original", selected == "original", document == "original" else { throw Refusal.source }
        }
        func query() throws {
            queries += 1
            guard current else { throw Refusal.scope }
        }
    }

    @Test func manyMetadataQueriesUseTwoStrongBoundariesAndNoPrivateAuthority() throws {
        let state = State()
        let value = try NativeMetadataPhase.run(deadline: .now.advanced(by: .seconds(1)),
            boundary: state.boundary, query: state.query) { phase in
                state.escaped = phase
                for _ in 0..<80 { try phase.check(); state.metadata += 1; try phase.check() }
                return 80
            }
        #expect(value == 80 && state.metadata == 80 && state.queries == 160 && state.boundaries == 2)
        #expect(state.privateReads == 0 && state.published == 0)
        let phase = try #require(state.escaped)
        #expect(throws: NativeMetadataPhase.Failure.expired) { try phase.check() }
        #expect(state.queries == 160)
    }

    @Test(arguments: ["source", "selected", "document"])
    func driftDuringMetadataRefusesBeforeLabelsOrPublication(kind: String) throws {
        let state = State()
        #expect(throws: Refusal.source) {
            try NativeMetadataPhase.run(deadline: .now.advanced(by: .seconds(1)),
                boundary: state.boundary, query: state.query) { phase in
                    try phase.check(); state.metadata += 1
                    switch kind {
                    case "source": state.source = "replacement"
                    case "selected": state.selected = "replacement"
                    default: state.document = "replacement"
                    }
                    // Remaining metadata may inspect only retained references;
                    // no body/label is admitted by a cheap check.
                    try phase.check(); state.escaped = phase
                }
            state.privateReads += 1; state.published += 1
        }
        #expect(state.boundaries == 2 && state.metadata == 1 && state.queries == 2)
        #expect(state.privateReads == 0 && state.published == 0)
        let phase = try #require(state.escaped)
        #expect(throws: NativeMetadataPhase.Failure.expired) { try phase.check() }
    }

    @Test func stopDuringMetadataFailsNextQueryAndExitAndRetiresPhase() throws {
        let state = State()
        #expect(throws: Refusal.scope) {
            try NativeMetadataPhase.run(deadline: .now.advanced(by: .seconds(1)),
                boundary: state.boundary, query: state.query) { phase in
                    state.escaped = phase; try phase.check(); state.metadata += 1
                    state.current = false; try phase.check(); state.metadata += 1
                }
        }
        #expect(state.metadata == 1 && state.boundaries == 2 && state.privateReads == 0)
        let phase = try #require(state.escaped)
        #expect(throws: NativeMetadataPhase.Failure.expired) { try phase.check() }
    }

    @Test func sourceFailureOnErrorExitOverridesOldMetadataError() throws {
        let state = State()
        #expect(throws: Refusal.source) {
            try NativeMetadataPhase.run(deadline: .now.advanced(by: .seconds(1)),
                boundary: state.boundary, query: state.query) { phase in
                    state.escaped = phase; try phase.check(); state.document = "replacement"
                    throw Refusal.metadata
                }
        }
        #expect(state.boundaries == 2 && state.queries == 1 && state.privateReads == 0)
        let phase = try #require(state.escaped)
        #expect(throws: NativeMetadataPhase.Failure.expired) { try phase.check() }
    }

    @Test func unchangedSourcePreservesExactMetadataErrorAndRetiresPhase() throws {
        let state = State()
        #expect(throws: Refusal.metadata) {
            try NativeMetadataPhase.run(deadline: .now.advanced(by: .seconds(1)),
                boundary: state.boundary, query: state.query) { phase in
                    state.escaped = phase; try phase.check(); throw Refusal.metadata
                }
        }
        #expect(state.boundaries == 2 && state.queries == 1)
        let phase = try #require(state.escaped)
        #expect(throws: NativeMetadataPhase.Failure.expired) { try phase.check() }
    }

    @Test func failedEntryStillChecksExitAndNeverRunsBody() throws {
        let state = State(); state.current = false
        #expect(throws: Refusal.scope) {
            try NativeMetadataPhase.run(deadline: .now.advanced(by: .seconds(1)),
                boundary: state.boundary, query: state.query) { _ in state.metadata += 1 }
        }
        #expect(state.boundaries == 2 && state.queries == 0 && state.metadata == 0)
    }

    @Test func fullBoundaryTimeIsIncludedInTheUnchanged750MillisecondBudget() throws {
        let state = State(), start = ContinuousClock.now
        var now = start
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeMetadataPhase.run(deadline: start.advanced(by: .milliseconds(750)), boundary: {
                try state.boundary(); now = start.advanced(by: .milliseconds(751))
            }, query: state.query, now: { now }) { _ in state.metadata += 1 }
        }
        #expect(state.boundaries == 2 && state.metadata == 0 && state.queries == 0)
    }

    @Test func exitBoundaryCannotReturnSuccessPastTheSameDeadline() throws {
        let state = State(), start = ContinuousClock.now
        var now = start
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeMetadataPhase.run(deadline: start.advanced(by: .milliseconds(750)), boundary: {
                try state.boundary()
                if state.boundaries == 2 { now = start.advanced(by: .milliseconds(750)) }
            }, query: state.query, now: { now }) { phase in
                state.escaped = phase; try phase.check(); state.metadata += 1
            }
            state.published += 1
        }
        #expect(state.boundaries == 2 && state.metadata == 1 && state.published == 0)
        let phase = try #require(state.escaped)
        #expect(throws: NativeMetadataPhase.Failure.expired) { try phase.check() }
    }

    @Test func canceledTaskRefusesAndRetiresItsPhaseWithoutASecondQuery() async throws {
        let state = State()
        let child = Task { @MainActor in
            do {
                try NativeMetadataPhase.run(deadline: .now.advanced(by: .seconds(1)),
                    boundary: state.boundary, query: state.query) { phase in
                        state.escaped = phase; try phase.check(); state.metadata += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                        try phase.check(); state.metadata += 1
                    }
                Issue.record("A canceled metadata phase returned success")
            } catch is CancellationError { }
            catch { Issue.record("Unexpected refusal: \(error)") }
        }
        await child.value
        #expect(state.metadata == 1 && state.queries == 1 && state.boundaries == 2)
        let phase = try #require(state.escaped)
        #expect(throws: NativeMetadataPhase.Failure.expired) { try phase.check() }
    }

    @Test func anEscapingTaskCannotUseTheLeaseAfterTheSynchronousPhase() async throws {
        let state = State()
        let followup = try NativeMetadataPhase.run(deadline: .now.advanced(by: .seconds(1)),
            boundary: state.boundary, query: state.query) { phase in
                Task { @MainActor in
                    #expect(throws: NativeMetadataPhase.Failure.expired) { try phase.check() }
                }
            }
        await followup.value
        #expect(state.queries == 0 && state.boundaries == 2)
    }

    @Test func inertPreparationCannotMintTheOptimizedBindingOrCallTheProvider() async throws {
        var captures = 0
        let observer = TargetBoundNativeObservation(backend: .init(capture: { _, _ in
            captures += 1; throw TargetBoundNativeObservation.Failure.nativeError
        }, close: {}), sessionIsActive: { true })
        let app = DesktopApplicationIdentity(processID: 42, launchedAt: Date(timeIntervalSince1970: 1),
            bundleID: "test.metadata.inert", bundleURL: URL(fileURLWithPath: "/Inert.app"))
        let window = TargetBoundNativeObservation.WindowInfo(title: "Inert", role: "AXWindow", identifier: "",
            document: "", url: "", x: 0, y: 0, width: 100, height: 100, minimized: false, hidden: false, modal: false)
        let request = try observer.prepare(.init(application: app, window: window, validate: {}))
        let lease = try observer.retainPreparedTarget(request)
        #expect(throws: TargetBoundNativeObservation.Failure.unavailableWindow) { try observer.metadataBinding(lease) }
        #expect(captures == 0)
        observer.stop()
        await observer.drain()
    }
}
