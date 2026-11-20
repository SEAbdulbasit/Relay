import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

/// Real Store/SQLite boundaries, synthetic model and immutable backend only.
/// No Calendar permission, account, SDK event data or real model is used.
@Suite(.serialized) @MainActor struct CalendarReadStorePublicationTests {
    private func start(_ store: AssistantStore, _ f: CalendarProtocolFixture,
                       objective: String = "Read the selected calendars and describe the returned events.",
                       grants: [ScopeGrant]? = nil) async throws {
        await store.waitForConversationTaskToSettle()
        store.calendarSource.selectedCalendarIDs = f.source.selectedCalendarIDs
        store.grants = grants ?? [.init(path: f.root.path, writable: true)]
        store.draft = objective
        let ticket = try #require(store.send())
        #expect(await ticket.waitForAcknowledgment() == .saved)
    }
    private func close(_ store: AssistantStore, _ fixture: CalendarProtocolFixture) async {
        store.stop(); await store.waitForConversationTaskToSettle(); await fixture.close()
    }
    @Test func actualProtocolResultReachesTheNextTurnOnlyAfterSavedFreshQueryAdmission() async throws {
        let f = try CalendarProtocolFixture(); var turns = 0, executions = 0, admitted = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.call()]) }
            admitted = input.contains { $0.content.contains("OWNED_EVENT_CONTEXT") }
            return .init(content: "The bounded selected query returned the checked event.", toolCalls: [])
        }, conversationHistory: f.history, executeCalendarRead: { call, scope in
            executions += 1; return try await f.worker.read(call: call, scope: scope).result
        }, calendarReadWorker: f.worker)
        do {
            try await start(store, f); await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && executions == 1 && admitted && f.backend.count > 1)
            #expect(store.calendarSource.events.isEmpty)
            #expect(store.activity.contains { $0.name == "read_calendar" && $0.detail.contains("OWNED_EVENT_CONTEXT") })
            let rows = try await f.records()
            #expect(rows.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
            #expect(rows.filter { if case let .result(value) = $0.event.payload { value.kind == .returnedVerified } else { false } }.count == 1)
            await close(store, f)
        } catch { await close(store, f); throw error }
    }
    @Test(arguments: ["content", "selection", "database", "configuration", "stop", "replacement", "lost_ack"])
    func resultCommitCannotPublishItsFirstBodyAfterRevocationOrLostAcknowledgment(_ change: String) async throws {
        let f = try CalendarProtocolFixture(), barrier = CalendarProtocolBarrier()
        let core = try await f.history.journalForTesting()
        if change == "lost_ack" { await core.injectResultFault(.afterCommit, forToolName: "read_calendar") }
        await core.atNextResultBoundary(.afterCommit, forToolName: "read_calendar") { barrier.pause() }
        var turns = 0, executions = 0, laterInputs: [String] = []
        var replacement: ConversationSubmission?
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.call()]) }
            laterInputs.append(input.map(\.content).joined())
            #expect(!input.contains { $0.content.contains("OWNED_EVENT_CONTEXT") })
            return .init(content: "The previous calendar read fact remains recorded, without its unavailable body.", toolCalls: [])
        }, conversationHistory: f.history, executeCalendarRead: { call, scope in
            executions += 1; return try await f.worker.read(call: call, scope: scope).result
        }, calendarReadWorker: f.worker)
        do {
            try await start(store, f); try await waitForCalendarBarrier(barrier)
            #expect(turns == 1 && executions == 1 && !store.activity.contains { $0.detail.contains("OWNED_EVENT_CONTEXT") })
            switch change {
            case "content", "lost_ack": f.backend.change("CHANGED_CURRENT_EVENT")
            case "selection": store.calendarSource.selectedCalendarIDs = ["other-owned-selection"]
            case "database": f.worker.invalidateDatabaseForTesting()
            case "configuration": store.configuration.modelPath += "changed"
            default:
                store.stop()
                if change == "replacement" { store.draft = "Acknowledge this unrelated new task."; replacement = store.send() }
            }
            barrier.release(); await store.waitForConversationTaskToSettle(); await f.worker.drain()
            if let replacement { #expect(await replacement.waitForAcknowledgment() == .saved); await store.waitForConversationTaskToSettle() }
            #expect(executions == 1 && !store.activity.contains { $0.detail.contains("OWNED_EVENT_CONTEXT") })
            #expect(!store.messages.contains { $0.text.contains("OWNED_EVENT_CONTEXT") })
            if change == "lost_ack" {
                #expect(store.phase == .failed)
                try await store.retryConversationStorage(); store.resume(); await store.waitForConversationTaskToSettle()
                #expect(executions == 1 && !store.activity.contains { $0.detail.contains("OWNED_EVENT_CONTEXT") })
            }
            #expect(laterInputs.allSatisfy { !$0.contains("OWNED_EVENT_CONTEXT") })
            let rows = try await f.records()
            #expect(rows.filter { if case let .intent(value) = $0.event.payload { value.toolName == "read_calendar" } else { false } }.count == 1)
            #expect(rows.filter { if case let .result(value) = $0.event.payload { value.kind == .returnedVerified } else { false } }.count == 1)
            await close(store, f)
        } catch { barrier.release(); await close(store, f); throw error }
    }
    @Test(arguments: ["content", "selection", "stop"])
    func derivedActionRechecksTheActualIncludedQueryAfterItsDurableIntent(_ change: String) async throws {
        let f = try CalendarProtocolFixture(), barrier = CalendarProtocolBarrier(), core = try await f.history.journalForTesting()
        let output = f.root.appendingPathComponent("derived.txt")
        var turns = 0, executions = 0, writes = 0, admitted = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.call()]) }
            if turns == 2 {
                admitted = input.contains { $0.content.contains("OWNED_EVENT_CONTEXT") }
                await core.atNextBoundary(.afterCommit) { barrier.pause() }
                return .init(content: "", toolCalls: [.init(id: "derived", name: "write_file", arguments: ["path": .string(output.path), "content": .string("Derived from the current calendar query.")])])
            }
            return .init(content: "No stale calendar-derived action was repeated.", toolCalls: [])
        }, conversationHistory: f.history, execute: { _ in
            writes += 1; return .init(summary: "Unexpected write dispatch", evidence: "Inert effect counter", verified: true)
        }, executeCalendarRead: { call, scope in
            executions += 1; return try await f.worker.read(call: call, scope: scope).result
        }, calendarReadWorker: f.worker)
        do {
            try await start(store, f, objective: "Read the selected calendar, then write derived.txt in the selected folder from its current event description.")
            try await waitForCalendarBarrier(barrier)
            #expect(admitted && executions == 1 && writes == 0)
            switch change {
            case "content": f.backend.change("UNDELIVERED_CHANGED_EVENT")
            case "selection": store.calendarSource.selectedCalendarIDs = ["other-owned-selection"]
            default: store.stop()
            }
            barrier.release(); await store.waitForConversationTaskToSettle(); await f.worker.drain()
            #expect(turns == 2 && writes == 0 && !FileManager.default.fileExists(atPath: output.path))
            let rows = try await f.records()
            let intent = try #require(rows.compactMap { row -> JournalIntent? in
                if case let .intent(value) = row.event.payload, value.toolName == "write_file" { value } else { nil }
            }.first)
            #expect(rows.filter { if case let .result(value) = $0.event.payload { value.invocationID == intent.invocationID && value.kind == .notDispatched } else { false } }.count == 1)
            await close(store, f)
        } catch { barrier.release(); await close(store, f); throw error }
    }
    @Test(arguments: [false, true])
    func customOrForgedResultNeverBecomesCurrentCalendarAuthorityOrArtifact(_ forged: Bool) async throws {
        let f = try CalendarProtocolFixture(); var turns = 0, executions = 0
        let marker = "UNBOUND_CALENDAR_BODY"
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.call()]) }
            #expect(!input.contains { $0.content.contains(marker) })
            return .init(content: "The read fact is retained; current data needs a new selected query.", toolCalls: [])
        }, conversationHistory: f.history, executeCalendarRead: { call, scope in
            executions += 1
            var value: ToolResult
            if forged { value = try await f.worker.read(call: call, scope: scope).result }
            else { value = ToolResult(summary: "", evidence: "", verified: true) }
            // Even a producer object's presence cannot certify changed output.
            value.summary = marker; value.evidence = marker
            value.artifactPath = f.root.appendingPathComponent(marker).path
            return value
        }, calendarReadWorker: f.worker)
        do {
            try await start(store, f); await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && executions == 1 && f.backend.count == (forged ? 1 : 0))
            #expect(!store.activity.contains { $0.detail.contains(marker) } && !store.messages.contains { $0.text.contains(marker) })
            #expect(store.activity.contains { $0.detail.contains("The calendar result is unavailable for this task.") })
            let rows = try await f.records()
            for row in rows { if case let .result(value) = row.event.payload { #expect(value.artifacts.isEmpty) } }
            await close(store, f)
        } catch { await close(store, f); throw error }
    }
    @Test(arguments: [false, true])
    func sourceDriftDuringModelSuccessAndErrorCannotDispatchOrExposePrivateError(_ fail: Bool) async throws {
        let f = try CalendarProtocolFixture(); var turns = 0, executions = 0, writes = 0
        let marker = "UNADMITTED_PRIVATE_MODEL_ERROR"
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.call()]) }
            #expect(input.contains { $0.content.contains("OWNED_EVENT_CONTEXT") })
            f.backend.change("CHANGED_QUERY_CONTENT")
            if fail { throw RelayError.message(marker) }
            return .init(content: marker, toolCalls: [.init(id: "late", name: "write_file", arguments: ["path": .string(f.root.appendingPathComponent("late.txt").path), "content": .string("late")])])
        }, conversationHistory: f.history, execute: { _ in
            writes += 1; return .init(summary: "Unexpected effect", evidence: "Inert counter", verified: true)
        }, executeCalendarRead: { call, scope in
            executions += 1; return try await f.worker.read(call: call, scope: scope).result
        }, calendarReadWorker: f.worker)
        do {
            try await start(store, f); await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && executions == 1 && writes == 0)
            #expect(!(store.errorMessage ?? "").contains(marker) && !store.activity.contains { $0.detail.contains(marker) })
            let rows = try await f.records()
            #expect(!rows.contains { if case let .intent(value) = $0.event.payload { value.toolName == "write_file" } else { false } })
            await close(store, f)
        } catch { await close(store, f); throw error }
    }
    @Test func aFreshCalendarResultCannotLaunderItsRevokedIncomingSelectedFileProof() async throws {
        let f = try CalendarProtocolFixture(), barrier = CalendarProtocolBarrier()
        let core = try await f.history.journalForTesting(), fileWorker = FileExtractionWorker(), tools = MacTools()
        let selected = f.root.appendingPathComponent("source.txt")
        try Data("ACTUAL_SELECTED_FILE_INPUT_A".utf8).write(to: selected)
        tools.grants = [.init(path: f.root.path, writable: true)]
        await core.atNextResultBoundary(.afterCommit, forToolName: "read_calendar") { barrier.pause() }
        var turns = 0, calendarExecutions = 0, writes = 0, fileWasActuallyIncluded = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "selected-input", name: "read_file", arguments: ["path": .string(selected.path)])]) }
            if turns == 2 {
                fileWasActuallyIncluded = input.contains { $0.content.contains("ACTUAL_SELECTED_FILE_INPUT_A") }
                return .init(content: "", toolCalls: [f.call()])
            }
            #expect(!input.contains { $0.content.contains("OWNED_EVENT_CONTEXT") })
            return .init(content: "The calendar read fact remains recorded; its revoked input was not reused.", toolCalls: [])
        }, conversationHistory: f.history, execute: { _ in
            writes += 1; return .init(summary: "Unexpected effect", evidence: "Inert dispatch counter", verified: true)
        }, executeFileRead: { call, scope in
            try await tools.execute(call, fileReadScope: scope, fileReadWorker: fileWorker)
        }, fileReadWorker: fileWorker, executeCalendarRead: { call, scope in
            calendarExecutions += 1; return try await f.worker.read(call: call, scope: scope).result
        }, calendarReadWorker: f.worker)
        do {
            try await start(store, f, objective: "Read source.txt, then use the selected calendar to answer its question.")
            try await waitForCalendarBarrier(barrier)
            #expect(turns == 2 && fileWasActuallyIncluded && calendarExecutions == 1)
            // B itself is unchanged. Only the actual input A changes while B's
            // saved result awaits acknowledgment.
            try Data("REPLACED_SELECTED_FILE_INPUT_A".utf8).write(to: selected)
            barrier.release(); await store.waitForConversationTaskToSettle()
            #expect(writes == 0 && calendarExecutions == 1)
            #expect(!store.activity.contains { $0.detail.contains("OWNED_EVENT_CONTEXT") })
            #expect(!store.messages.contains { $0.text.contains("OWNED_EVENT_CONTEXT") })
            let rows = try await f.records()
            #expect(rows.filter { if case let .intent(value) = $0.event.payload { value.toolName == "read_calendar" } else { false } }.count == 1)
            store.stop(); await store.waitForConversationTaskToSettle(); await fileWorker.drain(); await f.close()
        } catch { barrier.release(); store.stop(); await store.waitForConversationTaskToSettle(); await fileWorker.drain(); await f.close(); throw error }
    }

    @Test func stopReturnsWhileAnOwnedBackendIsBlockedAndLateBodyNeverPublishes() async throws {
        let f = try CalendarProtocolFixture(), barrier = CalendarProtocolBarrier()
        f.backend.pauseNext(barrier)
        var turns = 0, executions = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1; return .init(content: "", toolCalls: [f.call()])
        }, conversationHistory: f.history, executeCalendarRead: { call, scope in
            executions += 1; return try await f.worker.read(call: call, scope: scope).result
        }, calendarReadWorker: f.worker)
        var settlement: Task<Void, Never>?
        do {
            try await start(store, f); try await waitForCalendarBarrier(barrier)
            let began = ContinuousClock.now
            store.stop()
            #expect(ContinuousClock.now - began < .seconds(1))
            var settled = false
            let task = Task { await store.waitForConversationTaskToSettle(); settled = true }
            settlement = task
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !settled && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            #expect(settled && f.worker.activeCount == 1 && turns == 1 && executions == 1)
            #expect(!store.activity.contains { $0.detail.contains("OWNED_EVENT_CONTEXT") })
            barrier.release(); await f.worker.drain(); await task.value
            #expect(f.worker.activeCount == 0 && !store.messages.contains { $0.text.contains("OWNED_EVENT_CONTEXT") })
            await close(store, f)
        } catch { barrier.release(); store.stop(); await settlement?.value; await close(store, f); throw error }
    }

    @Test func secondIncomingValidationCannotHideRecordedCalendarGenerationRevocation() async throws {
        let f = try CalendarProtocolFixture(), commit = CalendarProtocolBarrier()
        let firstA = CalendarProtocolBarrier(), secondA = CalendarProtocolBarrier()
        let core = try await f.history.journalForTesting(), fileWorker = FileExtractionWorker(), tools = MacTools()
        let path = f.root.appendingPathComponent("included-a.txt"), bytes = Data("CURRENT_SELECTED_INPUT_A".utf8)
        try bytes.write(to: path)
        let originalGrants = [ScopeGrant(path: f.root.path, writable: true)]
        tools.grants = originalGrants
        await core.atNextResultBoundary(.afterCommit, forToolName: "read_calendar") { commit.pause() }
        var turns = 0, fileReads = 0, calendarReads = 0, otherEffects = 0, aRemainedIncluded = false
        var actualCalendarScope: CalendarReadExecutionScope?
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "source-a", name: "read_file", arguments: ["path": .string(path.path)])]) }
            if turns == 2 {
                #expect(input.contains { $0.content.contains("CURRENT_SELECTED_INPUT_A") })
                return .init(content: "", toolCalls: [f.call()])
            }
            aRemainedIncluded = input.contains { $0.content.contains("CURRENT_SELECTED_INPUT_A") }
            #expect(!input.contains { $0.content.contains("OWNED_EVENT_CONTEXT") })
            return .init(content: "The unchanged selected file remains available; the calendar read fact is retained without its unavailable event body.", toolCalls: [])
        }, conversationHistory: f.history, execute: { _ in
            otherEffects += 1; return .init(summary: "Unexpected effect", evidence: "Inert counter", verified: true)
        }, executeFileRead: { call, scope in
            fileReads += 1; return try await tools.execute(call, fileReadScope: scope, fileReadWorker: fileWorker)
        }, fileReadWorker: fileWorker, executeCalendarRead: { call, scope in
            calendarReads += 1; actualCalendarScope = scope
            return try await f.worker.read(call: call, scope: scope).result
        }, calendarReadWorker: f.worker)
        do {
            try await start(store, f, objective: "Read included-a.txt, then answer using the selected calendar. Do not modify anything.",
                            grants: originalGrants)
            #expect(store.grants == originalGrants)
            try await waitForCalendarBarrier(commit)
            fileWorker.pauseAfterNextSnapshot { firstA.pause() }
            commit.release()
            try await waitForCalendarBarrier(firstA)
            // Arming only after the first hook was consumed makes the second
            // real read unambiguous; no fixed number of earlier reads is assumed.
            fileWorker.pauseAfterNextSnapshot { secondA.pause() }
            firstA.release()
            try await waitForCalendarBarrier(secondA)
            let scope = try #require(actualCalendarScope), source = store.calendarSource.calendarReadSeed()
            let configuration = store.configuration, beforeGeneration = f.worker.databaseGeneration
            let checks = f.worker.generationFenceChecks, queries = f.backend.count
            #expect(queries == 2 && fileReads == 1 && calendarReads == 1 && turns == 2)
            f.worker.invalidateDatabaseForTesting()
            #expect(f.worker.databaseGeneration != beforeGeneration)
            #expect(source.matches(store.calendarSource.calendarReadSeed()))
            #expect(store.grants == originalGrants && store.configuration == configuration)
            try scope.validateCurrent(call: f.call()) // Actual task/context/Source scope is still current.
            #expect(try Data(contentsOf: path) == bytes)
            secondA.release(); await store.waitForConversationTaskToSettle()
            // If A timed out or failed, the final generation fence would not
            // execute. This counter prevents a closed-error false positive.
            #expect(f.worker.generationFenceChecks > checks)
            #expect(f.backend.count == queries && fileReads == 1 && calendarReads == 1 && otherEffects == 0)
            #expect(turns == 3 && aRemainedIncluded)
            #expect(!store.activity.contains { $0.detail.contains("OWNED_EVENT_CONTEXT") })
            #expect(!store.messages.contains { $0.text.contains("OWNED_EVENT_CONTEXT") })
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains("CURRENT_SELECTED_INPUT_A") })
            #expect(store.activity.contains { $0.name == "read_calendar" && $0.detail.contains("The calendar result is unavailable for this task.") })
            #expect(source.matches(store.calendarSource.calendarReadSeed()) && store.grants == originalGrants)
            #expect(try Data(contentsOf: path) == bytes)
            let rows = try await f.records()
            #expect(rows.filter { if case let .intent(value) = $0.event.payload { value.toolName == "read_calendar" } else { false } }.count == 1)
            #expect(rows.filter { if case let .result(value) = $0.event.payload { value.kind == .returnedVerified } else { false } }.count == 2)
            store.stop(); await store.waitForConversationTaskToSettle(); await fileWorker.drain(); await f.close()
        } catch {
            commit.release(); firstA.release(); secondA.release(); store.stop()
            await store.waitForConversationTaskToSettle(); await fileWorker.drain(); await f.close(); throw error
        }
    }

}
