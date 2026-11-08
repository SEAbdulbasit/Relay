import CryptoKit
import Foundation

/// Original-source data admission only. This retains no image, answer, model
/// history, input grant or replacement-window resolver. Trusted capture code
/// supplies the already-admitted actual target and brackets metadata-only IO.
@MainActor final class NativeCurrentReadbackSource {
    let sourceID: UUID
    let application: DesktopApplicationIdentity
    private let validateOriginal: @MainActor () throws -> Void
    init(sourceID: UUID, application: DesktopApplicationIdentity,
         validateOriginalSource: @escaping @MainActor () throws -> Void) {
        self.sourceID = sourceID; self.application = application
        self.validateOriginal = validateOriginalSource
    }
    func validate() throws {
        try Task.checkCancellation(); try validateOriginal(); try Task.checkCancellation()
    }
}

/// A returned result and its actual memory-only source capability. The source
/// is optional: an unqualified backend can still read, but cannot admit private
/// data to a later Critic inference merely because it returned a ToolResult.
@MainActor struct NativeSourcedToolResult {
    let result: ToolResult
    let source: NativeCurrentReadbackSource?
    /// Actual settled effect coverage only; never part of ToolResult/Codable.
    var goalSeed: NativeGoalEffectSeed? = nil
}

/// Bounded metadata/source cache, never an executable ledger. Eviction only
/// refuses later private-body admission; it cannot authorize/repeat any effect.
@MainActor final class NativeCurrentReadbackReceipts {
    enum Failure: LocalizedError {
        case unavailable, changedResult
        var errorDescription: String? {
            switch self {
            case .unavailable: "The native result has no current exact source receipt. Its private detail was not admitted for another inference."
            case .changedResult: "The native result differs from the exact observed result. Inspect the actual source again; no input was repeated."
            }
        }
    }
    private struct Key: Hashable {
        let run: UUID, attempt: UUID, proposal: UUID
        let providerID: Data, name: Data, callDigest: Data
    }
    private struct Entry {
        let id: UUID
        let resultDigest: Data
        let source: NativeCurrentReadbackSource
        let ownProof: ModelInputSourceProof
        let inputProof: ModelInputSourceProof?
    }
    static let maximumEntries = 32
    private let scope: NativeVisualTaskScope
    private var epoch = UUID()
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    init(scope: NativeVisualTaskScope) { self.scope = scope }

    /// Call only with the result/source that this accepted operation actually
    /// returned. No source is looked up from model IDs, names, title or history.
    func record(_ returned: NativeSourcedToolResult, call: ToolCall, acceptedProposalID: UUID,
                inputProof: ModelInputSourceProof? = nil) throws {
        try scope.validate()
        guard let source = returned.source else { return }
        try source.validate(); try scope.validate()
        let key = try key(call, proposal: acceptedProposalID), digest = try Self.digest(returned.result)
        if let previous = entries[key] {
            guard previous.resultDigest == digest, previous.source === source else { throw Failure.changedResult }
            return
        }
        let expected = epoch
        let ownProof = ModelInputSourceProof.source(identity: .init(owner: scope.run.taskID,
            sourceID: Data(source.sourceID.uuidString.utf8), purpose: "native original read source")) { [weak self] in
                guard let self else { throw Failure.unavailable }
                try self.scope.validate()
                guard self.epoch == expected else { throw Failure.unavailable }
                try source.validate(); try self.scope.validate()
                guard self.epoch == expected else { throw Failure.unavailable }
            }
        entries[key] = Entry(id: UUID(), resultDigest: digest, source: source,
            ownProof: ownProof, inputProof: inputProof); order.append(key)
        while order.count > Self.maximumEntries { entries.removeValue(forKey: order.removeFirst()) }
    }

    func admission(call: ToolCall, acceptedProposalID: UUID, result: ToolResult) throws -> @MainActor @Sendable () async throws -> Void {
        try scope.validate()
        let key = try key(call, proposal: acceptedProposalID), digest = try Self.digest(result)
        guard let entry = entries[key] else { throw Failure.unavailable }
        guard entry.resultDigest == digest else { throw Failure.changedResult }
        try entry.source.validate(); try scope.validate()
        guard let proof = try ModelInputSourceProof.merging([entry.ownProof, entry.inputProof]) else { throw Failure.unavailable }
        let expectedEpoch = epoch, id = entry.id
        let validate: @MainActor @Sendable () async throws -> Void = { [weak self] in
            guard let self else { throw Failure.unavailable }
            try self.scope.validate()
            guard self.epoch == expectedEpoch, let current = self.entries[key], current.id == id,
                  current.resultDigest == digest else { throw Failure.unavailable }
            // The actual retained target's metadata/privacy/task source fence
            // precedes any source validation IO. This performs no capture/input.
            try current.source.validate(); try await proof.validate()
            try self.scope.validate()
            guard self.epoch == expectedEpoch, self.entries[key]?.id == id else { throw Failure.unavailable }
        }
        return validate
    }
    func sourceProof(call: ToolCall, acceptedProposalID: UUID, result: ToolResult) throws -> ModelInputSourceProof {
        try scope.validate()
        let key = try key(call, proposal: acceptedProposalID), digest = try Self.digest(result)
        guard let entry = entries[key] else { throw Failure.unavailable }
        guard entry.resultDigest == digest else { throw Failure.changedResult }
        try entry.source.validate(); try scope.validate()
        guard let proof = try ModelInputSourceProof.merging([entry.ownProof, entry.inputProof]) else { throw Failure.unavailable }
        return proof
    }

    func stop() { epoch = UUID(); entries.removeAll(); order.removeAll() }
    private func key(_ call: ToolCall, proposal: UUID) throws -> Key {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(call)
        return Key(run: scope.run.taskID, attempt: scope.run.attemptID, proposal: proposal,
            providerID: Data(call.id.utf8), name: Data(call.name.utf8), callDigest: Data(SHA256.hash(data: bytes)))
    }
    private static func digest(_ result: ToolResult) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(result)))
    }
}
