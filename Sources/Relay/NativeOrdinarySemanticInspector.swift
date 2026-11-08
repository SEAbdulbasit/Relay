import Foundation

/// Uses trusted live task authority, actual retained-window metadata and the
/// controller's pre-inference editor facts. A model effect string is displayed
/// for review, never used to classify a target as safe or ordinary.
@MainActor final class NativeOrdinarySemanticInspector {
    private let authority: NativeLocalTaskInputAuthority
    private let target: @MainActor (UUID) throws -> NativeOriginalPolicyTarget

    init(authority: NativeLocalTaskInputAuthority,
         target: @escaping @MainActor (UUID) throws -> NativeOriginalPolicyTarget) {
        self.authority = authority; self.target = target
    }
    func inspect(_ context: NativeControlSession.PolicyContext, scope: NativeVisualTaskScope) throws -> NativeOrdinaryAssessment {
        guard scope === authority.scope else { throw NativeVisualTaskFailure.staleTask }
        let source = try target(context.sourceID)
        guard source.sourceID == context.sourceID, source.application == context.application else { throw NativeVisualTaskFailure.staleProposal }
        try context.validateTarget()
        let facts = try authority.inspect(source)
        let boundary = try Self.boundary(action: context.action, facts: facts,
            hasQualifiedFocus: context.focus != nil && context.focusedTarget != nil,
            hasQualifiedInsertion: context.textInsertion != nil && context.focusedTarget != nil)
        return .init(boundary: boundary, permitsTaskAuthorizedFocus: true, visualProof: .wholeFrame,
            validateSemanticContext: { [authority] in
                try authority.validate(); try source.validateSource(); try context.validateTarget()
                let current = try authority.inspect(source)
                guard current.digest == facts.digest, current.sourceID == facts.sourceID,
                      current.application == facts.application else { throw NativeOrdinaryWindowPolicySource.Failure.changedContext }
            })
    }

    static func boundary(action: NativeControlSession.Action, facts: NativeOrdinaryWindowPolicySource.Facts,
                         hasQualifiedFocus: Bool, hasQualifiedInsertion: Bool) throws -> NativeOrdinaryAssessment.Boundary {
        switch facts.context {
        case .protected: return .protected
        case .dedicated(let effect): return .dedicated(effect.rawValue)
        case .ordinary, .modalReviewRequired: break
        }
        switch action {
        case .key:
            try facts.admitPrivateEditorPlanning()
            guard hasQualifiedFocus else { throw NativeControlSession.Failure.unavailableFocus }
            return .ordinary
        case .typeUnsentText:
            try facts.admitPrivateEditorPlanning()
            guard hasQualifiedInsertion else { throw NativeControlSession.Failure.unavailableFocus }
            return .ordinary
        case .click, .drag:
            // No qualified AX hit-target mapping exists in this candidate.
            // Where a visible dedicated control could be the proposed hit,
            // exact review alone cannot bypass that known effect boundary.
            // Unrelated Send controls do not block ordinary editor work above.
            if let dedicated = facts.visibleDedicatedControls.sorted(by: { $0.rawValue < $1.rawValue }).first {
                return .dedicated(dedicated.rawValue)
            }
            return .review
        }
    }
}
