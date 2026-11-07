import Foundation
import CryptoKit
import CoreFoundation

private func validateLegacyEnvelope(_ root: [String: Any]) throws {
    func string(_ value: Any?) throws -> String { guard let value = value as? String else { throw JournalError.corrupt }; return value }
    func uuid(_ value: Any?) throws { guard UUID(uuidString: try string(value)) != nil else { throw JournalError.corrupt } }
    func bool(_ value: Any?) throws {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw JournalError.corrupt }
    }
    func number(_ value: Any?, integer: Bool = false) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              !integer || (value.doubleValue.rounded(.towardZero) == value.doubleValue && value.doubleValue >= Double(Int.min) && value.doubleValue < Double(Int.max)) else { throw JournalError.corrupt }
        return value.doubleValue
    }
    func dictionaries(_ key: String) throws -> [[String: Any]] {
        guard let array = root[key] as? [Any], array.count <= 100_000 else { throw JournalError.corrupt }
        return try array.map { guard let object = $0 as? [String: Any] else { throw JournalError.corrupt }; return object }
    }
    func optionalString(_ value: Any?) throws { if let value, !(value is NSNull) { _ = try string(value) } }
    func optionalInteger(_ value: Any?) throws { if let value, !(value is NSNull) { _ = try number(value, integer: true) } }
    for item in try dictionaries("messages") {
        try uuid(item["id"]); _ = try string(item["role"]); _ = try string(item["text"]); _ = try number(item["date"])
        if let artifacts = item["artifacts"] { guard artifacts is [String] else { throw JournalError.corrupt } }
    }
    for item in try dictionaries("activity") {
        try uuid(item["id"]); _ = try string(item["name"]); _ = try string(item["detail"]); _ = try string(item["status"]); _ = try number(item["date"])
    }
    for item in try dictionaries("grants") { try uuid(item["id"]); _ = try string(item["path"]); try bool(item["writable"]) }
    for item in try dictionaries("memories") { try uuid(item["id"]); _ = try string(item["text"]) }
    for item in try dictionaries("modelMessages") {
        _ = try string(item["role"]); _ = try string(item["content"]); try optionalString(item["toolCallID"]); try optionalString(item["toolName"])
        guard let calls = item["toolCalls"] as? [[String: Any]] else { throw JournalError.corrupt }
        for call in calls {
            _ = try string(call["id"]); _ = try string(call["name"])
            guard call["arguments"] is [String: Any] else { throw JournalError.corrupt }
        }
    }
    try bool(root["interrupted"]); try optionalString(root["activeObjective"])
    try optionalInteger(root["activeContextStart"]); try optionalInteger(root["pendingContextReset"])
    guard let configuration = root["configuration"] as? [String: Any], Set(configuration.keys).isSubset(of: ["backend","modelPath","computeBackend","model","lmStudio"]) else { throw JournalError.unsupportedSchema }
    if let backend = configuration["backend"] { guard ["liteRTLM","lmStudio"].contains(try string(backend)) else { throw JournalError.unsupportedSchema } }
    for key in ["modelPath","computeBackend","model"] { try optionalString(configuration[key]) }
    if let value = configuration["lmStudio"], !(value is NSNull) {
        guard let choice = value as? [String: Any], Set(choice.keys).isSubset(of: ["endpoint","modelID"]),
              let endpoint = choice["endpoint"] as? [String: Any], Set(endpoint.keys) == ["host","port"],
              ["127.0.0.1","::1"].contains(try string(endpoint["host"])) else { throw JournalError.unsupportedSchema }
        let port = try number(endpoint["port"], integer: true); guard (1...65535).contains(port) else { throw JournalError.corrupt }
        try optionalString(choice["modelID"])
        if let model = choice["modelID"] as? String, !model.isEmpty {
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.utf8.count <= 256, !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw JournalError.corrupt }
        }
    }
}

public struct JournalLegacySnapshot: Sendable {
    public let manifest: JournalLegacyManifest
    public let events: [JournalEvent]
    public let omittedActivityCount: Int
    public let omittedModelMessageCount: Int
    /// The explicitly configured legacy file is read only. No discovery, replacement or rename.
    @concurrent public static func read(_ url: URL) async throws -> JournalLegacySnapshot {
        try decode(LocalStateFile.read(url, maximumBytes: 32 * 1024 * 1024))
    }
    public static func decode(_ data: Data) throws -> JournalLegacySnapshot {
        guard data.count <= 32 * 1024 * 1024 else { throw JournalError.tooLarge }
        try validateJournalJSON(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw JournalError.corrupt }
        let known = Set(["messages", "activity", "grants", "memories", "configuration", "modelMessages", "interrupted", "activeObjective", "activeContextStart", "pendingContextReset"])
        guard Set(root.keys).isSubset(of: known) else { throw JournalError.unsupportedSchema }
        try validateLegacyEnvelope(root)
        // Structural validation is deliberate: this importer owns conversation extraction,
        // not migration or rewriting of the independent preference/configuration types.
        for key in ["messages", "activity", "grants", "memories", "modelMessages"] {
            guard let values = root[key] as? [Any], values.count <= 100_000 else { throw JournalError.corrupt }
        }
        guard let configuration = root["configuration"] as? [String: Any], let interrupted = root["interrupted"] as? Bool else { throw JournalError.corrupt }
        if let backend = configuration["backend"] as? String, !["liteRTLM", "lmStudio"].contains(backend) { throw JournalError.unsupportedSchema }
        struct Message: Decodable { let id: UUID; let role: String; let text: String; let date: Date; let artifacts: [String]? }
        struct Messages: Decodable { let messages: [Message] }
        let messages: [Message]
        do { messages = try JSONDecoder().decode(Messages.self, from: data).messages } catch { throw JournalError.corrupt }
        guard messages.allSatisfy({ ["user", "assistant"].contains($0.role) && $0.date.timeIntervalSince1970.isFinite }) else { throw JournalError.corrupt }
        let sourceDigest = journalDigest(data)
        let activityCount = (root["activity"] as! [Any]).count
        let modelCount = (root["modelMessages"] as! [Any]).count
        var events: [JournalEvent] = [], taskID: UUID?, ordinal = 0
        func stableUUID(_ label: String) -> UUID {
            let digest = journalDigest(sourceDigest + Data(label.utf8))
            return digest.prefix(16).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        }
        func finish(_ id: UUID, last: Bool = false) throws {
            let eventID = try JournalOpaqueID("legacy-end:" + id.uuidString)
            events.append(JournalEvent(id: eventID, taskID: id, attemptID: nil, payload: .finished(interrupted && last ? .interrupted : .historicalUnknown)))
        }
        for message in messages {
            if message.role == "user" || taskID == nil {
                if let taskID { try finish(taskID) }
                taskID = stableUUID("task:\(ordinal):\(message.id.uuidString)")
            }
            let id = try JournalOpaqueID("legacy:\(ordinal):\(message.id.uuidString)")
            var omitted: [JournalOmission] = []
            if ordinal == 0, activityCount > 0 { omitted.append(.legacyActivity) }
            if ordinal == 0, modelCount > 0 { omitted.append(.legacyModelContext) }
            let artifacts = try (message.artifacts ?? []).map { try JournalArtifactReference(visiblePath: $0) }
            let text = try JournalVisibleText(message.text, origin: .legacyUnknown, omissions: omitted, artifacts: artifacts)
            let milliseconds = message.date.timeIntervalSince1970 * 1000
            guard milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else { throw JournalError.corrupt }
            events.append(JournalEvent(id: id, taskID: taskID!, attemptID: nil, createdAtMilliseconds: Int64(milliseconds), payload: message.role == "user" ? .user(text) : .assistant(text)))
            ordinal += 1
        }
        if let taskID { try finish(taskID, last: true) }
        let manifest = try JournalLegacyManifest(digest: sourceDigest, expectedEvents: events.count, eventsDigest: journalEventsDigest(events))
        return JournalLegacySnapshot(manifest: manifest, events: events, omittedActivityCount: activityCount, omittedModelMessageCount: modelCount)
    }
    /// Batches stay within both event and encoded byte limits; an oversized event refuses.
    public func batches() throws -> [[JournalEvent]] {
        var result: [[JournalEvent]] = [], pending: [JournalEvent] = [], bytes = 0
        for event in events {
            let size = try journalEncoded(event).count
            if !pending.isEmpty, pending.count == 32 || bytes + size > 512 * 1024 { result.append(pending); pending = []; bytes = 0 }
            pending.append(event); bytes += size
        }
        if !pending.isEmpty { result.append(pending) }; return result
    }
}
