import Foundation
import Testing
@testable import Relay

private actor SyntheticCalendarTransportFixture {
    struct StoredEvent {
        let calendarID: String
        let eventIdentifier: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var location: String
        var notes: String
        var timeZone: String?
    }

    var events: [String: StoredEvent] = [:] // eventIdentifier -> StoredEvent
    var createCount = 0
    var readCount = 0
    var deleteCount = 0
    var simulateReadbackMismatch = false
    var simulateCreateFailure = false
    var simulateReadFailure = false
    var simulateDeleteFailure = false

    nonisolated var transport: CalendarWriteTransport {
        CalendarWriteTransport(
            create: { event in try await self.create(event) },
            read: { calendarID, eventIdentifier in try await self.read(calendarID: calendarID, eventIdentifier: eventIdentifier) },
            delete: { calendarID, eventIdentifier in try await self.delete(calendarID: calendarID, eventIdentifier: eventIdentifier) }
        )
    }

    func create(_ event: CalendarWriteEvent) throws -> CalendarWriteSnapshot {
        createCount += 1
        if simulateCreateFailure {
            throw CalendarWriteFailure.eventSaveFailed
        }
        let id = "synth-evt-" + UUID().uuidString
        let stored = StoredEvent(
            calendarID: event.calendarID,
            eventIdentifier: id,
            title: event.title,
            start: event.start,
            end: event.end,
            allDay: event.allDay,
            location: event.location,
            notes: event.notes,
            timeZone: event.timeZone
        )
        events[id] = stored
        return CalendarWriteSnapshot(eventIdentifier: id, calendarID: event.calendarID, event: event, createdAt: Date())
    }

    func read(calendarID: String, eventIdentifier: String) throws -> CalendarWriteSnapshot {
        readCount += 1
        if simulateReadFailure {
            throw CalendarWriteFailure.eventNotFound
        }
        guard let stored = events[eventIdentifier], stored.calendarID == calendarID else {
            throw CalendarWriteFailure.eventNotFound
        }
        let title = simulateReadbackMismatch ? "Corrupted Title" : stored.title
        let event = CalendarWriteEvent(
            id: UUID(),
            calendarID: calendarID,
            title: title,
            start: stored.start,
            end: stored.end,
            allDay: stored.allDay,
            location: stored.location,
            notes: stored.notes,
            timeZone: stored.timeZone
        )
        return CalendarWriteSnapshot(eventIdentifier: eventIdentifier, calendarID: calendarID, event: event, createdAt: Date())
    }

    func delete(calendarID: String, eventIdentifier: String) -> Bool {
        deleteCount += 1
        guard !simulateDeleteFailure,
              let stored = events[eventIdentifier], stored.calendarID == calendarID else { return false }
        events.removeValue(forKey: eventIdentifier)
        return true
    }

    func setMismatch() { simulateReadbackMismatch = true }
    func setCreateFailure() { simulateCreateFailure = true }
    func setReadFailure() { simulateReadFailure = true }
    func setDeleteFailure() { simulateDeleteFailure = true }
    func storedCount() -> Int { events.count }
}

@Suite(.serialized) @MainActor
struct CalendarWriteWorkflowTests {

    #if DEBUG
    @Test(arguments: LocalBackend.allCases) func selectedCalendarFlowsThroughEveryConfiguredPlannerAndExactReviews(backend: LocalBackend) async throws {
        let fixture = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fixture.transport)
        let stage = ToolCall(name: "create_calendar_event", arguments: ["event_json": .string("""
            {"calendar_id":"selected","title":"Owned fixture event","start":"2026-11-10T10:00:00Z","end":"2026-11-10T11:00:00Z"}
            """)])
        let store = AssistantStore(persistenceURL: nil, complete: { messages, tools, _ in
            #expect(tools.contains { $0.name == "create_calendar_event" })
            #expect(messages.first?.content.contains("calendar_id=selected") == true)
            #expect(messages.allSatisfy { !$0.content.contains(self.testCalendarID) && !$0.content.contains(self.testCalendarTitle) })
            if messages.contains(where: { $0.toolName == "commit_calendar_event" }) {
                return .init(content: "The reviewed event was saved.", toolCalls: [])
            }
            guard let result = messages.last(where: { $0.toolCallID == stage.id }) else {
                return .init(content: "", toolCalls: [stage])
            }
            let feedback = try JSONDecoder().decode(ToolResult.self, from: Data(result.content.utf8))
            let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(feedback.summary.utf8))
            let id = try #require(fields["review_id"]?.string)
            return .init(content: "", toolCalls: [.init(name: "commit_calendar_event", arguments: ["review_id": .string(id)])])
        }, calendarWriteWorkflow: workflow)
        store.configuration.backend = backend
        store.calendarSource.setWriteCalendarCatalogForTesting([
            .init(id: testCalendarID, title: testCalendarTitle, allowsContentModifications: true)
        ])
        try store.calendarSource.selectWriteCalendar(id: testCalendarID, catalogEpoch: store.calendarSource.selectionCatalog.epoch)
        store.draft = "Create an event named Owned fixture event in the selected calendar."
        let ticket = try #require(store.send())
        #expect(await ticket.waitForAcknowledgment() == .saved)

        for name in ["create_calendar_event", "commit_calendar_event"] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while store.pendingReview == nil, store.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let review = try #require(store.pendingReview)
            #expect(review.call.name == name)
            #expect(await fixture.storedCount() == 0)
            store.approveReview()
        }
        await store.waitForConversationTaskToSettle()
        #expect(await fixture.createCount == 1)
        #expect(await fixture.readCount == 1)
        #expect(await fixture.storedCount() == 1)
        #expect(store.messages.last?.text.contains("reviewed event was saved") == true)
    }
    @Test func selectedCalendarFlowsThroughHostedCodexAndExactReviews() async throws {
        let fixture = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fixture.transport)
        let stage = ToolCall(name: "create_calendar_event", arguments: ["event_json": .string("""
            {"calendar_id":"selected","title":"Owned fixture event","start":"2026-11-10T10:00:00Z","end":"2026-11-10T11:00:00Z"}
            """)])
        let store = AssistantStore(persistenceURL: nil, calendarWriteWorkflow: workflow, codexComplete: { messages, tools in
            #expect(tools.contains { $0.name == "create_calendar_event" })
            #expect(messages.first?.content.contains("calendar_id=selected") == true)
            #expect(messages.allSatisfy { !$0.content.contains(self.testCalendarID) && !$0.content.contains(self.testCalendarTitle) })
            if messages.contains(where: { $0.toolName == "commit_calendar_event" }) {
                return .init(content: "The reviewed event was saved.", toolCalls: [])
            }
            guard let result = messages.last(where: { $0.toolCallID == stage.id }) else {
                return .init(content: "", toolCalls: [stage])
            }
            let feedback = try JSONDecoder().decode(ToolResult.self, from: Data(result.content.utf8))
            let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(feedback.summary.utf8))
            let id = try #require(fields["review_id"]?.string)
            return .init(content: "", toolCalls: [.init(name: "commit_calendar_event", arguments: ["review_id": .string(id)])])
        }, codexCheck: {})
        store.calendarSource.setWriteCalendarCatalogForTesting([
            .init(id: testCalendarID, title: testCalendarTitle, allowsContentModifications: true)
        ])
        try store.calendarSource.selectWriteCalendar(id: testCalendarID, catalogEpoch: store.calendarSource.selectionCatalog.epoch)
        await store.selectWorkspaceCodex()
        #expect(store.workspaceUsesCodex)
        store.draft = "Create an event named Owned fixture event in the selected calendar."
        let ticket = try #require(store.send(useWorkspaceProvider: true))
        #expect(await ticket.waitForAcknowledgment() == .saved)

        for name in ["create_calendar_event", "commit_calendar_event"] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while store.pendingReview == nil, store.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let review = try #require(store.pendingReview)
            #expect(review.call.name == name)
            #expect(await fixture.storedCount() == 0)
            store.approveReview()
        }
        await store.waitForConversationTaskToSettle()
        #expect(await fixture.createCount == 1)
        #expect(await fixture.readCount == 1)
        #expect(await fixture.storedCount() == 1)
        #expect(store.messages.last?.text.contains("reviewed event was saved") == true)
    }
    @Test func multiAgentCalendarUsesActualStageReceiptAndExactCommitReviews() async throws {
        let fixture = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fixture.transport)
        var plannerTurns = 0
        let stage = ToolCall(name: "create_calendar_event", arguments: ["event_json": .string("""
            {"calendar_id":"selected","title":"Owned delegated event","start":"2026-11-10T10:00:00Z","end":"2026-11-10T11:00:00Z"}
            """)])
        let store = AssistantStore(persistenceURL: nil, complete: { messages, definitions, _ in
            let system = messages.first?.content ?? ""
            #expect(system.contains("calendar_id=selected"))
            #expect(messages.allSatisfy { !$0.content.contains(self.testCalendarID) && !$0.content.contains(self.testCalendarTitle) })
            if system.hasPrefix("ROLE: Planner") {
                plannerTurns += 1
                if plannerTurns == 1 {
                    return .init(content: #"{"taskType":"automation","steps":[{"id":"stage","role":"Executor","title":"Stage the requested calendar event"},{"id":"commit","role":"Executor","title":"Commit the exact reviewed event"}]}"#, toolCalls: [])
                }
                return .init(content: "The reviewed delegated event was saved.", toolCalls: [])
            }
            if system.hasPrefix("ROLE: Critic") {
                return .init(content: "VERIFIED: the actual workflow returned its checked outcome.", toolCalls: [])
            }
            #expect(system.hasPrefix("ROLE: Executor"))
            #expect(definitions.contains { $0.name == "create_calendar_event" })
            let receiptText = messages.map(\.content).joined(separator: "\n")
                .replacingOccurrences(of: "\u{005C}\u{0022}", with: "\u{0022}")
            let pattern = #""review_id"\s*:\s*"([0-9A-Fa-f-]{36})""#
            let regex = try NSRegularExpression(pattern: pattern)
            let match = regex.firstMatch(in: receiptText, range: NSRange(receiptText.startIndex..., in: receiptText))
            guard let match, let range = Range(match.range(at: 1), in: receiptText) else {
                return .init(content: "", toolCalls: [stage])
            }
            return .init(content: "", toolCalls: [.init(name: "commit_calendar_event", arguments: ["review_id": .string(String(receiptText[range]))])])
        }, calendarWriteWorkflow: workflow, multiAgent: true)
        store.calendarSource.setWriteCalendarCatalogForTesting([
            .init(id: testCalendarID, title: testCalendarTitle, allowsContentModifications: true)
        ])
        try store.calendarSource.selectWriteCalendar(id: testCalendarID, catalogEpoch: store.calendarSource.selectionCatalog.epoch)
        store.draft = "Create the owned delegated event in the selected calendar after exact review."
        let ticket = try #require(store.send())
        #expect(await ticket.waitForAcknowledgment() == .saved)
        for name in ["create_calendar_event", "commit_calendar_event"] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while store.pendingReview == nil, store.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let review = try #require(store.pendingReview)
            #expect(review.call.name == name)
            #expect(await fixture.storedCount() == 0)
            store.approveReview()
        }
        await store.waitForConversationTaskToSettle()
        #expect(await fixture.createCount == 1)
        #expect(await fixture.readCount == 1)
        #expect(await fixture.storedCount() == 1)
    }

    @Test func codexCLIMeetingClarificationsKeepOriginalRequestAndCalendarCapability() async throws {
        let fixture = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fixture.transport)
        let zone = try #require(TimeZone(identifier: "Asia/Riyadh"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())))
        let start = tomorrow.addingTimeInterval(12 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        let event = JSONValue.object(["calendar_id": .string("selected"), "title": .string("Alignment"),
            "start": .string(formatter.string(from: start)), "end": .string(formatter.string(from: start.addingTimeInterval(15 * 60))),
            "time_zone": .string(zone.identifier)])
        let stage = ToolCall(name: "create_calendar_event", arguments: ["event_json": .string(event.pretty)])
        var completions = 0
        let store = AssistantStore(persistenceURL: nil, complete: { messages, definitions, configuration in
            completions += 1
            #expect(configuration.backend == .codexCLI)
            #expect(definitions.contains { $0.name == "create_calendar_event" })
            #expect(definitions.contains { $0.name == "commit_calendar_event" })
            let context = messages.first?.content ?? ""
            #expect(context.contains("calendar_id=selected") && context.contains("Device date/time:"))
            #expect(!context.contains(self.testCalendarID) && !context.contains(self.testCalendarTitle))
            let dialogue = messages.map(\.content).joined(separator: "\n")
            #expect(dialogue.contains("create a meeting for tomorrow at 12 PM"))
            if completions == 1 {
                return .init(content: "What should the meeting be called, how long should it last, and should anyone be invited?", toolCalls: [])
            }
            #expect(dialogue.contains("Alignment and only me"))
            if completions == 2 {
                return .init(content: "How long should Alignment last?", toolCalls: [])
            }
            #expect(dialogue.contains("15 min"))
            if messages.contains(where: { $0.toolName == "commit_calendar_event" }) {
                return .init(content: "Alignment was created and checked in the selected calendar.", toolCalls: [])
            }
            guard let output = messages.last(where: { $0.toolCallID == stage.id }) else {
                return .init(content: "", toolCalls: [stage])
            }
            let feedback = try JSONDecoder().decode(ToolResult.self, from: Data(output.content.utf8))
            let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(feedback.summary.utf8))
            let id = try #require(fields["review_id"]?.string)
            return .init(content: "", toolCalls: [.init(name: "commit_calendar_event", arguments: ["review_id": .string(id)])])
        }, calendarWriteWorkflow: workflow)
        store.configuration.backend = .codexCLI
        store.calendarSource.setWriteCalendarCatalogForTesting([
            .init(id: testCalendarID, title: testCalendarTitle, allowsContentModifications: true)
        ])
        try store.calendarSource.selectWriteCalendar(id: testCalendarID, catalogEpoch: store.calendarSource.selectionCatalog.epoch)
        for utterance in ["create a meeting for tomorrow at 12 PM", "Alignment and only me"] {
            store.draft = utterance
            let ticket = try #require(store.send())
            #expect(await ticket.waitForAcknowledgment() == .saved)
            await store.waitForConversationTaskToSettle()
            #expect(await fixture.createCount == 0)
            #expect(store.pendingReview == nil)
        }
        store.draft = "15 min"
        let ticket = try #require(store.send())
        #expect(await ticket.waitForAcknowledgment() == .saved)
        for name in ["create_calendar_event", "commit_calendar_event"] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while store.pendingReview == nil, store.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let review = try #require(store.pendingReview)
            #expect(review.call.name == name)
            #expect(review.reason.contains("Alignment"))
            #expect(await fixture.createCount == 0)
            store.approveReview()
        }
        await store.waitForConversationTaskToSettle()
        #expect(await fixture.createCount == 1)
        #expect(await fixture.readCount == 1)
        #expect(store.messages.last?.text.contains("created and checked") == true)
    }

    @Test func missingDestinationExplainsSetupWithoutClaimingCalendarIsUnsupported() async throws {
        var inspected = false
        let store = AssistantStore(persistenceURL: nil, complete: { messages, definitions, _ in
            inspected = true
            #expect(!definitions.contains { CalendarWriteWorkflowTools.names.contains($0.name) })
            let context = messages.first?.content ?? ""
            #expect(context.contains("No write destination is selected"))
            #expect(context.contains("Settings → Sources → Apple Calendar"))
            #expect(context.contains("Calendar creation is supported"))
            return .init(content: "Choose Calendar for event creation in Settings → Sources → Apple Calendar, then retry.", toolCalls: [])
        })
        store.configuration.backend = .codexCLI
        store.draft = "Create a personal planning meeting tomorrow at noon for 15 minutes."
        let ticket = try #require(store.send())
        #expect(await ticket.waitForAcknowledgment() == .saved)
        await store.waitForConversationTaskToSettle()
        #expect(inspected)
        #expect(store.messages.last?.text.contains("Calendar for event creation") == true)
        #expect(store.calendarSource.writeCalendar == nil)
        #expect(store.pendingReview == nil)
    }

    @Test func selectedCalendarAndMCPProfilesRetainAFullFreshNativeObservation() async throws {
        let controls = (0..<16).map { index in
            "element_id=fixture-control-\(index) role=AXStaticText title=Native fixture source row \(index) value=\(String(repeating: "ordinary bounded source text ", count: 5)) window_id=original-window"
        }.joined(separator: "\n")
        let fresh = controls + "\nelement_id=fresh-input-8431 role=AXTextField title=Fixture input value= identifier=relay.fixture.input window_id=original-window\n"
            + "element_id=fresh-apply-8431 role=AXButton title=Apply identifier=relay.fixture.apply window_id=original-window\n"
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { messages, definitions, _ in
            turns += 1
            #expect(definitions.contains { $0.name == "create_calendar_event" })
            let advertisedNames = Set(definitions.map(\.name))
            var catalog = definitions
            for candidate in MainAgentMCPTools.definitions {
                if !advertisedNames.contains(candidate.name) { catalog.append(candidate) }
            }
            let native = try LocalModelClient.prepareNativeTextContext(messages: messages, tools: catalog)
            #expect(native.availableHistoryBytes >= 6_000)
            let systemBytes = messages.filter { $0.role == "system" }.reduce(0) { $0 + $1.content.utf8.count }
            #expect(LocalModelClient.maximumContextBytes - systemBytes - (try JSONEncoder().encode(catalog)).count >= 6_000)
            print("Calendar+MCP native history budget: \(native.availableHistoryBytes), schema: \(native.actualNativeSchemaBytes), system: \(native.systemPrompt.utf8.count)")
            if turns == 1 { return .init(content: "", toolCalls: [.init(name: "observe_app", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID)])]) }
            let output = try #require(messages.last { $0.toolName == "observe_app" })
            let feedback = try JSONDecoder().decode(ToolResult.self, from: Data(output.content.utf8))
            #expect(fresh.utf8.count == 4_396)
            #expect(Data(feedback.summary.utf8) == Data(fresh.utf8))
            return .init(content: "Whole fresh observation retained.", toolCalls: [])
        }, execute: { call in
            #expect(call.name == "observe_app")
            return .init(summary: fresh, evidence: "Owned fixture only.", verified: true)
        })
        store.configuration = ModelConfiguration(modelPath: "/synthetic/calendar-context-capacity.litertlm")
        store.calendarSource.setWriteCalendarCatalogForTesting([
            .init(id: testCalendarID, title: testCalendarTitle, allowsContentModifications: true)
        ])
        try store.calendarSource.selectWriteCalendar(id: testCalendarID, catalogEpoch: store.calendarSource.selectionCatalog.epoch)
        store.draft = "Inspect only the already-running owned Relay Accessibility Fixture, preserving the complete native observation."
        let ticket = try #require(store.send())
        #expect(await ticket.waitForAcknowledgment() == .saved)
        await store.waitForConversationTaskToSettle()
        #expect(turns == 2 && store.errorMessage == nil)
    }

    @Test func calendarCapabilityUsesDeviceClockAndOpaqueDestination() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Riyadh"))
        let context = CalendarPlannerSupport.instructions(hasWriteDestination: true,
            now: Date(timeIntervalSince1970: 0), timeZone: zone)
        #expect(context.contains("1970-01-01T03:00:00+03:00"))
        #expect(context.contains("Asia/Riyadh"))
        #expect(context.contains("calendar_id=selected"))
        #expect(context.contains("attendees are not supported"))
    }

    #endif
    init() async throws {
        await awaitParitySuiteQuietWindow()
    }
    private let testCalendarID = "owned-test-calendar-uuid-1"
    private let testCalendarTitle = "Relay Synthetic Test Calendar"

    private func makeEvent(title: String = "Sprint Planning",
                           start: Date = Date(timeIntervalSince1970: 1_700_000_000),
                           end: Date = Date(timeIntervalSince1970: 1_700_003_600),
                           allDay: Bool = false,
                           location: String = "Meeting Room A",
                           notes: String = "Discussion of parity backlog.") -> CalendarWriteEvent {
        CalendarWriteEvent(
            calendarID: testCalendarID,
            title: title,
            start: start,
            end: end,
            allDay: allDay,
            location: location,
            notes: notes
        )
    }

    @Test func exactDisplayedReviewIsRequiredAndOneUse() async throws {
        let fake = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fake.transport)
        workflow.configureTestCalendar(id: testCalendarID, title: testCalendarTitle, isSelected: true)

        let event = makeEvent()
        let review = try await workflow.stageEvent(requestID: "req-1", event: event)
        #expect(review.calendarID == testCalendarID)
        #expect(review.calendarTitle == testCalendarTitle)

        // Cannot approve before review is displayed
        #expect(throws: CalendarWriteFailure.reviewNotDisplayed) {
            try workflow.approve(review.id, displayedFingerprint: review.fingerprint)
        }

        // Display review
        let displayed = try workflow.reviewForDisplay(review.id)
        #expect(displayed.reviewText.contains("Sprint Planning"))
        #expect(displayed.reviewText.contains("Meeting Room A"))
        #expect(displayed.reviewText.contains(testCalendarTitle))

        // Approve with wrong fingerprint fails
        #expect(throws: CalendarWriteFailure.reviewNotDisplayed) {
            try workflow.approve(review.id, displayedFingerprint: "wrong-fingerprint")
        }

        // Approve with exact displayed fingerprint succeeds
        try workflow.approve(review.id, displayedFingerprint: displayed.fingerprint)

        // Execute approved review
        let receipt = try await workflow.executeApproved(review.id)
        #expect(receipt.status == .verified)
        #expect(!receipt.eventIdentifier.isEmpty)
        #expect(receipt.calendarID == testCalendarID)
        #expect(await fake.createCount == 1)
        #expect(await fake.readCount == 1) // independent readback verification occurred!
        #expect(await fake.storedCount() == 1)

        // Review is one-use: re-executing fails
        await #expect(throws: CalendarWriteFailure.reviewUnavailable) {
            try await workflow.executeApproved(review.id)
        }
    }

    @Test func retryDeduplicationPreventsDuplicateWrites() async throws {
        let fake = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fake.transport)
        workflow.configureTestCalendar(id: testCalendarID, title: testCalendarTitle, isSelected: true)

        let event = makeEvent()
        let review = try await workflow.stageEvent(requestID: "req-dedup-1", event: event)
        let displayed = try workflow.reviewForDisplay(review.id)
        try workflow.approve(review.id, displayedFingerprint: displayed.fingerprint)
        _ = try await workflow.executeApproved(review.id)

        #expect(await fake.createCount == 1)

        // Staging the exact same requestID again blocks replay
        await #expect(throws: CalendarWriteFailure.replayBlocked) {
            try await workflow.stageEvent(requestID: "req-dedup-1", event: event)
        }

        // Staging with different content under same requestID also blocks replay
        let different = makeEvent(title: "Different Meeting")
        await #expect(throws: CalendarWriteFailure.replayBlocked) {
            try await workflow.stageEvent(requestID: "req-dedup-1", event: different)
        }
        #expect(await fake.createCount == 1)
    }

    @Test func readbackMismatchTriggersSafeRollback() async throws {
        let fake = SyntheticCalendarTransportFixture()
        await fake.setMismatch()
        let workflow = CalendarWriteWorkflow(transport: fake.transport)
        workflow.configureTestCalendar(id: testCalendarID, title: testCalendarTitle, isSelected: true)

        let event = makeEvent()
        let review = try await workflow.stageEvent(requestID: "req-mismatch-1", event: event)
        let displayed = try workflow.reviewForDisplay(review.id)
        try workflow.approve(review.id, displayedFingerprint: displayed.fingerprint)

        // When executeApproved runs, readback returns a mismatched title, so it must rollback
        await #expect(throws: (any Error).self) {
            try await workflow.executeApproved(review.id)
        }

        #expect(await fake.createCount == 1)
        #expect(await fake.readCount == 1)
        #expect(await fake.deleteCount == 1) // Safe rollback was executed!
        #expect(await fake.storedCount() == 0) // Calendar is clean

        let receipt = workflow.receipt(for: review.id)
        #expect(receipt?.status == .readbackMismatch)
    }

    @Test func explicitRollbackDeletesCreatedEvent() async throws {
        let fake = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fake.transport)
        workflow.configureTestCalendar(id: testCalendarID, title: testCalendarTitle, isSelected: true)

        let event = makeEvent()
        let review = try await workflow.stageEvent(requestID: "req-rb-1", event: event)
        let displayed = try workflow.reviewForDisplay(review.id)
        try workflow.approve(review.id, displayedFingerprint: displayed.fingerprint)
        let receipt = try await workflow.executeApproved(review.id)
        #expect(receipt.status == .verified)
        #expect(await fake.storedCount() == 1)

        // Now trigger explicit rollback
        let success = try await workflow.rollback(reviewID: review.id)
        #expect(success)
        #expect(await fake.deleteCount == 1)
        #expect(await fake.storedCount() == 0)
        #expect(workflow.receipt(for: review.id)?.status == .rolledBack)
    }

    @Test func unconfirmedRollbackKeepsTheWriteUncertainAndBlocksReplay() async throws {
        let fake = SyntheticCalendarTransportFixture()
        await fake.setMismatch()
        await fake.setDeleteFailure()
        let workflow = CalendarWriteWorkflow(transport: fake.transport)
        workflow.configureTestCalendar(id: testCalendarID, title: testCalendarTitle)
        let event = makeEvent()
        let review = try await workflow.stageEvent(requestID: "uncertain-rollback", event: event)
        let displayed = try workflow.reviewForDisplay(review.id)
        try workflow.approve(review.id, displayedFingerprint: displayed.fingerprint)

        await #expect(throws: CalendarWriteFailure.self) { try await workflow.executeApproved(review.id) }
        #expect(workflow.receipt(for: review.id)?.status == .uncertain)
        #expect(await fake.storedCount() == 1)
        await #expect(throws: CalendarWriteFailure.replayBlocked) {
            try await workflow.stageEvent(requestID: "uncertain-rollback", event: event)
        }
    }

    @Test func onlyExplicitlySelectedTestCalendarAllowed() async throws {
        let fake = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fake.transport)

        // Not designated as test calendar
        let event = makeEvent()
        await #expect(throws: CalendarWriteFailure.unselectedCalendar) {
            try await workflow.stageEvent(requestID: "req-unsel", event: event)
        }

        // Designated as test calendar, but not selected
        workflow.configureTestCalendar(id: testCalendarID, title: testCalendarTitle, isSelected: false)
        await #expect(throws: CalendarWriteFailure.unselectedCalendar) {
            try await workflow.stageEvent(requestID: "req-unsel-2", event: event)
        }

        // Selected, but not in designated test set
        workflow.setSelectedCalendar(id: "personal-user-calendar")
        let personalEvent = CalendarWriteEvent(calendarID: "personal-user-calendar", title: "Test", start: Date(), end: Date())
        await #expect(throws: CalendarWriteFailure.notTestCalendar) {
            try await workflow.stageEvent(requestID: "req-personal", event: personalEvent)
        }

        // Both designated and selected: succeeds
        workflow.configureTestCalendar(id: testCalendarID, title: testCalendarTitle, isSelected: true)
        let review = try await workflow.stageEvent(requestID: "req-ok", event: event)
        #expect(review.calendarID == testCalendarID)

        // If selection changes while review is pending, pending review is invalidated
        workflow.setSelectedCalendar(id: "other-test-calendar")
        #expect(throws: CalendarWriteFailure.reviewUnavailable) {
            try workflow.reviewForDisplay(review.id)
        }
    }

    @Test func expiredReviewCannotExecute() async throws {
        var clockTime = Date(timeIntervalSince1970: 1_000)
        let fake = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fake.transport, now: { clockTime })
        workflow.configureTestCalendar(id: testCalendarID, title: testCalendarTitle, isSelected: true)

        let event = makeEvent()
        let review = try await workflow.stageEvent(requestID: "req-exp", event: event)
        let displayed = try workflow.reviewForDisplay(review.id)
        try workflow.approve(review.id, displayedFingerprint: displayed.fingerprint)

        // Advance clock past 120s expiration
        clockTime = clockTime.addingTimeInterval(125)

        await #expect(throws: CalendarWriteFailure.reviewExpired) {
            try await workflow.executeApproved(review.id)
        }
        #expect(await fake.createCount == 0)
    }

    @Test func toolExecutionPipelineViaToolsAdapter() async throws {
        let fake = SyntheticCalendarTransportFixture()
        let workflow = CalendarWriteWorkflow(transport: fake.transport)
        workflow.configureTestCalendar(id: testCalendarID, title: testCalendarTitle, isSelected: true)
        let tools = CalendarWriteWorkflowTools(workflow: workflow)

        let eventJSON = """
        {
            "calendar_id": "\(testCalendarID)",
            "title": "Architecture Review",
            "start": "2026-11-10T10:00:00Z",
            "end": "2026-11-10T11:00:00Z",
            "all_day": false,
            "location": "Conf Room 4",
            "notes": "Parity review for AUT-29."
        }
        """

        let stageCall = ToolCall(name: "create_calendar_event", arguments: ["event_json": .string(eventJSON)])
        let stageReason = try #require(try tools.reviewReason(stageCall))
        #expect(stageReason.contains("Architecture Review"))
        try tools.prepareReview(stageCall)
        try tools.authorize(stageCall)
        let stageResult = try await tools.execute(stageCall)
        #expect(stageResult.verified)

        guard let data = stageResult.summary.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reviewIDStr = dict["review_id"] as? String,
              let reviewID = UUID(uuidString: reviewIDStr) else {
            Issue.record("Failed to parse review_id from stageResult")
            return
        }

        // Commit step
        let commitCall = ToolCall(name: "commit_calendar_event", arguments: ["review_id": .string(reviewID.uuidString)])
        let commitReason = try #require(try tools.reviewReason(commitCall))
        #expect(commitReason.contains("Conf Room 4"))
        try tools.prepareReview(commitCall)
        try tools.authorize(commitCall)
        let commitResult = try await tools.execute(commitCall)
        #expect(commitResult.verified)
        #expect(await fake.storedCount() == 1)

        // Rollback step
        let rollbackCall = ToolCall(name: "rollback_calendar_event", arguments: ["review_id": .string(reviewID.uuidString)])
        let rollbackReason = try #require(try tools.reviewReason(rollbackCall))
        #expect(rollbackReason.contains("Safely delete/rollback"))
        await #expect(throws: CalendarWriteFailure.reviewNotDisplayed) {
            try await tools.execute(rollbackCall)
        }
        #expect(await fake.storedCount() == 1)
        _ = try tools.reviewReason(rollbackCall)
        try tools.prepareReview(rollbackCall)
        try tools.authorize(rollbackCall)
        let rollbackResult = try await tools.execute(rollbackCall)
        #expect(rollbackResult.verified)
        #expect(await fake.storedCount() == 0)
        await #expect(throws: CalendarWriteFailure.reviewNotDisplayed) {
            try await tools.execute(rollbackCall)
        }
    }
}
