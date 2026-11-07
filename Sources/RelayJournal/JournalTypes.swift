import Foundation
import CryptoKit

public struct JournalOpaqueID: Codable, Sendable, Hashable {
    public let bytes: Data
    public init(_ string: String) throws { try self.init(bytes: Data(string.utf8)) }
    public init(bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= 512, String(data: bytes, encoding: .utf8) != nil else { throw JournalError.invalidEvent }
        self.bytes = bytes
    }
    public init(from decoder: any Decoder) throws { try self.init(bytes: decoder.singleValueContainer().decode(Data.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(bytes) }
}

public struct JournalScope: Codable, Sendable, Equatable {
    public let storeID: UUID
    public let generation: UUID
    public init(storeID: UUID, generation: UUID) { self.storeID = storeID; self.generation = generation }
}

public enum JournalOrigin: String, Codable, Sendable { case user, assistant, source, legacyUnknown }
public enum JournalOmission: String, Codable, Sendable {
    case credentialField, requestHeader, imageBody, audioBody, nativeSnapshot, legacyActivity, legacyModelContext, legacyArtifactPath
}
/// Local display metadata only. A saved path or receipt never grants access.
public struct JournalArtifactReference: Codable, Sendable, Equatable {
    public let visiblePath: String
    public let canonicalPath: String?
    public let identityDigest: Data?
    public init(visiblePath: String, canonicalPath: String? = nil, identityDigest: Data? = nil) throws {
        func valid(_ path: String) -> Bool { path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0") }
        guard valid(visiblePath), canonicalPath.map(valid) ?? true,
              (canonicalPath == nil && identityDigest == nil) || (canonicalPath != nil && identityDigest?.count == 32) else { throw JournalError.invalidEvent }
        self.visiblePath = visiblePath; self.canonicalPath = canonicalPath; self.identityDigest = identityDigest
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.visiblePath.utf8) == Data(rhs.visiblePath.utf8) && lhs.canonicalPath.map({ Data($0.utf8) }) == rhs.canonicalPath.map({ Data($0.utf8) }) && lhs.identityDigest == rhs.identityDigest
    }
}
/// Plain visible prose is exact, including prose that resembles a key. No secret or PII classifier.
/// Credentials, headers and image objects have no representation in this payload API.
public struct JournalVisibleText: Codable, Sendable, Equatable {
    public let text: String
    public let origin: JournalOrigin
    public let omissions: [JournalOmission]
    public let sourceRequirements: [JournalSourceRequirement]
    public let artifacts: [JournalArtifactReference]
    public init(_ text: String, origin: JournalOrigin, omissions: [JournalOmission] = [], sourceRequirements: [JournalSourceRequirement] = [], artifacts: [JournalArtifactReference] = []) throws {
        guard text.utf8.count <= 240 * 1024, omissions.count <= 16, sourceRequirements.count <= 32, artifacts.count <= 32 else { throw JournalError.tooLarge }
        self.text = text; self.origin = origin; self.omissions = omissions; self.sourceRequirements = sourceRequirements; self.artifacts = artifacts
    }
    public var automaticallyEligibleForInference: Bool { origin != .legacyUnknown && origin != .source && sourceRequirements.isEmpty && artifacts.isEmpty }
    private enum CodingKeys: String, CodingKey { case text, origin, omissions, sourceRequirements, artifacts }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(String.self, forKey: .text), origin: values.decode(JournalOrigin.self, forKey: .origin),
            omissions: values.decode([JournalOmission].self, forKey: .omissions),
            sourceRequirements: values.decode([JournalSourceRequirement].self, forKey: .sourceRequirements),
            artifacts: values.decodeIfPresent([JournalArtifactReference].self, forKey: .artifacts) ?? [])
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(text, forKey: .text); try values.encode(origin, forKey: .origin)
        try values.encode(omissions, forKey: .omissions); try values.encode(sourceRequirements, forKey: .sourceRequirements)
        if !artifacts.isEmpty { try values.encode(artifacts, forKey: .artifacts) }
    }
}
public struct JournalSourceRequirement: Codable, Sendable, Equatable {
    public let identity: JournalOpaqueID
    public let revision: Data
    public init(identity: JournalOpaqueID, revision: Data) throws {
        guard revision.count == 32 else { throw JournalError.invalidEvent }; self.identity = identity; self.revision = revision
    }
}
public enum JournalEffect: Int, Codable, Sendable { case readOnly, mutation, unknown }
public struct JournalIntent: Codable, Sendable, Equatable {
    public let invocationID: UUID
    public let proposalID: UUID
    public let producerEpoch: UUID
    public let toolCallID: JournalOpaqueID
    public let toolName: String
    public let callDigest: Data
    public let effect: JournalEffect
    public init(invocationID: UUID = UUID(), proposalID: UUID, producerEpoch: UUID, toolCallID: JournalOpaqueID, toolName: String, callDigest: Data, effect: JournalEffect) throws {
        guard !toolName.isEmpty, toolName.utf8.count <= 128, toolName.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }), callDigest.count == 32 else { throw JournalError.invalidEvent }
        self.invocationID = invocationID; self.proposalID = proposalID; self.producerEpoch = producerEpoch; self.toolCallID = toolCallID; self.toolName = toolName; self.callDigest = callDigest; self.effect = effect
    }
}
public enum JournalOutcomeKind: Int, Codable, Sendable { case notDispatched, returnedVerified, returnedUnverified, failedBeforeDispatch, effectUncertain }
public struct JournalToolOutcome: Codable, Sendable, Equatable {
    public let invocationID: UUID
    public let callDigest: Data
    public let kind: JournalOutcomeKind
    public let evidence: JournalVisibleText?
    public let artifacts: [JournalArtifactReference]
    public init(intent: JournalIntent, kind: JournalOutcomeKind, evidence: JournalVisibleText? = nil, artifacts: [JournalArtifactReference] = []) {
        invocationID = intent.invocationID; callDigest = intent.callDigest; self.kind = kind; self.evidence = evidence; self.artifacts = artifacts
    }
    private enum CodingKeys: String, CodingKey { case invocationID, callDigest, kind, evidence, artifacts }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        invocationID = try values.decode(UUID.self, forKey: .invocationID)
        callDigest = try values.decode(Data.self, forKey: .callDigest)
        kind = try values.decode(JournalOutcomeKind.self, forKey: .kind)
        evidence = try values.decodeIfPresent(JournalVisibleText.self, forKey: .evidence)
        artifacts = try values.decodeIfPresent([JournalArtifactReference].self, forKey: .artifacts) ?? []
        guard callDigest.count == 32, artifacts.count <= 32 else { throw JournalError.invalidEvent }
        for value in artifacts { _ = try JournalArtifactReference(visiblePath: value.visiblePath, canonicalPath: value.canonicalPath, identityDigest: value.identityDigest) }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(invocationID, forKey: .invocationID); try values.encode(callDigest, forKey: .callDigest); try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(evidence, forKey: .evidence)
        if !artifacts.isEmpty { try values.encode(artifacts, forKey: .artifacts) }
    }
}
public enum JournalTaskOutcome: Int, Codable, Sendable {
    case success, failed, stopped, interrupted, historicalUnknown, responseDelivered, needsInput
}
public enum JournalRunCause: String, Codable, Sendable { case newRequest, steering, resume }
public struct JournalRunRelation: Codable, Sendable, Equatable {
    public let logicalTaskID: UUID
    public let predecessorRunID: UUID?
    public let cause: JournalRunCause
    public init(logicalTaskID: UUID, predecessorRunID: UUID? = nil, cause: JournalRunCause) throws {
        guard (cause == .newRequest && predecessorRunID == nil) || (cause != .newRequest && predecessorRunID != nil) else { throw JournalError.invalidEvent }
        self.logicalTaskID = logicalTaskID; self.predecessorRunID = predecessorRunID; self.cause = cause
    }
}
public enum JournalPayload: Codable, Sendable, Equatable {
    case started(producerEpoch: UUID, relation: JournalRunRelation? = nil)
    case user(JournalVisibleText)
    case assistant(JournalVisibleText)
    case question(JournalVisibleText)
    case answer(JournalVisibleText)
    case intent(JournalIntent)
    case result(JournalToolOutcome)
    case finished(JournalTaskOutcome)
    case sourceInvalidated(JournalOpaqueID)
    var kind: Int64 {
        switch self { case .started: 0; case .user: 1; case .assistant: 2; case .question: 3; case .answer: 4; case .intent: 5; case .result: 6; case .finished: 7; case .sourceInvalidated: 8 }
    }
}
public struct JournalEvent: Codable, Sendable, Equatable {
    public let id: JournalOpaqueID
    public let taskID: UUID
    public let attemptID: UUID?
    public let createdAtMilliseconds: Int64?
    public let payload: JournalPayload
    public init(id: JournalOpaqueID, taskID: UUID, attemptID: UUID?, createdAtMilliseconds: Int64? = nil, payload: JournalPayload) {
        self.id = id; self.taskID = taskID; self.attemptID = attemptID; self.createdAtMilliseconds = createdAtMilliseconds; self.payload = payload
    }
}
public struct JournalRecord: Sendable, Equatable {
    public let scope: JournalScope
    public let sequence: Int64
    public let event: JournalEvent
    public let digest: Data
}
public struct JournalAppend: Sendable { public let record: JournalRecord; public let inserted: Bool }
public enum JournalIntentCommit: Sendable { case inserted(JournalRecord), alreadyRecorded(JournalRecord) }
public struct JournalCursor: Sendable, Equatable { public let scope: JournalScope; public let sequence: Int64 }
public struct JournalPage: Sendable { public let records: [JournalRecord]; public let cursor: JournalCursor; public let hasLater: Bool }
public enum JournalError: Error, Equatable, Sendable {
    case invalidEvent, invalidTransition, conflictingID, wrongGeneration, corrupt, unsupportedSchema, unsafeLocation, writerBusy, tooLarge, cancelled, closed, notReady, duplicateIntent, dispatchRevoked, pendingResult
    case sqlite(Int32), injectedBeforeCommit, acknowledgmentLost
}
public enum JournalFault: Sendable { case beforeCommit, afterCommit }
#if DEBUG
enum JournalTestBoundary: Sendable { case beforeCommit, afterCommit }
#endif
public struct JournalLimits: Sendable {
    public var databaseBytes = 128 * 1024 * 1024
    public var walThresholdBytes = 16 * 1024 * 1024
    public var busyMilliseconds: Int32 = 250
    public init() {}
}
public struct JournalLegacyManifest: Sendable, Equatable {
    public let digest: Data
    public let expectedEvents: Int
    public let eventsDigest: Data
    public init(digest: Data, expectedEvents: Int, eventsDigest: Data) throws {
        guard digest.count == 32, eventsDigest.count == 32, expectedEvents >= 0, expectedEvents <= 100_000 else { throw JournalError.invalidEvent }
        self.digest = digest; self.expectedEvents = expectedEvents; self.eventsDigest = eventsDigest
    }
}
public enum JournalInitialization: Sendable { case ready, importing(JournalLegacyManifest) }

func journalDigest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
func uuidBytes(_ value: UUID) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }
func uuidFromBytes(_ data: Data) throws -> UUID {
    guard data.count == 16 else { throw JournalError.corrupt }
    return data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
}
func journalEncoded(_ event: JournalEvent) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(event)
    guard data.count <= 262_144 else { throw JournalError.tooLarge }
    try validateJournalJSON(data)
    return data
}
func validateJournalJSON(_ data: Data) throws {
    var depth = 0, nodes = 0, inString = false, escaped = false
    for byte in data {
        if inString { if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { inString = false }; continue }
        if byte == 34 { inString = true; nodes += 1 }
        else if byte == 123 || byte == 91 { depth += 1; nodes += 1 }
        else if byte == 125 || byte == 93 { depth -= 1 }
        else if byte == 44 { nodes += 1 }
        guard depth >= 0, depth <= 32, nodes <= 100_000 else { throw JournalError.tooLarge }
    }
    guard !inString, depth == 0 else { throw JournalError.corrupt }
}

func journalEventsDigest(_ events: [JournalEvent]) throws -> Data {
    var hash = SHA256()
    for event in events { hash.update(data: journalDigest(try journalEncoded(event))) }
    return Data(hash.finalize())
}
