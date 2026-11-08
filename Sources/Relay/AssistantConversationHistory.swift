import Foundation
import CryptoKit
import RelayJournal

/// App bridge only. SQLite ownership and immutable checkpoints stay in RelayJournal.
/// This draft is ignored and requires real Store integration qualification before promotion.
@MainActor final class AssistantConversationHistory {
    struct Run: Sendable {
        let taskID = UUID()
        let attemptID = UUID()
        let relation: JournalRunRelation
        init(logicalTaskID: UUID, predecessor: Run? = nil, cause: JournalRunCause) throws {
            relation = try JournalRunRelation(logicalTaskID: logicalTaskID, predecessorRunID: predecessor?.taskID, cause: cause)
        }
    }
    struct Restored { let messages: [ChatMessage]; let activity: [ActivityEntry]; let interrupted: Bool; let latestOutcome: JournalTaskOutcome? }
    private struct Pending { let run: Run; let message: ChatMessage; let text: JournalVisibleText }
    private struct Opened: Sendable { let journal: ConversationJournal; let scope: JournalScope; let records: [JournalRecord]; let interrupted: Bool }
    let preferencesURL: URL?
    private let legacyURL: URL?
    private let directory: URL
    private var opening: Task<Opened, Error>?
    private var opened: Opened?
    private var pending: [Pending] = []
    private var started: Set<UUID> = []
    private var startEvents: [UUID: JournalEvent] = [:]
    private var finishEvents: [UUID: JournalEvent] = [:]
    private var checkpoints: [UUID: JournalDispatchCheckpoint] = [:]
    private var pendingResultSaves: [UUID: JournalDispatchCheckpoint] = [:]
    private var pendingFinishes: [UUID: (Run, JournalTaskOutcome)] = [:]
    private var artifacts: [UUID: [JournalArtifactReference]] = [:]
    private var flushing: Task<[UUID], Error>?
    private var flushID: UUID?

    init(stateURL: URL?) {
        legacyURL = stateURL
        preferencesURL = stateURL.map { $0.appendingPathExtension("preferences-v2.json") }
        directory = stateURL.map { $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + ".conversation-v1", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("relay-journal-session-" + UUID().uuidString, isDirectory: true)
    }
    private func load() async throws -> Opened {
        if let opened { return opened }
        if let opening { return try await opening.value }
        let directory = directory, legacyURL = legacyURL
        let task = Task<Opened, Error> {
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("Conversation.sqlite").path)
            var snapshot: JournalLegacySnapshot?
            if !exists, let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) { snapshot = try await JournalLegacySnapshot.read(legacyURL) }
            var journal = try await ConversationJournal.open(directory: directory, initialization: snapshot.map { .importing($0.manifest) } ?? .ready)
            if try await !journal.isReady(), snapshot == nil {
                try await journal.close()
                guard let legacyURL else { throw JournalError.notReady }
                snapshot = try await JournalLegacySnapshot.read(legacyURL)
                journal = try await ConversationJournal.open(directory: directory, initialization: .importing(snapshot!.manifest))
            }
            let scope = try await journal.scope()
            if let snapshot {
                for batch in try snapshot.batches() { try await journal.importLegacyBatch(batch, manifest: snapshot.manifest, expectedScope: scope) }
                try await journal.finishLegacyImport(manifest: snapshot.manifest, expectedScope: scope)
            }
            let recovered = try await journal.recoverInterrupted(expectedScope: scope)
            var records: [JournalRecord] = [], cursor: JournalCursor?
            repeat {
                let page = try await journal.page(after: cursor, expectedScope: scope)
                records += page.records; cursor = page.hasLater ? page.cursor : nil
            } while cursor != nil
            return Opened(journal: journal, scope: scope, records: records, interrupted: !recovered.isEmpty)
        }
        opening = task
        do { let value = try await task.value; opened = value; opening = nil; return value }
        catch { opening = nil; throw error }
    }
    func restore() async throws -> Restored {
        let value = try await load()
        var messages: [ChatMessage] = [], activity: [ActivityEntry] = []
        var linkedOutputs: [UUID: Set<Data>] = [:]
        for record in value.records {
            switch record.event.payload {
            case let .user(text), let .assistant(text), let .question(text), let .answer(text):
                for reference in text.artifacts { linkedOutputs[record.event.taskID, default: []].insert(Data(reference.visiblePath.utf8)) }
            default: break
            }
        }
        var latestOutcome: JournalTaskOutcome?
        for record in value.records {
            let id = Self.messageID(record.event.id)
            let date = Date(timeIntervalSince1970: Double(record.event.createdAtMilliseconds ?? 0) / 1000)
            let text: JournalVisibleText?, role: String
            switch record.event.payload {
            case let .user(body), let .answer(body): text = body; role = "user"
            case let .assistant(body), let .question(body): text = body; role = "assistant"
            case let .intent(intent):
                text = nil; role = "assistant"
                activity.append(ActivityEntry(id: id, name: intent.toolName, detail: "A durable intent was recorded. This alone does not prove dispatch.", status: "requested", date: date))
            case let .result(outcome):
                role = "assistant"
                let recovered = outcome.artifacts.filter { !(linkedOutputs[record.event.taskID]?.contains(Data($0.visiblePath.utf8)) ?? false) }
                if recovered.isEmpty { text = nil }
                else {
                    text = try JournalVisibleText("Recovered output reference from an earlier tool result. Inspect it in Finder; this does not confirm task completion.", origin: .source, artifacts: recovered)
                }
                activity.append(ActivityEntry(id: id, name: "Action checkpoint", detail: "Historical operational metadata only; no raw app tree, image or provider envelope was retained.", status: outcome.kind == .returnedVerified ? "verified receipt" : "inspect uncertainty", date: date))
            case let .finished(outcome): latestOutcome = outcome; text = nil; role = "assistant"
            default: text = nil; role = "assistant"
            }
            if let text {
                artifacts[id] = text.artifacts
                messages.append(ChatMessage(id: id, role: role, text: text.text, date: date, artifacts: text.artifacts.map(\.visiblePath)))
            }
        }
        return Restored(messages: messages, activity: Array(activity.suffix(400)), interrupted: value.interrupted || latestOutcome == .interrupted, latestOutcome: latestOutcome)
    }
    private static var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func messageID(_ id: JournalOpaqueID) -> UUID {
        let string = String(decoding: id.bytes, as: UTF8.self)
        if let value = UUID(uuidString: string) { return value }
        if string.hasPrefix("legacy:"), let tail = string.split(separator: ":").last, let value = UUID(uuidString: String(tail)) { return value }
        let bytes = Data(SHA256.hash(data: id.bytes)).prefix(16)
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
    func stage(_ message: ChatMessage, run: Run, grants: [ScopeGrant]) throws {
        guard !pending.contains(where: { $0.message.id == message.id }) else { return }
        let references = try message.artifacts.map { path in
            if let bound = try? JournalArtifactAccess.capture(visiblePath: path, isAuthorized: { value in _ = try ToolPolicy.scopedURL(value, grants: grants); return true }) { return bound }
            return try JournalArtifactReference(visiblePath: path)
        }
        artifacts[message.id] = references
        // Derived assistant text remains local history, with no automatic post-restart prompt reuse.
        let text = try JournalVisibleText(message.text, origin: message.role == "user" ? .user : .source, artifacts: references)
        pending.append(Pending(run: run, message: message, text: text))
    }
    private func startEvent(_ run: Run, opened: Opened) throws -> JournalEvent {
        if let event = startEvents[run.taskID] { return event }
        let event = JournalEvent(id: try JournalOpaqueID("start:" + run.taskID.uuidString), taskID: run.taskID, attemptID: run.attemptID,
            createdAtMilliseconds: Self.nowMilliseconds, payload: .started(producerEpoch: opened.journal.producerEpoch, relation: run.relation))
        startEvents[run.taskID] = event
        return event
    }
    private func start(_ run: Run, opened: Opened) async throws {
        guard !started.contains(run.taskID) else { return }
        let event = try startEvent(run, opened: opened)
        _ = try await opened.journal.appendBatch([event], expectedScope: opened.scope)
        started.insert(run.taskID)
    }
    @discardableResult func flush() async throws -> [UUID] {
        while let current = flushing {
            let previousID = flushID
            _ = try await current.value
            if flushID == previousID { flushing = nil; flushID = nil }
        }
        let identifier = UUID()
        let task = Task<[UUID], Error> {
            let opened = try await self.load(); var saved: [UUID] = []
            while let entry = self.pending.first {
                let message = entry.message
                let payload: JournalPayload = message.role == "user" ? .user(entry.text) : .assistant(entry.text)
                let milliseconds = message.date.timeIntervalSince1970 * 1000
                guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else { throw JournalError.invalidEvent }
                let event = JournalEvent(id: try JournalOpaqueID(message.id.uuidString), taskID: entry.run.taskID, attemptID: entry.run.attemptID,
                    createdAtMilliseconds: Int64(milliseconds), payload: payload)
                var batch: [JournalEvent] = []
                if !self.started.contains(entry.run.taskID) {
                    batch.append(try self.startEvent(entry.run, opened: opened))
                }
                batch.append(event)
                _ = try await opened.journal.appendBatch(batch, expectedScope: opened.scope)
                self.started.insert(entry.run.taskID)
                guard self.pending.first?.message.id == message.id else { throw JournalError.invalidTransition }
                self.pending.removeFirst(); saved.append(message.id)
            }
            return saved
        }
        flushing = task; flushID = identifier
        do {
            let saved = try await task.value
            if flushID == identifier { flushing = nil; flushID = nil }; return saved
        } catch { if flushID == identifier { flushing = nil; flushID = nil }; throw error }
    }
    func perform<Output>(_ call: ToolCall, proposalID: UUID, run: Run, journalEffect: JournalEffect = .unknown, validate: @escaping @MainActor () throws -> Void,
                         admitAction: (@MainActor @Sendable () async throws -> Void)? = nil,
                         action: @escaping @MainActor () async throws -> Output,
                         result: @escaping @MainActor (Output) -> ToolResult,
                         unsavedResult: @escaping @MainActor (ToolResult) -> Void,
                         journalOutcome: (@MainActor (Output, JournalIntent) -> JournalToolOutcome)? = nil,
                         failureOutcome: (@MainActor (any Error, JournalIntent) -> JournalToolOutcome?)? = nil,
                         metadataFailure: @escaping @MainActor (ToolResult) -> Void = { _ in }) async throws -> Output {
        _ = try await flush(); let opened = try await load(); try await start(run, opened: opened)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let encoded = try encoder.encode(call); guard encoded.count <= 128 * 1024 else { throw JournalError.tooLarge }
        let intent = try JournalIntent(proposalID: proposalID, producerEpoch: opened.journal.producerEpoch, toolCallID: JournalOpaqueID(call.id), toolName: call.name,
            callDigest: Data(SHA256.hash(data: encoded)), effect: journalEffect)
        let event = JournalEvent(id: try JournalOpaqueID(UUID().uuidString), taskID: run.taskID, attemptID: run.attemptID, createdAtMilliseconds: Self.nowMilliseconds, payload: .intent(intent))
        let checkpoint = checkpoints[run.taskID] ?? JournalDispatchCheckpoint(journal: opened.journal)
        checkpoints[run.taskID] = checkpoint
        var output: Output?, actionError: (any Error)?, serializationError: (any Error)?
        do {
        _ = try await checkpoint.execute(event, expectedScope: opened.scope, validate: validate, admitAction: admitAction, action: {
            let value: Output
            do { value = try await action() }
            catch {
                actionError = error
                return failureOutcome?(error, intent) ?? JournalToolOutcome(intent: intent, kind: .effectUncertain)
            }
            output = value
            let observed = result(value)
            if let journalOutcome { return journalOutcome(value, intent) }
            do {
                let references = try observed.artifactPath.map { [try JournalArtifactReference(visiblePath: $0)] } ?? []
                return JournalToolOutcome(intent: intent, kind: observed.verified ? .returnedVerified : .returnedUnverified, artifacts: references)
            } catch {
                serializationError = error
                return JournalToolOutcome(intent: intent, kind: .effectUncertain)
            }
        })
        } catch {
            if checkpoint.pendingResultCount > 0 {
                pendingResultSaves[intent.invocationID] = checkpoint
                if let output {
                    let observed = result(output)
                    if serializationError != nil {
                        metadataFailure(ToolResult(summary: observed.summary, evidence: observed.evidence + " Output link metadata could not be retained; its checkpoint also remains unsaved.", verified: observed.verified))
                    } else { unsavedResult(observed) }
                }
            }
            throw error
        }
        if let serializationError {
            if let output {
                let observed = result(output)
                metadataFailure(ToolResult(summary: observed.summary, evidence: observed.evidence + " Output link metadata could not be retained.", verified: observed.verified))
            }
            throw serializationError
        }
        if let actionError { throw actionError }
        guard let output else { throw JournalError.invalidEvent }; return output
    }
    func prepare(_ run: Run) async throws {
        _ = try await flush(); let opened = try await load(); try await start(run, opened: opened)
    }
    func journalForTesting() async throws -> ConversationJournal { try await load().journal }
    func retryResultSaves() async throws {
        // No action closures, proposal reminting or side-effect retries are accepted here.
        for (invocationID, checkpoint) in pendingResultSaves {
            _ = try await checkpoint.savePendingResult(invocationID: invocationID)
            pendingResultSaves.removeValue(forKey: invocationID)
        }
        for (_, value) in pendingFinishes { try await finish(value.0, outcome: value.1) }
    }
    func finish(_ run: Run, outcome: JournalTaskOutcome) async throws {
        let event: JournalEvent
        if let retained = finishEvents[run.taskID] {
            guard retained.payload == .finished(outcome) else { throw JournalError.conflictingID }
            event = retained
        } else {
            event = JournalEvent(id: try JournalOpaqueID("finish:" + run.taskID.uuidString), taskID: run.taskID, attemptID: run.attemptID, createdAtMilliseconds: Self.nowMilliseconds, payload: .finished(outcome))
            finishEvents[run.taskID] = event
        }
        pendingFinishes[run.taskID] = (run, outcome)
        _ = try await flush(); let opened = try await load(); try await start(run, opened: opened)
        _ = try await opened.journal.finishTask(event, expectedScope: opened.scope)
        checkpoints.removeValue(forKey: run.taskID); started.remove(run.taskID); pendingFinishes.removeValue(forKey: run.taskID)
    }
    func stop(_ run: Run?) { if let run { checkpoints[run.taskID]?.stop() } }
    func validateArtifactForContentAccess(messageID: UUID, path: String, grants: [ScopeGrant]) throws {
        let references = artifacts[messageID]?.filter { Data($0.visiblePath.utf8) == Data(path.utf8) } ?? []
        guard references.count == 1 else { throw JournalError.unsafeLocation }
        try JournalArtifactAccess.validate(references[0], isAuthorized: { value in _ = try ToolPolicy.scopedURL(value, grants: grants); return true })
    }
    func close() async throws {
        if let flushing { _ = try await flushing.value }
        if let opening { _ = try await opening.value }
        if let opened { try await opened.journal.close() }
        opened = nil; opening = nil
    }
    func clear() async throws {
        // The Store already owns Stop/drain. Settle existing writes without making
        // an unsaved pending draft a prerequisite for the user's explicit clear.
        if let flushing { _ = try? await flushing.value }
        if let opening { _ = try? await opening.value }
        let value: Opened
        if let opened { value = opened }
        else if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Conversation.sqlite").path) {
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Explicit clear consumes even an unreadable legacy source, preserving its bytes.
            let journal = try await ConversationJournal.open(directory: directory)
            value = Opened(journal: journal, scope: try await journal.scope(), records: [], interrupted: false)
        } else {
            // Unknown/newer SQLite originals are preserved; no automatic empty replacement.
            value = try await load()
        }
        let scope = try await value.journal.reset(expectedScope: value.scope)
        opened = Opened(journal: value.journal, scope: scope, records: [], interrupted: false)
        pending.removeAll(); pendingResultSaves.removeAll(); pendingFinishes.removeAll(); checkpoints.removeAll(); started.removeAll(); startEvents.removeAll(); finishEvents.removeAll(); artifacts.removeAll()
        opening = nil; flushing = nil; flushID = nil
    }
}
