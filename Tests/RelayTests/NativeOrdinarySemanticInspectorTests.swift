import Foundation
import Testing
@testable import Relay

@MainActor @Suite struct NativeOrdinarySemanticInspectorTests {
    private func facts(context: NativeOrdinaryWindowPolicySource.Context = .ordinary,
                       controls: Set<NativeOrdinaryWindowPolicySource.Dedicated> = []) -> NativeOrdinaryWindowPolicySource.Facts {
        .init(sourceID: UUID(), application: .init(processID: 40, launchedAt: .init(timeIntervalSince1970: 1),
            bundleID: "dev.relay.owned.synthetic", bundleURL: URL(fileURLWithPath: "/Owned Synthetic.app")),
            context: context, coverage: .complete, visibleDedicatedControls: controls, visitedNodes: 3, digest: Data(repeating: 0x61, count: 32))
    }
    @Test func qualifiedOrdinaryEditorNeedsNoRedundantReviewDespiteUnrelatedSendControl() throws {
        let value = facts(controls: [.submission])
        let key = try NativeOrdinarySemanticInspector.boundary(action: .key(.left), facts: value,
            hasQualifiedFocus: true, hasQualifiedInsertion: false)
        let text = try NativeOrdinarySemanticInspector.boundary(action: .typeUnsentText("cafe\u{301} 世界 🌍"), facts: value,
            hasQualifiedFocus: false, hasQualifiedInsertion: true)
        guard case .ordinary = key, case .ordinary = text else { Issue.record("Qualified ordinary editing unexpectedly required review"); return }
    }
    @Test func missingCompositePreviewCannotBeReplacedByAnOrdinaryLabelOrToolName() {
        let value = facts()
        #expect(throws: NativeControlSession.Failure.unavailableFocus) {
            try NativeOrdinarySemanticInspector.boundary(action: .key(.right), facts: value,
                hasQualifiedFocus: false, hasQualifiedInsertion: false)
        }
        #expect(throws: NativeControlSession.Failure.unavailableFocus) {
            try NativeOrdinarySemanticInspector.boundary(action: .typeUnsentText("synthetic draft"), facts: value,
                hasQualifiedFocus: true, hasQualifiedInsertion: false)
        }
    }
    @Test func unknownCanvasUsesExactReviewButKnownProtectedAndDedicatedContextsNeverDo() throws {
        let action = NativeControlSession.Action.click(image: UUID(), point: .init(x: 40, y: 20))
        let ordinary = try NativeOrdinarySemanticInspector.boundary(action: action, facts: facts(),
            hasQualifiedFocus: false, hasQualifiedInsertion: false)
        guard case .review = ordinary else { Issue.record("Unknown canvas did not require review"); return }
        let protected = try NativeOrdinarySemanticInspector.boundary(action: action, facts: facts(context: .protected),
            hasQualifiedFocus: true, hasQualifiedInsertion: true)
        guard case .protected = protected else { Issue.record("Protected context became reviewable"); return }
        let dedicated = try NativeOrdinarySemanticInspector.boundary(action: action,
            facts: facts(context: .dedicated(.financial)), hasQualifiedFocus: false, hasQualifiedInsertion: false)
        guard case .dedicated("financial") = dedicated else { Issue.record("Dedicated context became reviewable"); return }
    }
    @Test func unqualifiedPointerTargetCannotUseReviewToBypassKnownDedicatedControl() throws {
        let action = NativeControlSession.Action.drag(image: UUID(), from: .init(x: 10, y: 10), to: .init(x: 20, y: 20))
        let boundary = try NativeOrdinarySemanticInspector.boundary(action: action, facts: facts(controls: [.destructive]),
            hasQualifiedFocus: false, hasQualifiedInsertion: false)
        guard case .dedicated("destructive") = boundary else { Issue.record("Unproven pointer target bypassed a known boundary"); return }
    }
}
