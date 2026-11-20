import Foundation

/// Data/source validation only. No text, image, model context, input grant or
/// dispatch callback is stored here. Composition stays flat and bounded across
/// derived replies/results instead of recursively retaining whole snapshots.
@MainActor struct ModelInputSourceProof {
    struct Identity: Hashable, Sendable {
        fileprivate let bytes: Data
        /// Trusted source providers supply their actual capability identity,
        /// scoped owner and fixed validation purpose. This is dedup metadata,
        /// never proof that two OS objects or validators are equivalent.
        init(owner: UUID, sourceID: Data, purpose: String) {
            var value = Data()
            for part in [Data(owner.uuidString.utf8), sourceID, Data(purpose.utf8)] {
                var size = UInt64(part.count).bigEndian
                withUnsafeBytes(of: &size) { value.append(contentsOf: $0) }
                value.append(part)
            }
            bytes = value
        }
    }
    private struct Leaf {
        let id: Identity
        let check: @MainActor @Sendable () async throws -> Void
        let finalMetadata: (@MainActor @Sendable () throws -> Void)?
    }
    enum Failure: LocalizedError {
        case capacity
        var errorDescription: String? {
            "The bounded source-dependency proof cannot admit more private inputs. Omit dependent data and inspect a fresh authorized source; no action was repeated."
        }
    }
    static let maximumDependencies = 32
    private let leaves: [Leaf]
    var dependencyCount: Int { leaves.count }

    /// Trusted callers create this once for an actual retained source or an
    /// immutable source snapshot's extracted validate function, never its body.
    static func source(identity: Identity, _ check: @escaping @MainActor @Sendable () async throws -> Void) -> Self {
        Self(leaves: [Leaf(id: identity, check: check, finalMetadata: nil)])
    }
    /// Known revocation only. The required labelled fence is synchronous and
    /// must retain no private body or perform IO; it is not an atomic OS proof.
    static func source(identity: Identity,
                       finalMetadata: @escaping @MainActor @Sendable () throws -> Void,
                       _ check: @escaping @MainActor @Sendable () async throws -> Void) -> Self {
        Self(leaves: [Leaf(id: identity, check: check, finalMetadata: finalMetadata)])
    }
    /// Nil means no private-source input. Duplicate trusted leaf IDs coalesce;
    /// equal source strings/hashes do not identify a validation capability.
    static func merging(_ proofs: [Self?]) throws -> Self? {
        var seen = Set<Identity>(), merged: [Leaf] = []
        for proof in proofs.compactMap({ $0 }) {
            for leaf in proof.leaves where seen.insert(leaf.id).inserted {
                guard merged.count < maximumDependencies else { throw Failure.capacity }
                merged.append(leaf)
            }
        }
        return merged.isEmpty ? nil : Self(leaves: merged)
    }
    private static func validateFinalMetadata(_ checks: [Leaf]) throws {
        for leaf in checks {
            try Task.checkCancellation()
            try leaf.finalMetadata?()
        }
        try Task.checkCancellation()
    }
    private static func validate(_ checks: [Leaf]) async throws {
        for leaf in checks {
            try Task.checkCancellation(); try await leaf.check(); try Task.checkCancellation()
        }
        // No await below this point. A later leaf cannot hide an already
        // recorded revocation of an earlier leaf while it was suspended.
        try validateFinalMetadata(checks)
    }
    func validateFinalMetadata() throws { try Self.validateFinalMetadata(leaves) }
    func validate() async throws { try await Self.validate(leaves) }
    var validator: @MainActor @Sendable () async throws -> Void {
        let checks = leaves
        return { try await Self.validate(checks) }
    }
}
