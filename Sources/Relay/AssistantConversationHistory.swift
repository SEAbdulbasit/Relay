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
    enum UserMessageReceiptFailure: Error, Equatable { case invalidBinding, unavailable }
    /// Comparison metadata only. No user prose, editor content or saved-record
    /// object is retained by the staging identity or its eventual receipt.
    fileprivate struct UserMessageIdentity: Equatable {
        let messageID: UUID, logicalTaskID: UUID, runID: UUID, attemptID: UUID
        let anchorID: UUID, originID: UUID
        let originRevision: Int
        let requestDigest: Data, literalDigest: Data
        let requestByteCount: Int, literalByteCount: Int
        init(_ binding: NativeExactUnsentMessageBinding) {
            messageID = binding.messageID; logicalTaskID = binding.logicalTaskID
            runID = binding.runID; attemptID = binding.attemptID
            anchorID = binding.anchorID; originID = binding.originID; originRevision = binding.originRevision
            requestDigest = Data(SHA256.hash(data: binding.exactRequestUTF8))
            literalDigest = Data(SHA256.hash(data: binding.literalUTF8))
            requestByteCount = binding.exactRequestUTF8.count; literalByteCount = binding.literalUTF8.count
        }
    }
    /// A particular original delivery ticket, not a saved-message capability.
    /// Only this file constructs it. A clone with the same fields is not it.
    @MainActor final class UserMessageStaging {
        fileprivate weak var issuer: AssistantConversationHistory?
        fileprivate weak var submission: ConversationSubmission?
        fileprivate let epoch: UUID, identity: UserMessageIdentity
        fileprivate let createdAtMilliseconds: Int64
        fileprivate var revoked = false, delivered = false, acknowledgmentLost = false
        fileprivate init(issuer: AssistantConversationHistory, submission: ConversationSubmission,
                         epoch: UUID, identity: UserMessageIdentity, createdAtMilliseconds: Int64) {
            self.issuer = issuer; self.submission = submission; self.epoch = epoch
            self.identity = identity; self.createdAtMilliseconds = createdAtMilliseconds
        }
    }
    /// Process-only evidence of the exact .user record returned after COMMIT.
    /// This does not acknowledge a ticket, grant input, or establish a target.
    @MainActor final class SavedUserMessage {
        let scope: JournalScope, sequence: Int64, eventID: Data, recordDigest: Data
        fileprivate let staging: UserMessageStaging
        fileprivate init(staging: UserMessageStaging, record: JournalRecord) {
            self.staging = staging; scope = record.scope; sequence = record.sequence
            eventID = record.event.id.bytes; recordDigest = record.digest
        }
        func validate(staging: UserMessageStaging, submission: ConversationSubmission,
                      run: Run, binding: NativeExactUnsentMessageBinding) throws {
            guard self.staging === staging, let issuer = staging.issuer,
                  issuer.opened?.scope == scope else { throw UserMessageReceiptFailure.unavailable }
            try issuer.validateUserMessage(staging, submission: submission, run: run, binding: binding)
            guard staging.delivered, eventID == Data(binding.messageID.uuidString.utf8),
                  sequence > 0, recordDigest.count == 32 else { throw UserMessageReceiptFailure.unavailable }
        }
        /// Only a full current validation of this actual returned receipt can
        /// seal these immutable bindings. This is not another ACK/input grant.
        func bindValidated(staging: UserMessageStaging, submission: ConversationSubmission,
                           run: Run, binding: NativeExactUnsentMessageBinding) throws -> ValidatedBinding {
            try validate(staging: staging, submission: submission, run: run, binding: binding)
            return ValidatedBinding(saved: self, submission: submission, run: run)
        }
        /// The retained receipt, ticket text/ID, staging identity and run are
        /// immutable. Keep every mutable issuer/epoch/status/Stop fence live.
        @MainActor final class ValidatedBinding {
            private let saved: SavedUserMessage
            private let submission: ConversationSubmission
            private let run: Run
            fileprivate init(saved: SavedUserMessage, submission: ConversationSubmission, run: Run) {
                self.saved = saved; self.submission = submission; self.run = run
            }
            func validate() throws {
                try Task.checkCancellation()
                guard let issuer = saved.staging.issuer, issuer.opened?.scope == saved.scope else {
                    throw UserMessageReceiptFailure.unavailable
                }
                try issuer.validateUserMessageMetadata(saved.staging, submission: submission, run: run)
                guard saved.staging.delivered else { throw UserMessageReceiptFailure.unavailable }
            }
        }

    }
    private struct UserMessageDelivery {
        let staging: UserMessageStaging
        let deposit: @MainActor (SavedUserMessage) -> Void
    }
    /// Factual native-effect settlement, never another phase's dispatch grant.
    /// Only the actual result-return/save-pending paths in this file mint it.
    @MainActor final class NativeTextEffectSettlement {
        private weak var issuer: AssistantConversationHistory?
        private let epoch: UUID
        private let effect: NativeControlSession.ExactUnsentEffect
        let scope: JournalScope, sequence: Int64, recordDigest: Data
        let invocationID: UUID
        fileprivate init?(issuer: AssistantConversationHistory, epoch: UUID,
                          effect: NativeControlSession.ExactUnsentEffect, run: Run,
                          intent: JournalIntent, record: JournalRecord) {
            let expectedName = effect.phase == .focus ? "native_exact_unsent_focus" : "native_exact_unsent_insert"
            guard intent.toolName == expectedName, effect.identity.call.name == expectedName,
                  intent.toolCallID.bytes == Data(effect.identity.call.id.utf8),
                  effect.runID == run.taskID, effect.attemptID == run.attemptID,
                  effect.logicalTaskID == run.relation.logicalTaskID, effect.proposalID == intent.proposalID,
                  effect.callDigest == intent.callDigest, effect.invocationID == intent.invocationID,
                  record.sequence > 0, record.digest.count == 32,
                  record.event.taskID == run.taskID, record.event.attemptID == run.attemptID,
                  case let .result(outcome) = record.event.payload,
                  outcome.invocationID == intent.invocationID, outcome.callDigest == intent.callDigest,
                  outcome.kind == effect.journalKind else { return nil }
            self.issuer = issuer; self.epoch = epoch; self.effect = effect
            scope = record.scope; sequence = record.sequence; recordDigest = record.digest
            invocationID = intent.invocationID
        }
        func validate(effect: NativeControlSession.ExactUnsentEffect) throws {
            guard self.effect === effect, let issuer, issuer.nativeTextEffectEpoch == epoch,
                  issuer.opened?.scope == scope else { throw JournalError.dispatchRevoked }
        }
    }
    private struct PendingNativeTextEffect {
        let effect: NativeControlSession.ExactUnsentEffect
        let run: Run, intent: JournalIntent, epoch: UUID
        let settled: @MainActor (NativeControlSession.ExactUnsentEffect, NativeTextEffectSettlement) -> Void
    }
    /// Process-only proof of this bridge's actual successful result checkpoint.
    /// Only this file can mint it, after the saved record is returned by SQLite.
    final class FileReadSettlement {
        let receipt: FileExtractionReceipt
        let runID: UUID, attemptID: UUID, proposalID: UUID
        let providerID: Data, callDigest: String, resultDigest: Data
        let sequence: Int64
        fileprivate init?(call: ToolCall, result: ToolResult, run: Run, intent: JournalIntent, record: JournalRecord) {
            guard call.name == "read_file", result.verified, let receipt = result.fileExtractionReceipt,
                  record.event.taskID == run.taskID, record.event.attemptID == run.attemptID,
                  case let .result(outcome) = record.event.payload,
                  outcome.kind == .returnedVerified, outcome.invocationID == intent.invocationID,
                  outcome.callDigest == intent.callDigest, record.sequence > 0 else { return nil }
            self.receipt = receipt; runID = run.taskID; attemptID = run.attemptID; proposalID = intent.proposalID
            providerID = Data(call.id.utf8); callDigest = ToolPolicy.fingerprint(call)
            resultDigest = FileExtractionReceipt.resultDigest(for: result); sequence = record.sequence
        }
        func matches(call: ToolCall, result: ToolResult, run: Run, proposalID: UUID) -> Bool {
            result.fileExtractionReceipt === receipt && run.taskID == runID && run.attemptID == attemptID
                && self.proposalID == proposalID && Data(call.id.utf8) == providerID
                && ToolPolicy.fingerprint(call) == callDigest && FileExtractionReceipt.resultDigest(for: result) == resultDigest
        }
    }
    /// Dedicated actual saved-result token; a file-read token is never search authority.
    final class FilenameSearchSettlement {
        let receipt: FilenameSearchReceipt
        let runID: UUID, attemptID: UUID, proposalID: UUID
        let providerID: Data, callDigest: String, resultDigest: Data
        let sequence: Int64
        fileprivate init?(call: ToolCall, result: ToolResult, run: Run, intent: JournalIntent, record: JournalRecord) {
            guard call.name == "search_files", result.verified, let receipt = result.filenameSearchReceipt,
                  record.event.taskID == run.taskID, record.event.attemptID == run.attemptID,
                  case let .result(outcome) = record.event.payload,
                  outcome.kind == .returnedVerified, outcome.invocationID == intent.invocationID,
                  outcome.callDigest == intent.callDigest, record.sequence > 0 else { return nil }
            self.receipt = receipt; runID = run.taskID; attemptID = run.attemptID; proposalID = intent.proposalID
            providerID = Data(call.id.utf8); callDigest = ToolPolicy.fingerprint(call)
            resultDigest = FilenameSearchReceipt.digest(result); sequence = record.sequence
        }
        func matches(call: ToolCall, result: ToolResult, run: Run, proposalID: UUID) -> Bool {
            result.filenameSearchReceipt === receipt && run.taskID == runID && run.attemptID == attemptID
                && self.proposalID == proposalID && Data(call.id.utf8) == providerID
                && ToolPolicy.fingerprint(call) == callDigest && FilenameSearchReceipt.digest(result) == resultDigest
        }
    }
    final class CalendarReadSettlement {
        let receipt: CalendarReadReceipt
        let runID: UUID, attemptID: UUID, proposalID: UUID
        let providerID: Data, callDigest: String, resultDigest: Data
        let sequence: Int64
        fileprivate init?(call: ToolCall, result: ToolResult, run: Run, intent: JournalIntent, record: JournalRecord) {
            guard call.name == "read_calendar", result.verified, CalendarReadReceipt.isBounded(result),
                  let receipt = result.calendarReadReceipt,
                  record.event.taskID == run.taskID, record.event.attemptID == run.attemptID,
                  case let .result(outcome) = record.event.payload,
                  outcome.kind == .returnedVerified, outcome.invocationID == intent.invocationID,
                  outcome.callDigest == intent.callDigest, record.sequence > 0 else { return nil }
            self.receipt = receipt; runID = run.taskID; attemptID = run.attemptID; proposalID = intent.proposalID
            providerID = Data(call.id.utf8); callDigest = ToolPolicy.fingerprint(call)
            resultDigest = CalendarReadReceipt.digest(result); sequence = record.sequence
        }
        func matches(call: ToolCall, result: ToolResult, run: Run, proposalID: UUID) -> Bool {
            result.calendarReadReceipt === receipt && run.taskID == runID && run.attemptID == attemptID
                && self.proposalID == proposalID && Data(call.id.utf8) == providerID
                && ToolPolicy.fingerprint(call) == callDigest && CalendarReadReceipt.digest(result) == resultDigest
        }
    }
    /// Actual returned row only; a remote response is factual snapshot DATA,
    /// not independent verification of a user goal, account or remote effect.
    final class MCPTaskSettlement {
        let receipt: MCPTaskReceipt
        let scope: JournalScope, sequence: Int64
        private weak var issuer: AssistantConversationHistory?
        private let epoch: UUID
        fileprivate init?(issuer: AssistantConversationHistory, epoch: UUID, receipt: MCPTaskReceipt, run: Run,
            intent: JournalIntent, record: JournalRecord, expectedScope: JournalScope) {
            guard MainAgentMCPTools.names.contains(receipt.toolName), receipt.toolName == intent.toolName,
                  receipt.runID == run.taskID, receipt.attemptID == run.attemptID, receipt.proposalID == intent.proposalID,
                  receipt.providerID == intent.toolCallID.bytes, receipt.callDigest == intent.callDigest,
                  record.scope == expectedScope, record.event.taskID == run.taskID, record.event.attemptID == run.attemptID,
                  case let .result(outcome) = record.event.payload,
                  (receipt.reportedVerified ? outcome.kind == .returnedVerified : outcome.kind == .returnedUnverified),
                  outcome.invocationID == intent.invocationID, outcome.callDigest == intent.callDigest,
                  record.sequence > 0, issuer.mcpTaskEpoch == epoch, issuer.opened?.scope == expectedScope else { return nil }
            self.issuer = issuer; self.epoch = epoch; self.receipt = receipt; scope = record.scope; sequence = record.sequence
        }
        func matches(receipt: MCPTaskReceipt, run: Run, proposalID: UUID) -> Bool {
            guard let issuer, issuer.mcpTaskEpoch == epoch, issuer.opened?.scope == scope else { return false }
            return self.receipt === receipt && run.taskID == receipt.runID && run.attemptID == receipt.attemptID
                && proposalID == receipt.proposalID
        }
        func matches(call: ToolCall, result: ToolResult, run: Run, proposalID: UUID) -> Bool {
            matches(receipt: receipt, run: run, proposalID: proposalID)
                && receipt.matches(call: call, result: result, run: run, proposalID: proposalID)
        }
    }
    /// Storage-only repair retains metadata/actual receipt, not private output,
    /// ToolCall arguments or a dispatch closure. Only returned rows mint tokens.
    private struct PendingMCPTaskResult {
        let receipt: MCPTaskReceipt, run: Run, intent: JournalIntent, epoch: UUID, scope: JournalScope
        let settled: @MainActor (MCPTaskReceipt, MCPTaskSettlement) -> Void
    }
    /// Calendar bodies and fabricated artifact paths must not reach journal
    /// metadata/unsaved/error callbacks, even without a valid producer receipt.
    static func calendarFact(_ result: ToolResult) -> ToolResult {
        ToolResult(summary: "The calendar result is unavailable for this task.",
            evidence: "Read the selected calendars again to use their current events. The recorded read outcome is retained; no action was repeated.",
            verified: result.verified)
    }
    struct Restored { let messages: [ChatMessage]; let activity: [ActivityEntry]; let interrupted: Bool; let latestOutcome: JournalTaskOutcome?; let messageRunIDs: [UUID: UUID] }
    private struct Pending {
        let run: Run; let message: ChatMessage; let text: JournalVisibleText
        var userMessage: UserMessageDelivery? = nil
        var replySelection: ConversationReplySelection? = nil
    }
    struct Opened: Sendable { let journal: ConversationJournal; let scope: JournalScope; var records: [JournalRecord]; let interrupted: Bool }
    var currentOpened: Opened? { opened }
    private(set) var installedSummaries: [ConversationSummary] = []
    var latestSummary: ConversationSummary? { installedSummaries.last }
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
    private var userMessageEpoch = UUID()
    private var userMessageIssuerClosed = false, acceptingUserMessages = true
    private var userMessages: [UUID: UserMessageStaging] = [:]
    private var stoppedUserMessageRuns: Set<UUID> = []
    private var mcpTaskEpoch = UUID()
    private var pendingMCPTaskResults: [UUID: PendingMCPTaskResult] = [:]
    private var nativeTextEffectEpoch = UUID()
    private var replyEpoch = UUID()
    private var replySequences: [UUID: Int64] = [:]
    private var pendingNativeTextEffects: [UUID: PendingNativeTextEffect] = [:]

    init(stateURL: URL?) {
        legacyURL = stateURL
        preferencesURL = stateURL.map { $0.appendingPathExtension("preferences-v2.json") }
        directory = stateURL.map { $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + ".conversation-v1", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("relay-journal-session-" + UUID().uuidString, isDirectory: true)
    }
    var hasExistingStorage: Bool {
        if opened != nil || opening != nil { return true }
        guard let legacyURL else { return false }
        if FileManager.default.fileExists(atPath: legacyURL.path) { return true }
        if FileManager.default.fileExists(atPath: directory.path) { return true }
        return false
    }
    private func load() async throws -> Opened {
        if let opened { return opened }
        if let opening { return try await opening.value }
        let directory = directory, legacyURL = legacyURL
        let task = Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("Conversation.sqlite").path)
            var snapshot: JournalLegacySnapshot?
            if !exists, let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) { snapshot = try await JournalLegacySnapshot.read(legacyURL) }
            var journal = try await ConversationJournal.open(directory: directory, initialization: snapshot.map { .importing($0.manifest) } ?? .ready)
            let scope = try await journal.scope()
            if !exists, snapshot == nil {
                return Opened(journal: journal, scope: scope, records: [], interrupted: false)
            }
            if try await !journal.isReady(), snapshot == nil {
                try await journal.close()
                guard let legacyURL else { throw JournalError.notReady }
                snapshot = try await JournalLegacySnapshot.read(legacyURL)
                journal = try await ConversationJournal.open(directory: directory, initialization: .importing(snapshot!.manifest))
            }
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
        do {
            let value = try await task.value
            opened = value
            opening = nil
            let summaryURL = directory.appendingPathComponent("summaries.json")
            if FileManager.default.fileExists(atPath: summaryURL.path),
               let data = try? LocalStateFile.read(summaryURL, maximumBytes: LocalPrivateFileWriter.maximumSupportedBytes),
               let loaded = try? JSONDecoder().decode([ConversationSummary].self, from: data) {
                installedSummaries = loaded.filter { $0.scope == value.scope }
            }
            return value
        }
        catch { opening = nil; throw error }
    }
    /// Actual current-journal DATA lease. Its constructor is producer-only;
    /// no record body, artifact, model history or input capability is retained.
    @MainActor final class ConversationQueryLease {
        let scope: JournalScope
        fileprivate let epoch: UUID, runID: UUID, scopeID: UUID
        private weak var issuer: AssistantConversationHistory?
        private let checkStore: @MainActor @Sendable () throws -> Void
        private let sourceRevision: Int
        fileprivate init(issuer: AssistantConversationHistory, scope: JournalScope,
                         runID: UUID, scopeID: UUID, sourceRevision: Int,
                         checkStore: @escaping @MainActor @Sendable () throws -> Void) {
            self.issuer = issuer; self.scope = scope; epoch = issuer.userMessageEpoch
            self.runID = runID; self.scopeID = scopeID; self.sourceRevision = sourceRevision; self.checkStore = checkStore
        }
        func validate() throws {
            try Task.checkCancellation(); try checkStore()
            guard let issuer, !issuer.userMessageIssuerClosed, issuer.userMessageEpoch == epoch,
                  issuer.opened?.scope == scope else { throw ConversationHistoryQueryTools.Failure.unavailable }
            try checkStore(); try Task.checkCancellation()
        }
        var sourceProof: ModelInputSourceProof {
            var bytes = Data()
            for part in [scope.storeID.uuidString, scope.generation.uuidString, runID.uuidString,
                         scopeID.uuidString, String(sourceRevision)] {
                let field = Data(part.utf8); var count = UInt64(field.count).bigEndian
                withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(field)
            }
            return .source(identity: .init(owner: epoch, sourceID: bytes, purpose: "eligible saved conversation data"),
                finalMetadata: { [self] in try validate() }, { [self] in try validate() })
        }
    }
    struct ConversationQueryPage {
        let records: [JournalRecord]
        let nextCursor: String?
        let hasMore: Bool
    }
    private struct ConversationCursor {
        let value: JournalCursor, epoch: UUID, runID: UUID, scopeID: UUID
    }
    private var conversationCursors: [String: ConversationCursor] = [:]
    private var conversationCursorOrder: [String] = []

    /// Store restoration must already have loaded this journal. A model query
    /// does not import, repair, flush pending messages or create another store.
    func openConversationQuery(runID: UUID, scopeID: UUID, sourceRevision: Int,
        validateCurrent: @escaping @MainActor @Sendable () throws -> Void) throws -> ConversationQueryLease {
        try validateCurrent(); try Task.checkCancellation()
        guard let opened, !userMessageIssuerClosed else { throw ConversationHistoryQueryTools.Failure.unavailable }
        let lease = ConversationQueryLease(issuer: self, scope: opened.scope, runID: runID,
            scopeID: scopeID, sourceRevision: sourceRevision, checkStore: validateCurrent)
        try lease.validate(); return lease
    }
    func conversationQueryRecord(_ lease: ConversationQueryLease, sequence: Int64) async throws -> JournalRecord? {
        try lease.validate()
        guard let opened else { throw ConversationHistoryQueryTools.Failure.unavailable }
        let record: JournalRecord?
        do { record = try await opened.journal.record(sequence: sequence, expectedScope: lease.scope) }
        catch { try lease.validate(); throw ConversationHistoryQueryTools.Failure.unavailable }
        try lease.validate(); return record
    }
    func conversationQueryPage(_ lease: ConversationQueryLease, cursor: String?) async throws -> ConversationQueryPage {
        try lease.validate()
        guard let opened else { throw ConversationHistoryQueryTools.Failure.unavailable }
        let after: JournalCursor?
        if let cursor {
            guard let saved = conversationCursors[cursor], saved.epoch == lease.epoch,
                  saved.runID == lease.runID, saved.scopeID == lease.scopeID, saved.value.scope == lease.scope else {
                throw ConversationHistoryQueryTools.Failure.invalidRequest
            }
            after = saved.value
        } else { after = nil }
        let page: JournalPage
        do { page = try await opened.journal.page(after: after, limit: 100, byteBudget: 1_048_576, expectedScope: lease.scope) }
        catch { try lease.validate(); throw ConversationHistoryQueryTools.Failure.unavailable }
        try lease.validate()
        let next: String?
        if page.hasLater {
            let token = "history-page:" + UUID().uuidString
            conversationCursors[token] = ConversationCursor(value: page.cursor, epoch: lease.epoch,
                runID: lease.runID, scopeID: lease.scopeID)
            conversationCursorOrder.append(token)
            while conversationCursorOrder.count > 64 { conversationCursors.removeValue(forKey: conversationCursorOrder.removeFirst()) }
            next = token
        } else { next = nil }
        return ConversationQueryPage(records: page.records, nextCursor: next, hasMore: page.hasLater)
    }
    func restore() async throws -> Restored {
        let value = try await load()
        var messages: [ChatMessage] = [], activity: [ActivityEntry] = []
        var messageRunIDs: [UUID: UUID] = [:]
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
                messageRunIDs[id] = record.event.taskID
                artifacts[id] = text.artifacts
                messages.append(ChatMessage(id: id, role: role, text: text.text, date: date, artifacts: text.artifacts.map(\.visiblePath), reply: text.reply))
            }
        }
        return Restored(messages: messages, activity: Array(activity.suffix(400)), interrupted: value.interrupted || latestOutcome == .interrupted, latestOutcome: latestOutcome, messageRunIDs: messageRunIDs)
    }
    private static var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func messageID(_ id: JournalOpaqueID) -> UUID {
        let string = String(decoding: id.bytes, as: UTF8.self)
        if let value = UUID(uuidString: string) { return value }
        if string.hasPrefix("legacy:"), let tail = string.split(separator: ":").last, let value = UUID(uuidString: String(tail)) { return value }
        let bytes = Data(SHA256.hash(data: id.bytes)).prefix(16)
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
    private func replyBody(_ record: JournalRecord) throws -> (String, JournalVisibleText) {
        switch record.event.payload {
        case .user(let text), .answer(let text): return ("user", text)
        case .assistant(let text), .question(let text): return ("assistant", text)
        default: throw ConversationReplySelection.Failure.unavailable
        }
    }
    /// Only this actual saved-message lookup prepares a reply. A visible clone,
    /// caller text, old generation or tool record cannot become an original.
    func prepareReply(messageID: UUID, selectedRange: NSRange? = nil) async throws -> ConversationReplySelection {
        let epoch = replyEpoch
        guard !userMessageIssuerClosed else { throw ConversationReplySelection.Failure.unavailable }
        let value = try await load()
        for record in value.records {
            if (try? replyBody(record)) != nil { replySequences[Self.messageID(record.event.id)] = record.sequence }
        }
        guard let sequence = replySequences[messageID], epoch == replyEpoch else { throw ConversationReplySelection.Failure.unavailable }
        guard let record = try await value.journal.record(sequence: sequence, expectedScope: value.scope) else { throw ConversationReplySelection.Failure.unavailable }
        try Task.checkCancellation()
        guard epoch == replyEpoch, !userMessageIssuerClosed, opened?.scope == value.scope,
              Self.messageID(record.event.id) == messageID else { throw ConversationReplySelection.Failure.unavailable }
        let (role, body) = try replyBody(record)
        let quote = try selectedRange.map { try ConversationReplySelection.quote(body.text, range: $0) }
        let reference = try JournalReplyReference(scope: value.scope, sequence: record.sequence, eventID: record.event.id,
            bodyDigest: ConversationReplySelection.digest(body.text), selectedText: quote,
            utf16Location: selectedRange?.location, utf16Length: selectedRange?.length)
        return try ConversationReplySelection(reference: reference, snapshot: quote ?? body.text, role: role)
    }
    /// Prepares a reply for a turn restored from a switched thread archive when the turn
    /// is not yet present in the active SQLite journal generation.
    func prepareFallbackReply(for message: ChatMessage, selectedRange: NSRange? = nil) async throws -> ConversationReplySelection {
        guard ["user", "assistant"].contains(message.role), !userMessageIssuerClosed else {
            throw ConversationReplySelection.Failure.unavailable
        }
        let value = try await load()
        for record in value.records {
            if (try? replyBody(record)) != nil { replySequences[Self.messageID(record.event.id)] = record.sequence }
        }
        if replySequences[message.id] == nil {
            let run = try Run(logicalTaskID: UUID(), cause: .newRequest)
            var historicalMessage = message
            historicalMessage.reply = nil
            try stage(historicalMessage, run: run, grants: [])
            _ = try await flush()
            try await finish(run, outcome: .responseDelivered)
        }
        return try await prepareReply(messageID: message.id, selectedRange: selectedRange)
    }
    /// Recheck the actual immutable source row in this journal generation. This
    /// authorizes historical DATA only, not a fresh original-app source proof.
    func validateReply(_ reference: JournalReplyReference, selection: ConversationReplySelection? = nil) async throws {
        let epoch = replyEpoch
        guard !userMessageIssuerClosed else { throw ConversationReplySelection.Failure.unavailable }
        let value = try await load()
        guard value.scope == reference.scope,
              let record = try await value.journal.record(sequence: reference.sequence, expectedScope: reference.scope) else {
            throw ConversationReplySelection.Failure.unavailable
        }
        try Task.checkCancellation()
        guard epoch == replyEpoch, !userMessageIssuerClosed, opened?.scope == reference.scope,
              record.event.id == reference.eventID else { throw ConversationReplySelection.Failure.unavailable }
        let (role, text) = try replyBody(record)
        guard ConversationReplySelection.digest(text.text) == reference.bodyDigest else { throw ConversationReplySelection.Failure.unavailable }
        if let quote = reference.selectedText {
            guard let location = reference.utf16Location, let length = reference.utf16Length,
                  Data(try ConversationReplySelection.quote(text.text, range: NSRange(location: location, length: length)).utf8) == Data(quote.utf8) else {
                throw ConversationReplySelection.Failure.unavailable
            }
        }
        if let selection {
            guard selection.reference == reference, selection.role == role,
                  Data(selection.snapshot.utf8) == Data((reference.selectedText ?? text.text).utf8) else {
                throw ConversationReplySelection.Failure.unavailable
            }
        }
    }
    func stage(_ message: ChatMessage, run: Run, grants: [ScopeGrant], replySelection: ConversationReplySelection? = nil) throws {
        guard !pending.contains(where: { $0.message.id == message.id }) else { return }
        if let replySelection {
            guard message.reply == replySelection.reference else { throw ConversationReplySelection.Failure.unavailable }
        }
        let references = try message.artifacts.map { path in
            if let bound = try? JournalArtifactAccess.capture(visiblePath: path, isAuthorized: { value in _ = try ToolPolicy.scopedURL(value, grants: grants); return true }) { return bound }
            return try JournalArtifactReference(visiblePath: path)
        }
        artifacts[message.id] = references
        // Derived assistant text remains local history, with no automatic post-restart prompt reuse.
        let text = try JournalVisibleText(message.text, origin: message.role == "user" ? .user : .source, artifacts: references, reply: message.reply)
        pending.append(Pending(run: run, message: message, text: text, replySelection: replySelection))
    }
    /// Future Store transport only: deposit the sealed metadata without resolving
    /// UI delivery, invoking SDKs, or constructing an objective/action here.
    func stageUserMessageForSubmission(_ message: ChatMessage, run: Run, submission: ConversationSubmission,
                                      binding: NativeExactUnsentMessageBinding,
                                      onSaved: @escaping @MainActor (SavedUserMessage) -> Void) throws -> UserMessageStaging {
        try Task.checkCancellation()
        let bytes = Data(message.text.utf8), milliseconds = message.date.timeIntervalSince1970 * 1000
        guard acceptingUserMessages, !userMessageIssuerClosed, !stoppedUserMessageRuns.contains(run.taskID),
              message.role == "user", message.artifacts.isEmpty, message.reply == nil, submission.isPending,
              submission.messageID == message.id, Data(submission.text.utf8) == bytes,
              binding.messageID == message.id, binding.runID == run.taskID, binding.attemptID == run.attemptID,
              binding.logicalTaskID == run.relation.logicalTaskID, binding.exactRequestUTF8 == bytes,
              binding.originRevision >= 0, binding.literalUTF8.count <= 4096,
              String(data: binding.literalUTF8, encoding: .utf8) != nil,
              milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max),
              userMessages[message.id] == nil, !pending.contains(where: { $0.message.id == message.id }) else {
            throw UserMessageReceiptFailure.invalidBinding
        }
        let text = try JournalVisibleText(message.text, origin: .user)
        let staging = UserMessageStaging(issuer: self, submission: submission, epoch: userMessageEpoch,
            identity: UserMessageIdentity(binding), createdAtMilliseconds: Int64(milliseconds))
        userMessages[message.id] = staging
        artifacts[message.id] = []
        pending.append(Pending(run: run, message: message, text: text,
            userMessage: UserMessageDelivery(staging: staging, deposit: onSaved)))
        return staging
    }
    private func validateUserMessage(_ staging: UserMessageStaging, submission: ConversationSubmission,
                                     run: Run, binding: NativeExactUnsentMessageBinding) throws {
        try Task.checkCancellation()
        guard acceptingUserMessages, !userMessageIssuerClosed, staging.issuer === self,
              staging.epoch == userMessageEpoch, !staging.revoked,
              userMessages[staging.identity.messageID] === staging, staging.submission === submission,
              submission.status == .pending || submission.status == .saved,
              !stoppedUserMessageRuns.contains(run.taskID),
              binding.runID == run.taskID, binding.attemptID == run.attemptID,
              binding.logicalTaskID == run.relation.logicalTaskID, staging.identity == UserMessageIdentity(binding),
              submission.messageID == binding.messageID,
              Data(submission.text.utf8).count == staging.identity.requestByteCount,
              Data(SHA256.hash(data: Data(submission.text.utf8))) == staging.identity.requestDigest else {
            throw UserMessageReceiptFailure.unavailable
        }
    }
    /// Called only through a sealed exact-object binding after the full
    /// validator matched immutable request/literal bytes and actual saved row.
    /// No successful lifetime/source/privacy verdict is cached here.
    private func validateUserMessageMetadata(_ staging: UserMessageStaging, submission: ConversationSubmission,
                                             run: Run) throws {
        try Task.checkCancellation()
        guard acceptingUserMessages, !userMessageIssuerClosed, staging.issuer === self,
              staging.epoch == userMessageEpoch, !staging.revoked,
              userMessages[staging.identity.messageID] === staging, staging.submission === submission,
              submission.status == .pending || submission.status == .saved,
              !stoppedUserMessageRuns.contains(run.taskID),
              staging.identity.runID == run.taskID, staging.identity.attemptID == run.attemptID,
              staging.identity.logicalTaskID == run.relation.logicalTaskID,
              submission.messageID == staging.identity.messageID else {
            throw UserMessageReceiptFailure.unavailable
        }
    }
    /// Denial only. Revoked identities remain spent within this issuer epoch.
    func revokeUserMessage(_ staging: UserMessageStaging) {
        if staging.issuer === self, userMessages[staging.identity.messageID] === staging { staging.revoked = true }
    }
    private func retireUserMessages() {
        userMessageEpoch = UUID(); acceptingUserMessages = false
        for staging in userMessages.values {
            staging.revoked = true; stoppedUserMessageRuns.insert(staging.identity.runID)
        }
        // Clearing storage does not renew a previously retired run. A fresh
        // Run may stage in the new generation; no task/action count cap exists.
        userMessages.removeAll()
    }
    private func deliverUserMessage(_ delivery: UserMessageDelivery, entry: Pending,
                                    appends: [JournalAppend], scope: JournalScope) {
        let staging = delivery.staging, identity = staging.identity
        guard !Task.isCancelled, acceptingUserMessages, !userMessageIssuerClosed, staging.issuer === self,
              staging.epoch == userMessageEpoch, !staging.revoked, !staging.delivered,
              userMessages[entry.message.id] === staging, !stoppedUserMessageRuns.contains(entry.run.taskID),
              let submission = staging.submission, submission.isPending,
              submission.messageID == identity.messageID, Data(submission.text.utf8) == Data(entry.message.text.utf8),
              identity.runID == entry.run.taskID, identity.attemptID == entry.run.attemptID,
              identity.logicalTaskID == entry.run.relation.logicalTaskID, opened?.scope == scope else {
            staging.revoked = true; return
        }
        let matching = appends.filter { $0.record.event.id.bytes == Data(identity.messageID.uuidString.utf8) }
        guard matching.count == 1, let appended = matching.first,
              // An old restored/imported row is never a new receipt. Only this
              // SAME live stage's actual lost-ack repair may return inserted:false.
              appended.inserted || staging.acknowledgmentLost,
              appended.record.scope == scope, appended.record.sequence > 0, appended.record.digest.count == 32,
              appended.record.event.taskID == identity.runID, appended.record.event.attemptID == identity.attemptID,
              appended.record.event.createdAtMilliseconds == staging.createdAtMilliseconds,
              case let .user(text) = appended.record.event.payload, text.origin == .user,
              text.artifacts.isEmpty, text.omissions.isEmpty, text.sourceRequirements.isEmpty,
              Data(text.text.utf8) == Data(entry.message.text.utf8),
              text.text.utf8.count == identity.requestByteCount,
              Data(SHA256.hash(data: Data(text.text.utf8))) == identity.requestDigest else {
            staging.revoked = true; return
        }
        let receipt = SavedUserMessage(staging: staging, record: appended.record)
        staging.delivered = true
        delivery.deposit(receipt)
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
        let appends = try await opened.journal.appendBatch([event], expectedScope: opened.scope)
        self.opened?.records.append(contentsOf: appends.map(\.record))
        started.insert(run.taskID)
    }
    @discardableResult func flush() async throws -> [UUID] {
        if let flushing { return try await flushing.value }
        if pending.isEmpty, opened != nil, !userMessageIssuerClosed { return [] }
        let currentID = UUID(); flushID = currentID
        let task = Task<[UUID], Error> { @MainActor [weak self] in
            guard let self else { return [] }
            let opened = try await self.load(); var saved: [UUID] = []
        while let entry = self.pending.first {
            let message = entry.message
            if let reference = entry.text.reply { try await self.validateReply(reference, selection: entry.replySelection) }
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
            // Only this exact staging's first successful-new transaction
            // can establish lost-ack repair eligibility. A generic/old row
            // must refuse atomically, even with an after-COMMIT fault armed.
            let requiresNewUser = entry.userMessage.map { !$0.staging.acknowledgmentLost } ?? false
            let appends: [JournalAppend]
            do {
                appends = try await opened.journal.appendBatch(batch, expectedScope: opened.scope,
                    requiringNewUserEvent: requiresNewUser ? event.id : nil)
            }
            catch {
                if requiresNewUser, let staging = entry.userMessage?.staging, error as? JournalError == .acknowledgmentLost {
                    staging.acknowledgmentLost = true
                }
                throw error
            }
            self.started.insert(entry.run.taskID)
            self.opened?.records.append(contentsOf: appends.map(\.record))
            for append in appends where (try? self.replyBody(append.record)) != nil {
                self.replySequences[Self.messageID(append.record.event.id)] = append.record.sequence
            }
            guard self.pending.first?.message.id == message.id else { throw JournalError.invalidTransition }
            self.pending.removeFirst(); saved.append(message.id)
            if let delivery = entry.userMessage { self.deliverUserMessage(delivery, entry: entry, appends: appends, scope: opened.scope) }
        }
        return saved
    }
    flushing = task
    do { let saved = try await task.value; if flushID == currentID { flushing = nil }; return saved }
    catch { if flushID == currentID { flushing = nil }; throw error }
}
    func perform<Output>(_ call: ToolCall, proposalID: UUID, run: Run, journalEffect: JournalEffect = .unknown, validate: @escaping @MainActor () throws -> Void,
                         admitAction: (@MainActor @Sendable () async throws -> Void)? = nil,
                         action: @escaping @MainActor () async throws -> Output,
                         result: @escaping @MainActor (Output) -> ToolResult,
                         unsavedResult: @escaping @MainActor (ToolResult) -> Void,
                         journalOutcome: (@MainActor (Output, JournalIntent) -> JournalToolOutcome)? = nil,
                         failureOutcome: (@MainActor (any Error, JournalIntent) -> JournalToolOutcome?)? = nil,
                         metadataFailure: @escaping @MainActor (ToolResult) -> Void = { _ in },
                         settledFileResult: @escaping @MainActor (ToolResult, FileReadSettlement) -> Void = { _,_ in },
                         settledFilenameSearchResult: @escaping @MainActor (ToolResult, FilenameSearchSettlement) -> Void = { _,_ in },
                         settledCalendarReadResult: @escaping @MainActor (ToolResult, CalendarReadSettlement) -> Void = { _,_ in },
                         settledMCPTaskResult: @escaping @MainActor (MCPTaskReceipt, MCPTaskSettlement) -> Void = { _,_ in }) async throws -> Output {
        _ = try await flush(); let opened = try await load(); try await start(run, opened: opened)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let encoded = try encoder.encode(call); guard encoded.count <= 128 * 1024 else { throw JournalError.tooLarge }
        let intent = try JournalIntent(proposalID: proposalID, producerEpoch: opened.journal.producerEpoch, toolCallID: JournalOpaqueID(call.id), toolName: call.name,
            callDigest: Data(SHA256.hash(data: encoded)), effect: (call.name == "read_calendar" || call.name == MainAgentMCPTools.catalogName) ? .readOnly : call.name == MainAgentMCPTools.readName ? .unknown : journalEffect)
        let event = JournalEvent(id: try JournalOpaqueID(UUID().uuidString), taskID: run.taskID, attemptID: run.attemptID, createdAtMilliseconds: Self.nowMilliseconds, payload: .intent(intent))
        let checkpoint = checkpoints[run.taskID] ?? JournalDispatchCheckpoint(journal: opened.journal)
        checkpoints[run.taskID] = checkpoint
        var output: Output?, observedOutput: ToolResult?, actionError: (any Error)?, serializationError: (any Error)?
        let savedResult: JournalRecord
        do {
        savedResult = try await checkpoint.execute(event, expectedScope: opened.scope, validate: validate, admitAction: admitAction, action: {
            let value: Output
            do { value = try await action() }
            catch {
                actionError = error
                if call.name == "read_calendar" || MainAgentMCPTools.names.contains(call.name) { return JournalToolOutcome(intent: intent, kind: .effectUncertain) }
                return failureOutcome?(error, intent) ?? JournalToolOutcome(intent: intent, kind: .effectUncertain)
            }
            output = value
            let observed = result(value)
            observedOutput = observed
            // Remote calls remain unknown effects. Never persist a claimed output
            // link or private source body through a custom/forged result.
            if call.name == MainAgentMCPTools.readName {
                return JournalToolOutcome(intent: intent, kind: .returnedUnverified)
            }
            if call.name == "read_calendar" || call.name == MainAgentMCPTools.catalogName {
                return JournalToolOutcome(intent: intent, kind: observed.verified ? .returnedVerified : .returnedUnverified)
            }
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
                if let observed = observedOutput, let receipt = observed.mcpTaskReceipt,
                   receipt.matches(call: call, result: observed, run: run, proposalID: proposalID) {
                    pendingMCPTaskResults[intent.invocationID] = .init(receipt: receipt, run: run, intent: intent,
                        epoch: mcpTaskEpoch, scope: opened.scope, settled: settledMCPTaskResult)
                }
                if let output {
                    let raw = result(output)
                    let observed = call.name == "read_calendar" ? Self.calendarFact(raw) : MainAgentMCPTools.names.contains(call.name) ? MainAgentMCPTools.fact(raw) : raw
                    if serializationError != nil {
                        metadataFailure(ToolResult(summary: observed.summary, evidence: observed.evidence + " Output link metadata could not be retained; its checkpoint also remains unsaved.", verified: observed.verified))
                    } else { unsavedResult(observed) }
                }
            }
            throw error
        }
        if let serializationError {
            if let output {
                let raw = result(output)
                let observed = call.name == "read_calendar" ? Self.calendarFact(raw) : MainAgentMCPTools.names.contains(call.name) ? MainAgentMCPTools.fact(raw) : raw
                metadataFailure(ToolResult(summary: observed.summary, evidence: observed.evidence + " Output link metadata could not be retained.", verified: observed.verified))
            }
            throw serializationError
        }
        if let actionError { throw actionError }
        guard let output else { throw JournalError.invalidEvent }
        if let observed = observedOutput,
           let settlement = FileReadSettlement(call: call, result: observed, run: run, intent: intent, record: savedResult) {
            settledFileResult(observed, settlement)
        }
        if let observed = observedOutput,
           let settlement = FilenameSearchSettlement(call: call, result: observed, run: run, intent: intent, record: savedResult) {
            settledFilenameSearchResult(observed, settlement)
        }
        if let observed = observedOutput,
           let settlement = CalendarReadSettlement(call: call, result: observed, run: run, intent: intent, record: savedResult) {
            settledCalendarReadResult(observed, settlement)
        }
        if let observed = observedOutput, let receipt = observed.mcpTaskReceipt,
           receipt.matches(call: call, result: observed, run: run, proposalID: proposalID),
           let settlement = MCPTaskSettlement(issuer: self, epoch: mcpTaskEpoch, receipt: receipt, run: run,
                intent: intent, record: savedResult, expectedScope: opened.scope) {
            settledMCPTaskResult(receipt, settlement)
        }
        self.opened?.records.append(savedResult)
        return output
    }
    func prepare(_ run: Run) async throws {
        _ = try await flush(); let opened = try await load(); try await start(run, opened: opened)
    }
    func journalForTesting() async throws -> ConversationJournal { try await load().journal }
    /// Separate finite direct phases. Action sees the actual durable intent only
    /// inside Core's inserted post-admission lexical action. No ToolResult/body
    /// mapper or caller-created saved record can produce this settlement.
    func performNativeTextEffect(_ call: ToolCall, proposalID: UUID,
        phase: NativeControlSession.ExactUnsentEffect.Phase, run: Run,
        validate: @escaping @MainActor () throws -> Void,
        admitAction: (@MainActor @Sendable () async throws -> Void)? = nil,
        action: @escaping @MainActor (JournalIntent) async throws -> NativeControlSession.ExactUnsentEffect,
        unsavedEffect: @escaping @MainActor (NativeControlSession.ExactUnsentEffect) -> Void,
        settledEffect: @escaping @MainActor (NativeControlSession.ExactUnsentEffect, NativeTextEffectSettlement) -> Void
    ) async throws -> (effect: NativeControlSession.ExactUnsentEffect, settlement: NativeTextEffectSettlement) {
        let expectedName = phase == .focus ? "native_exact_unsent_focus" : "native_exact_unsent_insert"
        guard call.name == expectedName else { throw JournalError.invalidEvent }
        _ = try await flush(); let opened = try await load(); try await start(run, opened: opened)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(call)
        guard encoded.count <= 128 * 1024 else { throw JournalError.tooLarge }
        let intent = try JournalIntent(proposalID: proposalID, producerEpoch: opened.journal.producerEpoch,
            toolCallID: JournalOpaqueID(call.id), toolName: call.name,
            callDigest: Data(SHA256.hash(data: encoded)), effect: .mutation)
        let event = JournalEvent(id: try JournalOpaqueID(UUID().uuidString), taskID: run.taskID,
            attemptID: run.attemptID, createdAtMilliseconds: Self.nowMilliseconds, payload: .intent(intent))
        let checkpoint = checkpoints[run.taskID] ?? JournalDispatchCheckpoint(journal: opened.journal)
        checkpoints[run.taskID] = checkpoint
        let epoch = nativeTextEffectEpoch
        var observed: NativeControlSession.ExactUnsentEffect?, actionError: (any Error)?
        let saved: JournalRecord
        do {
            saved = try await checkpoint.execute(event, expectedScope: opened.scope, validate: validate,
                admitAction: admitAction, action: {
                    do {
                        let effect = try await action(intent)
                        observed = effect
                        guard effect.phase == phase, effect.runID == run.taskID, effect.attemptID == run.attemptID,
                              effect.logicalTaskID == run.relation.logicalTaskID, effect.proposalID == proposalID,
                              effect.callDigest == intent.callDigest, effect.invocationID == intent.invocationID else {
                            actionError = JournalError.invalidEvent
                            return JournalToolOutcome(intent: intent, kind: .effectUncertain)
                        }
                        return JournalToolOutcome(intent: intent, kind: effect.journalKind)
                    } catch {
                        actionError = error
                        return JournalToolOutcome(intent: intent, kind: .effectUncertain)
                    }
                })
        } catch {
            if checkpoint.pendingResultCount > 0 {
                pendingResultSaves[intent.invocationID] = checkpoint
                if let observed {
                    pendingNativeTextEffects[intent.invocationID] = .init(effect: observed, run: run,
                        intent: intent, epoch: epoch, settled: settledEffect)
                    unsavedEffect(observed)
                }
            }
            throw error
        }
        if let actionError { throw actionError }
        guard let observed, let settlement = NativeTextEffectSettlement(issuer: self, epoch: epoch,
            effect: observed, run: run, intent: intent, record: saved) else { throw JournalError.invalidEvent }
        settledEffect(observed, settlement)
        return (observed, settlement)
    }
    func retryResultSaves() async throws {
        guard !pendingResultSaves.isEmpty || !pendingFinishes.isEmpty else { return }
        // No action closures, proposal reminting or side-effect retries are accepted here.
        for (invocationID, checkpoint) in pendingResultSaves {
            let record = try await checkpoint.savePendingResult(invocationID: invocationID)
            pendingResultSaves.removeValue(forKey: invocationID)
            if let pending = pendingMCPTaskResults.removeValue(forKey: invocationID) {
                guard let token = MCPTaskSettlement(issuer: self, epoch: pending.epoch, receipt: pending.receipt,
                    run: pending.run, intent: pending.intent, record: record, expectedScope: pending.scope) else { throw JournalError.invalidEvent }
                pending.settled(pending.receipt, token)
            }
            if let pending = pendingNativeTextEffects.removeValue(forKey: invocationID) {
                guard let token = NativeTextEffectSettlement(issuer: self, epoch: pending.epoch,
                    effect: pending.effect, run: pending.run, intent: pending.intent, record: record) else { throw JournalError.invalidEvent }
                pending.settled(pending.effect, token)
            }
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
        let append = try await opened.journal.finishTask(event, expectedScope: opened.scope)
        self.opened?.records.append(append.record)
        checkpoints.removeValue(forKey: run.taskID); started.remove(run.taskID); pendingFinishes.removeValue(forKey: run.taskID)
    }
    func stop(_ run: Run?) {
        replyEpoch = UUID()
        if let run {
            stoppedUserMessageRuns.insert(run.taskID)
            for staging in userMessages.values where staging.identity.runID == run.taskID { staging.revoked = true }
            checkpoints[run.taskID]?.stop()
        }
    }
    func validateArtifactForContentAccess(messageID: UUID, path: String, grants: [ScopeGrant]) throws {
        let references = artifacts[messageID]?.filter { Data($0.visiblePath.utf8) == Data(path.utf8) } ?? []
        guard references.count == 1 else { throw JournalError.unsafeLocation }
        try JournalArtifactAccess.validate(references[0], isAuthorized: { value in _ = try ToolPolicy.scopedURL(value, grants: grants); return true })
    }
    func close() async throws {
        replyEpoch = UUID(); replySequences.removeAll()
        conversationCursors.removeAll(); conversationCursorOrder.removeAll()
        nativeTextEffectEpoch = UUID(); mcpTaskEpoch = UUID()
        userMessageIssuerClosed = true; retireUserMessages()
        if let flushing { _ = try await flushing.value }
        if let opening { _ = try await opening.value }
        if let opened { try await opened.journal.close() }
        opened = nil; opening = nil
    }
    func clear() async throws {
        replyEpoch = UUID(); replySequences.removeAll()
        conversationCursors.removeAll(); conversationCursorOrder.removeAll()
        nativeTextEffectEpoch = UUID(); mcpTaskEpoch = UUID()
        retireUserMessages()
        let receiptEpoch = userMessageEpoch
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
        installedSummaries.removeAll()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("summaries.json"))
        pending.removeAll(); pendingResultSaves.removeAll(); pendingNativeTextEffects.removeAll(); pendingMCPTaskResults.removeAll(); pendingFinishes.removeAll(); checkpoints.removeAll(); started.removeAll(); startEvents.removeAll(); finishEvents.removeAll(); artifacts.removeAll()
        opening = nil; flushing = nil; flushID = nil
        if userMessageEpoch == receiptEpoch, !userMessageIssuerClosed { acceptingUserMessages = true }
    }

    func compactionBoundary(keepingRecentTasks: Int = 5) -> Int64? {
        guard let opened, !opened.records.isEmpty else { return nil }
        var taskBounds: [UUID: (first: Int64, last: Int64, finished: Int64?)] = [:]
        for r in opened.records {
            let id = r.event.taskID
            var bound = taskBounds[id] ?? (first: r.sequence, last: r.sequence, finished: nil)
            bound.first = min(bound.first, r.sequence)
            bound.last = max(bound.last, r.sequence)
            if case .finished = r.event.payload {
                bound.finished = r.sequence
            }
            taskBounds[id] = bound
        }
        let allTasks = Array(taskBounds.values)
        let unfinished = allTasks.filter { $0.finished == nil }
        let finishedTasks = allTasks.filter { $0.finished != nil }
        guard !finishedTasks.isEmpty else { return nil }

        var protectedFirstSequences: [Int64] = unfinished.map(\.first)
        let sortedByLast = finishedTasks.sorted { $0.last > $1.last }
        let recentWindow = Array(sortedByLast.prefix(max(0, keepingRecentTasks)))
        protectedFirstSequences.append(contentsOf: recentWindow.map(\.first))

        let minProtected = protectedFirstSequences.min() ?? Int64.max
        let candidates = finishedTasks.compactMap { $0.finished }.filter { $0 < minProtected }
        guard let maxCandidate = candidates.max(), maxCandidate > 0 else { return nil }

        let incompleteBefore = allTasks.contains { t in
            t.first <= maxCandidate && (t.finished == nil || t.finished! > maxCandidate)
        }
        guard !incompleteBefore else { return nil }
        return maxCandidate
    }

    func recordsForCompaction(after: Int64, through: Int64, limit: Int = 500) -> [JournalRecord] {
        guard let opened else { return [] }
        let filtered = opened.records.filter { $0.sequence > after && $0.sequence <= through }
        return Array(filtered.prefix(max(0, limit)))
    }

    func isPrefixComplete(through: Int64) -> Bool {
        guard let opened else { return false }
        var taskBounds: [UUID: (first: Int64, finished: Int64?)] = [:]
        for r in opened.records {
            let id = r.event.taskID
            var b = taskBounds[id] ?? (first: r.sequence, finished: nil)
            b.first = min(b.first, r.sequence)
            if case .finished = r.event.payload {
                b.finished = r.sequence
            }
            taskBounds[id] = b
        }
        for (_, b) in taskBounds {
            if b.first <= through {
                guard let fin = b.finished, fin <= through else { return false }
            }
        }
        return true
    }

    func installSummary(
        generation: UUID,
        fromSequence: Int64,
        throughSequence: Int64,
        text: String,
        expectedFromSequence: Int64? = nil,
        expectedThroughDigest: Data? = nil
    ) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= ConversationCompactor.maximumSummaryBytes else {
            throw ConversationCompactor.Failure.invalidSummary
        }
        let current = try await load()
        try Task.checkCancellation()
        guard current.scope.generation == generation else {
            throw ConversationCompactor.Failure.staleGeneration
        }
        let maxSeq = current.records.last?.sequence ?? 0
        if let expectedThroughDigest {
            guard current.records.first(where: { $0.sequence == throughSequence })?.digest == expectedThroughDigest else {
                throw ConversationCompactor.Failure.staleSummary
            }
        }
        guard throughSequence > 0, throughSequence <= maxSeq else {
            throw ConversationCompactor.Failure.staleSummary
        }
        if let previous = latestSummary {
            if throughSequence == previous.throughSequence, text == previous.text,
               expectedFromSequence == nil || expectedFromSequence == previous.fromSequence {
                return
            }
            guard throughSequence > previous.throughSequence else {
                throw ConversationCompactor.Failure.staleSummary
            }
        }
        let from = latestSummary.map { $0.throughSequence + 1 } ?? 1
        if let expectedFromSequence, expectedFromSequence != from {
            throw ConversationCompactor.Failure.staleSummary
        }
        guard isPrefixComplete(through: throughSequence) else {
            throw ConversationCompactor.Failure.incompletePrefix
        }
        let summary = ConversationSummary(
            scope: current.scope,
            fromSequence: from,
            throughSequence: throughSequence,
            text: text
        )
        installedSummaries.append(summary)
        let summaryURL = directory.appendingPathComponent("summaries.json")
        if let data = try? JSONEncoder().encode(installedSummaries) {
            try? FileManager.default.createDirectory(
                at: summaryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? LocalPrivateFileWriter.write(data: data, to: summaryURL, maximumBytes: LocalPrivateFileWriter.maximumSupportedBytes)
        }
    }
}
