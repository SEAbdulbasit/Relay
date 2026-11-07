import Foundation

public actor ConversationJournal {
    public nonisolated let producerEpoch = UUID()
    private var database: JournalSQLite?
    private var files: JournalFiles?
    private let limits: JournalLimits
    private var nextFault: JournalFault?
    #if DEBUG
    private var nextIntentFault: JournalFault?
    func injectIntentFault(_ fault: JournalFault) { nextIntentFault = fault }
    private var nextBoundaryHook: (JournalTestBoundary, @Sendable () -> Void)?
    func atNextBoundary(_ boundary: JournalTestBoundary, _ hook: @escaping @Sendable () -> Void) { nextBoundaryHook = (boundary, hook) }
    #endif

    @concurrent public static func open(directory: URL, initialization: JournalInitialization = .ready, limits: JournalLimits = .init()) async throws -> ConversationJournal {
        try ConversationJournal(directory: directory, initialization: initialization, limits: limits)
    }
    private init(directory: URL, initialization: JournalInitialization, limits: JournalLimits) throws {
        guard (65_536...128 * 1024 * 1024).contains(limits.databaseBytes), (4096...16 * 1024 * 1024).contains(limits.walThresholdBytes),
              (0...1000).contains(limits.busyMilliseconds) else { throw JournalError.invalidEvent }
        self.limits = limits
        let files = try JournalFiles(root: directory)
        let isNew = try files.prepareNewOrValidate { path in
            let snapshot = try JournalSQLite(path: path, busyMilliseconds: limits.busyMilliseconds)
            defer { try? snapshot.close() }
            try snapshot.execute("PRAGMA query_only=ON")
            try Self.validateSchema(snapshot)
        }
        let database = try JournalSQLite(path: files.path, busyMilliseconds: limits.busyMilliseconds)
        do {
            if isNew { try Self.initialize(database, initialization: initialization) }
            else { try Self.validateSchema(database) }
            try Self.configure(database, limits: limits)
            try files.validateLiveFiles()
            if case let .importing(manifest) = initialization {
                let row = try database.query("SELECT readiness, legacy_consumed, legacy_digest, legacy_expected_records, legacy_events_digest FROM journal_state").first!
                guard row[0].integer == 0, row[1].integer == 0, row[2].data == manifest.digest, row[3].integer == Int64(manifest.expectedEvents), row[4].data == manifest.eventsDigest else { throw JournalError.conflictingID }
            }
        } catch { try? database.close(); throw error }
        self.database = database; self.files = files
    }
    private static func initialize(_ database: JournalSQLite, initialization: JournalInitialization) throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            guard try database.integer("SELECT COUNT(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'") == 0 else { throw JournalError.corrupt }
            for statement in JournalSchema.statements { try database.execute(statement) }
            let digest: SQLValue, count: SQLValue, eventDigest: SQLValue, ready: Int64
            switch initialization {
            case .ready: digest = .null; count = .null; eventDigest = .null; ready = 1
            case let .importing(manifest): digest = .blob(manifest.digest); count = .integer(Int64(manifest.expectedEvents)); eventDigest = .blob(manifest.eventsDigest); ready = 0
            }
            try database.execute("INSERT INTO journal_state VALUES(1, 'relay-conversation-journal', 1, ?, ?, ?, 0, ?, ?, ?)",
                [.blob(uuidBytes(UUID())), .blob(uuidBytes(UUID())), .integer(ready), digest, count, eventDigest])
            try database.execute("PRAGMA application_id=\(JournalSchema.applicationID)")
            try database.execute("PRAGMA user_version=\(JournalSchema.version)")
            try database.execute("COMMIT")
        } catch { try? database.execute("ROLLBACK"); throw error }
    }
    private static func validateSchema(_ database: JournalSQLite) throws {
        try database.withBudget(honorCancellation: true) {
            guard try database.integer("PRAGMA user_version") == JournalSchema.version else { throw JournalError.unsupportedSchema }
            guard try database.integer("PRAGMA application_id") == JournalSchema.applicationID else { throw JournalError.corrupt }
            let actual = try database.query("SELECT name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY name", maximumRows: 32)
            let expected = Dictionary(uniqueKeysWithValues: JournalSchema.statements.map { statement in
                let tokens = statement.split(whereSeparator: \.isWhitespace)
                return (String(tokens[tokens[1] == "UNIQUE" ? 3 : 2]), JournalSchema.normalized(statement))
            })
            guard actual.count == expected.count else { throw JournalError.corrupt }
            for row in actual {
                guard let name = row[0].string, let sql = row[1].string, expected[name] == JournalSchema.normalized(sql) else { throw JournalError.corrupt }
            }
            let state = try database.query("SELECT identity, format_version, store_id, generation, readiness, legacy_consumed, legacy_digest FROM journal_state", maximumRows: 2)
            guard state.count == 1, state[0][0].string == "relay-conversation-journal", state[0][1].integer == 1,
                  state[0][2].data?.count == 16, state[0][3].data?.count == 16, [0,1].contains(state[0][4].integer), [0,1].contains(state[0][5].integer),
                  try database.text("PRAGMA quick_check(1)") == "ok", try database.query("PRAGMA foreign_key_check", maximumRows: 1).isEmpty else { throw JournalError.corrupt }
        }
    }
    private static func configure(_ database: JournalSQLite, limits: JournalLimits) throws {
        guard try database.text("PRAGMA journal_mode=WAL").lowercased() == "wal" else { throw JournalError.corrupt }
        for statement in ["PRAGMA synchronous=FULL", "PRAGMA fullfsync=ON", "PRAGMA foreign_keys=ON", "PRAGMA trusted_schema=OFF", "PRAGMA wal_autocheckpoint=1000", "PRAGMA journal_size_limit=\(limits.walThresholdBytes)"] { try database.execute(statement) }
        guard try database.integer("PRAGMA synchronous") == 2, try database.integer("PRAGMA fullfsync") == 1,
              try database.integer("PRAGMA foreign_keys") == 1, try database.integer("PRAGMA trusted_schema") == 0 else { throw JournalError.corrupt }
        let pageSize = try database.integer("PRAGMA page_size")
        guard pageSize > 0, pageSize <= 65_536 else { throw JournalError.corrupt }
        let pages = Int64(limits.databaseBytes) / pageSize
        guard try database.integer("PRAGMA page_count") <= pages, try database.integer("PRAGMA max_page_count=\(pages)") == pages else { throw JournalError.tooLarge }
    }
    public func scope() throws -> JournalScope {
        let row = try db().query("SELECT store_id, generation FROM journal_state").first!
        guard let store = row[0].data, let generation = row[1].data else { throw JournalError.corrupt }
        return try JournalScope(storeID: uuidFromBytes(store), generation: uuidFromBytes(generation))
    }
    public func isReady() throws -> Bool { try db().integer("SELECT readiness FROM journal_state") == 1 }
    private func db() throws -> JournalSQLite { guard let database else { throw JournalError.closed }; return database }
    private func check(_ expected: JournalScope, requireReady: Bool = true) throws {
        guard try scope() == expected else { throw JournalError.wrongGeneration }
        if requireReady, try !isReady() { throw JournalError.notReady }
    }
    func injectFault(_ fault: JournalFault) { nextFault = fault }
    private func transaction<T>(scope expected: JournalScope, requireReady: Bool = true, honorCancellation: Bool = true, _ operation: (JournalSQLite) throws -> T) throws -> T {
        let database = try db()
        if honorCancellation, Task.isCancelled { throw JournalError.cancelled }
        try files?.validateLiveFiles()
        if let files, try files.walBytes() >= limits.walThresholdBytes {
            _ = try database.query("PRAGMA wal_checkpoint(PASSIVE)")
            // A complete checkpoint permits WAL reuse even when the allocated file remains large.
            let status = try database.query("PRAGMA wal_checkpoint(PASSIVE)").first!
            guard status[0].integer == 0, status[1].integer == status[2].integer else { throw JournalError.tooLarge }
        }
        let fault = nextFault; nextFault = nil
        #if DEBUG
        let boundaryHook = nextBoundaryHook; nextBoundaryHook = nil
        #endif
        return try database.withBudget(honorCancellation: honorCancellation) {
            try database.execute("BEGIN IMMEDIATE")
            var committed = false
            do {
                try check(expected, requireReady: requireReady)
                let result = try operation(database)
                #if DEBUG
                if case .beforeCommit? = boundaryHook?.0 { boundaryHook?.1() }
                #endif
                if honorCancellation, Task.isCancelled { throw JournalError.cancelled }
                if case .beforeCommit? = fault { throw JournalError.injectedBeforeCommit }
                try database.execute("COMMIT"); committed = true
                #if DEBUG
                if case .afterCommit? = boundaryHook?.0 { boundaryHook?.1() }
                #endif
                try files?.validateLiveFiles()
                if case .afterCommit? = fault { throw JournalError.acknowledgmentLost }
                return result
            } catch { if !committed { try? database.execute("ROLLBACK") }; throw error }
        }
    }
    private func validate(_ event: JournalEvent) throws {
        func text(_ value: JournalVisibleText) throws {
            guard value.text.utf8.count <= 240 * 1024, value.omissions.count <= 16, value.sourceRequirements.count <= 32,
                  value.sourceRequirements.allSatisfy({ $0.revision.count == 32 }), value.artifacts.count <= 32 else { throw JournalError.tooLarge }
            for artifact in value.artifacts { _ = try JournalArtifactReference(visiblePath: artifact.visiblePath, canonicalPath: artifact.canonicalPath, identityDigest: artifact.identityDigest) }
        }
        switch event.payload {
        case let .started(_, relation):
            if let relation {
                _ = try JournalRunRelation(logicalTaskID: relation.logicalTaskID, predecessorRunID: relation.predecessorRunID, cause: relation.cause)
                guard relation.predecessorRunID != event.taskID else { throw JournalError.invalidEvent }
            }
        case let .user(value), let .assistant(value), let .question(value), let .answer(value): try text(value)
        case let .intent(value):
            _ = try JournalIntent(invocationID: value.invocationID, proposalID: value.proposalID, producerEpoch: value.producerEpoch, toolCallID: value.toolCallID, toolName: value.toolName, callDigest: value.callDigest, effect: value.effect)
        case let .result(value):
            guard value.callDigest.count == 32, value.artifacts.count <= 32 else { throw JournalError.invalidEvent }
            for artifact in value.artifacts { _ = try JournalArtifactReference(visiblePath: artifact.visiblePath, canonicalPath: artifact.canonicalPath, identityDigest: artifact.identityDigest) }
            if let evidence = value.evidence { try text(evidence) }
        default: break
        }
    }
    private func record(_ row: [SQLValue], expected: JournalScope) throws -> JournalRecord {
        guard row.count == 8, let sequence = row[0].integer, sequence > 0, let bytes = row[1].data, bytes.count <= 262_144,
              let digest = row[2].data, digest.count == 32, journalDigest(bytes) == digest, row[3].data == uuidBytes(expected.generation) else { throw JournalError.corrupt }
        try validateJournalJSON(bytes)
        let event: JournalEvent
        do { event = try JSONDecoder().decode(JournalEvent.self, from: bytes) } catch { throw JournalError.corrupt }
        try validate(event)
        guard try journalEncoded(event) == bytes, row[4].data == event.id.bytes, row[5].data == uuidBytes(event.taskID),
              row[6] == event.attemptID.map({ .blob(uuidBytes($0)) }) ?? .null, row[7].integer == event.payload.kind else { throw JournalError.corrupt }
        try validateRelationships(event, sequence: sequence, expected: expected)
        return JournalRecord(scope: expected, sequence: sequence, event: event, digest: digest)
    }
    private func validateRelationships(_ event: JournalEvent, sequence: Int64, expected: JournalScope) throws {
        let database = try db()
        guard let task = try database.query("SELECT generation,attempt_id,producer_epoch,started_sequence,finished_sequence,terminal_kind FROM tasks WHERE task_id=?", [.blob(uuidBytes(event.taskID))]).first,
              task[0].data == uuidBytes(expected.generation), task[1] == event.attemptID.map({ .blob(uuidBytes($0)) }) ?? .null else { throw JournalError.corrupt }
        switch event.payload {
        case let .started(epoch, _): guard task[2].data == uuidBytes(epoch), task[3].integer == sequence else { throw JournalError.corrupt }
        case let .finished(outcome): guard task[4].integer == sequence, task[5].integer == Int64(outcome.rawValue) else { throw JournalError.corrupt }
        case let .intent(intent):
            guard let value = try database.query("SELECT invocation_id,generation,task_id,attempt_id,producer_epoch,tool_call_id,tool_name,call_sha256,effect_class,proposal_id FROM intents WHERE intent_sequence=?", [.integer(sequence)]).first,
                  value[0].data == uuidBytes(intent.invocationID), value[1] == task[0], value[2].data == uuidBytes(event.taskID), value[3] == task[1], value[4].data == uuidBytes(intent.producerEpoch),
                  value[5].data == intent.toolCallID.bytes, value[6].string == intent.toolName, value[7].data == intent.callDigest, value[8].integer == Int64(intent.effect.rawValue), value[9].data == uuidBytes(intent.proposalID) else { throw JournalError.corrupt }
        case let .result(outcome):
            guard let value = try database.query("SELECT invocation_id,task_id,attempt_id,call_sha256,outcome_kind,intent_sequence FROM intents WHERE result_sequence=?", [.integer(sequence)]).first,
                  value[0].data == uuidBytes(outcome.invocationID), value[1].data == uuidBytes(event.taskID), value[2] == task[1], value[3].data == outcome.callDigest, value[4].integer == Int64(outcome.kind.rawValue),
                  let intentSequence = value[5].integer, intentSequence < sequence,
                  let intentRow = try database.query("SELECT \(Self.columns) FROM events WHERE sequence=?", [.integer(intentSequence)]).first else { throw JournalError.corrupt }
            let original = try record(intentRow, expected: expected)
            guard case .intent = original.event.payload else { throw JournalError.corrupt }
        default: break
        }
    }
    private static let columns = "sequence, payload, payload_sha256, generation, event_id, task_id, attempt_id, kind"
    private func insert(_ event: JournalEvent, bytes: Data, expected: JournalScope, legacy: Bool = false, recovery: Bool = false) throws -> JournalAppend {
        let database = try db(); try validate(event)
        if let row = try database.query("SELECT \(Self.columns) FROM events WHERE generation=? AND event_id=?", [.blob(uuidBytes(expected.generation)), .blob(event.id.bytes)]).first {
            let existing = try record(row, expected: expected)
            guard try journalEncoded(existing.event) == bytes else { throw JournalError.conflictingID }
            return JournalAppend(record: existing, inserted: false)
        }
        if case let .intent(intent) = event.payload, let attemptID = event.attemptID,
           let existing = try database.query("SELECT intent_sequence,call_sha256,tool_name,effect_class FROM intents WHERE task_id=? AND attempt_id=? AND proposal_id=? AND tool_call_id=?",
                [.blob(uuidBytes(event.taskID)), .blob(uuidBytes(attemptID)), .blob(uuidBytes(intent.proposalID)), .blob(intent.toolCallID.bytes)]).first {
            guard existing[1].data == intent.callDigest, existing[2].string == intent.toolName,
                  existing[3].integer == Int64(intent.effect.rawValue), let sequence = existing[0].integer,
                  let row = try database.query("SELECT \(Self.columns) FROM events WHERE sequence=?", [.integer(sequence)]).first else { throw JournalError.conflictingID }
            return JournalAppend(record: try record(row, expected: expected), inserted: false)
        }
        var task = try database.query("SELECT attempt_id, producer_epoch, finished_sequence FROM tasks WHERE task_id=?", [.blob(uuidBytes(event.taskID))]).first
        if task == nil {
            if case let .started(epoch, relation) = event.payload {
                if let relation {
                    _ = try JournalRunRelation(logicalTaskID: relation.logicalTaskID, predecessorRunID: relation.predecessorRunID, cause: relation.cause)
                    guard relation.predecessorRunID != event.taskID else { throw JournalError.invalidTransition }
                    if let predecessor = relation.predecessorRunID {
                        guard let prior = try database.query("SELECT \(Self.columns) FROM events WHERE sequence=(SELECT started_sequence FROM tasks WHERE task_id=?)", [.blob(uuidBytes(predecessor))]).first else { throw JournalError.invalidTransition }
                        let previous = try record(prior, expected: expected)
                        guard case let .started(_, previousRelation) = previous.event.payload, previousRelation?.logicalTaskID == relation.logicalTaskID else { throw JournalError.invalidTransition }
                    }
                }
                guard !legacy, event.attemptID != nil, epoch == producerEpoch else { throw JournalError.invalidTransition }
                try database.execute("INSERT INTO tasks(task_id,generation,attempt_id,producer_epoch) VALUES(?,?,?,?)", [.blob(uuidBytes(event.taskID)), .blob(uuidBytes(expected.generation)), .blob(uuidBytes(event.attemptID!)), .blob(uuidBytes(epoch))])
            } else if legacy {
                try database.execute("INSERT INTO tasks(task_id,generation) VALUES(?,?)", [.blob(uuidBytes(event.taskID)), .blob(uuidBytes(expected.generation))])
            } else { throw JournalError.invalidTransition }
            task = try database.query("SELECT attempt_id, producer_epoch, finished_sequence FROM tasks WHERE task_id=?", [.blob(uuidBytes(event.taskID))]).first
        } else if case .started = event.payload { throw JournalError.invalidTransition }
        guard let task, task[0] == event.attemptID.map({ .blob(uuidBytes($0)) }) ?? .null else { throw JournalError.invalidTransition }
        let terminal = task[2] != .null
        if terminal { guard case .result = event.payload else { throw JournalError.invalidTransition } }
        switch event.payload {
        case let .intent(intent):
            guard !legacy, !terminal, intent.producerEpoch == producerEpoch, task[1].data == uuidBytes(producerEpoch), bytes.count <= 8192 else { throw JournalError.invalidTransition }
        case let .result(result):
            let row = try database.query("SELECT task_id,attempt_id,producer_epoch,call_sha256,result_sequence FROM intents WHERE invocation_id=?", [.blob(uuidBytes(result.invocationID))]).first
            guard let row, row[0].data == uuidBytes(event.taskID), row[1] == task[0], row[2].data == uuidBytes(producerEpoch), row[3].data == result.callDigest, row[4] == .null else { throw JournalError.invalidTransition }
        case let .finished(outcome):
            guard !terminal, legacy || recovery || task[1].data == uuidBytes(producerEpoch) else { throw JournalError.invalidTransition }
            if outcome == .success {
                guard try database.integer("SELECT COUNT(*) FROM intents WHERE task_id=? AND (result_sequence IS NULL OR outcome_kind IN (2,4))", [.blob(uuidBytes(event.taskID))]) == 0 else { throw JournalError.invalidTransition }
            }
        default:
            guard legacy || task[1].data == uuidBytes(producerEpoch) else { throw JournalError.invalidTransition }
        }
        let digest = journalDigest(bytes)
        try database.execute("INSERT INTO events(generation,event_id,task_id,attempt_id,kind,created_at_ms,payload,payload_sha256) VALUES(?,?,?,?,?,?,?,?)",
            [.blob(uuidBytes(expected.generation)), .blob(event.id.bytes), .blob(uuidBytes(event.taskID)), event.attemptID.map { .blob(uuidBytes($0)) } ?? .null,
             .integer(event.payload.kind), event.createdAtMilliseconds.map(SQLValue.integer) ?? .null, .blob(bytes), .blob(digest)])
        let sequence = database.lastSequence
        switch event.payload {
        case .started: try database.execute("UPDATE tasks SET started_sequence=? WHERE task_id=?", [.integer(sequence), .blob(uuidBytes(event.taskID))])
        case let .intent(intent):
            try database.execute("INSERT INTO intents(invocation_id,proposal_id,generation,task_id,attempt_id,producer_epoch,intent_sequence,tool_call_id,tool_name,call_sha256,effect_class) VALUES(?,?,?,?,?,?,?,?,?,?,?)", [.blob(uuidBytes(intent.invocationID)), .blob(uuidBytes(intent.proposalID)), .blob(uuidBytes(expected.generation)), .blob(uuidBytes(event.taskID)), .blob(uuidBytes(event.attemptID!)), .blob(uuidBytes(producerEpoch)), .integer(sequence), .blob(intent.toolCallID.bytes), .text(intent.toolName), .blob(intent.callDigest), .integer(Int64(intent.effect.rawValue))])
        case let .result(result): try database.execute("UPDATE intents SET result_sequence=?,outcome_kind=? WHERE invocation_id=?", [.integer(sequence), .integer(Int64(result.kind.rawValue)), .blob(uuidBytes(result.invocationID))])
        case let .finished(outcome): try database.execute("UPDATE tasks SET finished_sequence=?,terminal_kind=? WHERE task_id=?", [.integer(sequence), .integer(Int64(outcome.rawValue)), .blob(uuidBytes(event.taskID))])
        default: break
        }
        return JournalAppend(record: JournalRecord(scope: expected, sequence: sequence, event: event, digest: digest), inserted: true)
    }
    public func appendBatch(_ events: [JournalEvent], expectedScope: JournalScope) throws -> [JournalAppend] {
        try append(events, expectedScope: expectedScope)
    }
    private func append(_ events: [JournalEvent], expectedScope: JournalScope, legacy: Bool = false, recovery: Bool = false, honorCancellation: Bool = true) throws -> [JournalAppend] {
        guard !events.isEmpty, events.count <= 32 else { throw JournalError.tooLarge }
        let encoded = try events.map(journalEncoded)
        guard encoded.reduce(0, { $0 + $1.count }) <= 512 * 1024 else { throw JournalError.tooLarge }
        return try transaction(scope: expectedScope, requireReady: !legacy, honorCancellation: honorCancellation) { _ in
            try zip(events, encoded).map { try insert($0.0, bytes: $0.1, expected: expectedScope, legacy: legacy, recovery: recovery) }
        }
    }
    public func acceptRequest(id: JournalOpaqueID, taskID: UUID, attemptID: UUID, text: JournalVisibleText, relation: JournalRunRelation? = nil, expectedScope: JournalScope) throws -> [JournalAppend] {
        guard text.origin == .user else { throw JournalError.invalidEvent }
        let start = JournalEvent(id: try JournalOpaqueID("start:" + taskID.uuidString), taskID: taskID, attemptID: attemptID, payload: .started(producerEpoch: producerEpoch, relation: relation))
        let message = JournalEvent(id: id, taskID: taskID, attemptID: attemptID, payload: .user(text))
        return try append([start, message], expectedScope: expectedScope)
    }
    public func commitIntent(_ event: JournalEvent, expectedScope: JournalScope) throws -> JournalIntentCommit {
        #if DEBUG
        if let fault = nextIntentFault { nextFault = fault; nextIntentFault = nil }
        #endif
        guard case .intent = event.payload else { throw JournalError.invalidEvent }
        let value = try append([event], expectedScope: expectedScope)[0]
        return value.inserted ? .inserted(value.record) : .alreadyRecorded(value.record)
    }
    public func commitResult(_ event: JournalEvent, expectedScope: JournalScope) throws -> JournalAppend {
        guard case .result = event.payload else { throw JournalError.invalidEvent }
        return try append([event], expectedScope: expectedScope, honorCancellation: false)[0]
    }
    public func finishTask(_ event: JournalEvent, expectedScope: JournalScope) throws -> JournalAppend {
        guard case .finished = event.payload else { throw JournalError.invalidEvent }
        return try append([event], expectedScope: expectedScope, honorCancellation: false)[0]
    }
    public func page(after cursor: JournalCursor? = nil, limit: Int = 100, byteBudget: Int = 1_048_576, expectedScope: JournalScope) throws -> JournalPage {
        try check(expectedScope)
        guard limit > 0, limit <= 500, byteBudget > 0, byteBudget <= 1_048_576, cursor == nil || cursor!.scope == expectedScope else { throw JournalError.invalidEvent }
        let previous = cursor?.sequence ?? 0; guard previous >= 0 else { throw JournalError.invalidEvent }
        let database = try db()
        return try database.withBudget {
            // Inspect lengths first; never materialize all candidate payloads just to enforce the page budget.
            let sizes = try database.query("SELECT sequence,length(payload) FROM events WHERE sequence>? ORDER BY sequence LIMIT ?", [.integer(previous), .integer(Int64(limit))], maximumRows: limit)
            var selected: [Int64] = [], count = 0
            for row in sizes {
                guard let sequence = row[0].integer, let length = row[1].integer, length > 0, length <= 262_144 else { throw JournalError.corrupt }
                guard length <= byteBudget - count else { if selected.isEmpty { throw JournalError.tooLarge }; break }
                selected.append(sequence); count += Int(length)
            }
            var records: [JournalRecord] = []
            for sequence in selected {
                let row = try database.query("SELECT \(Self.columns) FROM events WHERE sequence=?", [.integer(sequence)], maximumRows: 1).first!
                records.append(try record(row, expected: expectedScope))
            }
            let last = selected.last ?? previous
            let hasLater = try database.integer("SELECT EXISTS(SELECT 1 FROM events WHERE sequence>?)", [.integer(last)]) == 1
            return JournalPage(records: records, cursor: JournalCursor(scope: expectedScope, sequence: last), hasLater: hasLater)
        }
    }
    public func recoverInterrupted(expectedScope: JournalScope) throws -> [JournalRecord] {
        try check(expectedScope)
        let rows = try db().query("SELECT task_id,attempt_id FROM tasks WHERE finished_sequence IS NULL AND (producer_epoch IS NULL OR producer_epoch!=?) ORDER BY rowid", [.blob(uuidBytes(producerEpoch))], maximumRows: 100_000)
        var recovered: [JournalRecord] = []
        for chunk in stride(from: 0, to: rows.count, by: 32) {
            let events = try rows[chunk..<min(chunk + 32, rows.count)].map { row -> JournalEvent in
                let taskID = try uuidFromBytes(row[0].data!)
                return JournalEvent(id: try JournalOpaqueID("interrupted:" + expectedScope.generation.uuidString + ":" + taskID.uuidString), taskID: taskID, attemptID: try row[1].data.map(uuidFromBytes), payload: .finished(.interrupted))
            }
            recovered += try append(events, expectedScope: expectedScope, recovery: true, honorCancellation: false).map(\.record)
        }
        return recovered
    }
    public func reset(expectedScope: JournalScope) throws -> JournalScope {
        try transaction(scope: expectedScope, requireReady: false, honorCancellation: false) { database in
            try database.execute("DELETE FROM intents"); try database.execute("DELETE FROM tasks"); try database.execute("DELETE FROM events")
            try database.execute("UPDATE journal_state SET generation=?,readiness=1,legacy_consumed=1", [.blob(uuidBytes(UUID()))])
        }
        return try scope()
    }
    public func importLegacyBatch(_ events: [JournalEvent], manifest: JournalLegacyManifest, expectedScope: JournalScope) throws {
        let state = try db().query("SELECT readiness,legacy_consumed,legacy_digest,legacy_expected_records,legacy_events_digest FROM journal_state").first!
        guard state[0].integer == 0, state[1].integer == 0, state[2].data == manifest.digest, state[3].integer == Int64(manifest.expectedEvents), state[4].data == manifest.eventsDigest,
              events.allSatisfy({ if case .intent = $0.payload { return false }; if case .result = $0.payload { return false }; if case .started = $0.payload { return false }; return $0.attemptID == nil }) else { throw JournalError.notReady }
        _ = try append(events, expectedScope: expectedScope, legacy: true)
    }
    public func finishLegacyImport(manifest: JournalLegacyManifest, expectedScope: JournalScope) throws {
        try transaction(scope: expectedScope, requireReady: false) { database in
            let state = try database.query("SELECT readiness,legacy_consumed,legacy_digest,legacy_expected_records,legacy_events_digest FROM journal_state").first!
            if state[0].integer == 1, state[1].integer == 1, state[2].data == manifest.digest, state[3].integer == Int64(manifest.expectedEvents), state[4].data == manifest.eventsDigest { return }
            guard state[0].integer == 0, state[1].integer == 0, state[2].data == manifest.digest,
                  state[3].integer == Int64(manifest.expectedEvents), try database.integer("SELECT COUNT(*) FROM events") == Int64(manifest.expectedEvents), state[4].data == manifest.eventsDigest else { throw JournalError.notReady }
            let rows = try database.query("SELECT payload_sha256 FROM events ORDER BY sequence", maximumRows: 100_000)
            var allDigests = Data()
            for row in rows { guard let digest = row[0].data, digest.count == 32 else { throw JournalError.corrupt }; allDigests.append(digest) }
            guard journalDigest(allDigests) == manifest.eventsDigest else { throw JournalError.conflictingID }
            try database.execute("UPDATE journal_state SET readiness=1,legacy_consumed=1")
        }
    }
    public func close() throws { let database = try db(); try database.close(); self.database = nil; files = nil }
}
