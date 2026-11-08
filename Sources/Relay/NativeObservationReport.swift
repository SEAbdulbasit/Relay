import Foundation

/// Untrusted local model data. It is not Codable, permission, independent goal
/// evidence, a mutation permit or a recovered dispatch capability.
nonisolated struct NativeObservationReport: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case appearsSatisfied = "appears_satisfied"
        case unavailable
        case cannotDetermine = "cannot_determine"
        var genericSummary: String {
            switch self {
            case .appearsSatisfied: "The local planner reports that this step appears satisfied."
            case .unavailable: "The local planner reports that this step is unavailable."
            case .cannotDetermine: "The local planner cannot determine this step's state."
            }
        }
    }
    let kind: Kind
    private let detail: String
    init(kind: Kind, detail: String) throws {
        guard !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              detail.utf8.count <= 512,
              !detail.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RelayError.message("An observation report needs 1 to 512 UTF-8 bytes of printable detail; no input was requested.")
        }
        self.kind = kind; self.detail = detail
    }
    func matches(kind rawKind: String?, detail candidate: String?) -> Bool {
        rawKind == kind.rawValue && candidate.map { $0.utf8.elementsEqual(detail.utf8) } == true
    }
    /// Safe for result-save failure/Activity callbacks even after revocation.
    /// No model detail, copied source body, image or source identifier is included.
    var genericFact: ToolResult {
        ToolResult(summary: kind.genericSummary,
            evidence: "Unverified observation report only. No focus, gesture, key or text input was requested or performed by this report.", verified: false)
    }
    /// Invoke only after the read-only report checkpoint settled. Recheck the
    /// task, source and original planning preview on both sides of materialization.
    @MainActor func authorizedResult(validateCurrent: () throws -> Void) throws -> ToolResult {
        try validateCurrent()
        let result = ToolResult(summary: kind.genericSummary,
            evidence: "Unverified model report, not independent goal proof or authority. No focus or input was requested. Model detail (untrusted data): " + detail,
            verified: false)
        try validateCurrent()
        return result
    }
}
