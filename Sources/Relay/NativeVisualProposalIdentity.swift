import CryptoKit
import Foundation
import RelayJournal

/// Metadata identity, not action authority. The accepted reply UUID comes from
/// Store/orchestrator acceptance once; retries must retain this same object.
@MainActor final class NativeVisualProposalIdentity {
    let runID: UUID
    let attemptID: UUID
    let proposalID: UUID
    let rawCallID: JournalOpaqueID
    let call: ToolCall
    let callDigest: Data
    let controllerRequestID: String
    private var attempted = false

    init(scope: NativeVisualTaskScope, acceptedReplyID: UUID, call: ToolCall) throws {
        try scope.validate()
        runID = scope.run.taskID; attemptID = scope.run.attemptID; proposalID = acceptedReplyID
        rawCallID = try JournalOpaqueID(call.id); self.call = call
        callDigest = try Self.digest(call)
        var bytes = Data("relay.native.proposal.v1".utf8)
        for part in [Data(runID.uuidString.utf8), Data(attemptID.uuidString.utf8),
                     Data(proposalID.uuidString.utf8), rawCallID.bytes] {
            var length = UInt64(part.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(part)
        }
        // The argument/effect digest is deliberately not part of this key:
        // changing an accepted operation must conflict, not mint another ID.
        controllerRequestID = "relay-native-v1:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func validate(scope: NativeVisualTaskScope, call candidate: ToolCall) throws {
        try scope.validate()
        guard scope.run.taskID == runID, scope.run.attemptID == attemptID,
              Data(candidate.id.utf8) == rawCallID.bytes, try Self.digest(candidate) == callDigest else {
            throw NativeVisualTaskFailure.staleProposal
        }
    }
    func admitOneAttempt(scope: NativeVisualTaskScope) throws {
        try validate(scope: scope, call: call)
        guard !attempted else { throw NativeVisualTaskFailure.duplicateAttempt }
        attempted = true
    }
    func admission(scope: NativeVisualTaskScope) throws -> NativeControlRequestAdmission {
        try validate(scope: scope, call: call)
        return NativeControlRequestAdmission(requestID: controllerRequestID,
            originalProviderCallID: rawCallID.bytes, exactCallDigest: callDigest,
            validateAcceptedProposal: { try self.validate(scope: scope, call: self.call) },
            admitOneAttempt: { try self.admitOneAttempt(scope: scope) })
    }

    private static func digest(_ call: ToolCall) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(call)))
    }
}
