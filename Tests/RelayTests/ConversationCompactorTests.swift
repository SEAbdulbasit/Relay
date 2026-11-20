import XCTest
import Foundation
import CryptoKit
@testable import Relay
@testable import RelayJournal

@MainActor
final class ConversationCompactorTests: XCTestCase {
    private var tempDirectory: URL!
    private var history: AssistantConversationHistory!

    override func setUp() async throws {
        try await super.setUp()
        await awaitParitySuiteQuietWindow()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-compactor-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        history = AssistantConversationHistory(stateURL: tempDirectory.appendingPathComponent("state.json"))
    }

    override func tearDown() async throws {
        if let history {
            try? await history.close()
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    // MARK: - Schema Validation Tests

    func testValidateSummaryAcceptsValidJSON() throws {
        let valid = "{\"summary\": \"User asked for weather. Assistant gave forecast.\"}"
        let extracted = try ConversationCompactor.validateSummary(valid)
        XCTAssertEqual(extracted, "User asked for weather. Assistant gave forecast.")
    }

    func testValidateSummaryRejectsNonJSON() {
        XCTAssertThrowsError(try ConversationCompactor.validateSummary("This is plain text, not JSON")) { error in
            XCTAssertEqual(error as? ConversationCompactor.Failure, .invalidSummary)
        }
    }

    func testValidateSummaryRejectsEmptySummary() {
        let empty = "{\"summary\": \"   \"}"
        XCTAssertThrowsError(try ConversationCompactor.validateSummary(empty)) { error in
            XCTAssertEqual(error as? ConversationCompactor.Failure, .invalidSummary)
        }
    }

    func testValidateSummaryRejectsExtraKeys() {
        let extra = "{\"summary\": \"Valid\", \"extra\": 123}"
        XCTAssertThrowsError(try ConversationCompactor.validateSummary(extra)) { error in
            XCTAssertEqual(error as? ConversationCompactor.Failure, .invalidSummary)
        }
    }

    func testValidateSummaryRejectsOversizedSummary() {
        let huge = "{\"summary\": \"\(String(repeating: "a", count: 10_001))\"}"
        XCTAssertThrowsError(try ConversationCompactor.validateSummary(huge)) { error in
            XCTAssertEqual(error as? ConversationCompactor.Failure, .invalidSummary)
        }
    }

    // MARK: - History Preservation & Compaction Boundary Tests

    func testCompactionBoundaryKeepsRecentTasksAndProtectsUnfinished() async throws {
        // Create 10 completed tasks in history
        for i in 1...10 {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let msg = ChatMessage(id: UUID(), role: "user", text: "Task \(i) request", date: Date(), artifacts: [])
            try history.stage(msg, run: run, grants: [])
            _ = try await history.flush()
            try await history.finish(run, outcome: .success)
        }

        let boundary = history.compactionBoundary(keepingRecentTasks: 5)
        XCTAssertNotNil(boundary)
        // With 10 tasks, keeping 5 recent means boundary should be around task 5's finish sequence
        XCTAssertGreaterThan(boundary ?? 0, 0)

        // Now start an unfinished task 11
        let unfinishedRun = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let unMsg = ChatMessage(id: UUID(), role: "user", text: "Task 11 in-flight", date: Date(), artifacts: [])
        try history.stage(unMsg, run: unfinishedRun, grants: [])
        _ = try await history.flush()

        // Compaction boundary must not cross into unfinished task 11
        let boundaryWithUnfinished = history.compactionBoundary(keepingRecentTasks: 5)
        XCTAssertNotNil(boundaryWithUnfinished)
        XCTAssertEqual(boundary, boundaryWithUnfinished)

        // Verify visible history is preserved: all messages are still present!
        let restored = try await history.restore()
        XCTAssertEqual(restored.messages.count, 11)
    }

    // MARK: - Stale Summary & Reset Rejection Tests

    func testStaleGenerationRejectedAfterReset() async throws {
        let compactor = ConversationCompactor(history: history)

        // Add 8 tasks
        for i in 1...8 {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let msg = ChatMessage(id: UUID(), role: "user", text: "Message \(i)", date: Date(), artifacts: [])
            try history.stage(msg, run: run, grants: [])
            _ = try await history.flush()
            try await history.finish(run, outcome: .success)
        }

        guard let snapshot = try compactor.snapshot() else {
            XCTFail("Expected snapshot")
            return
        }

        // Reset conversation history (clears journal and bumps generation)
        try await history.clear()

        // Attempting to install the snapshot with the old generation must throw staleGeneration
        do {
            try await history.installSummary(
                generation: snapshot.generation,
                fromSequence: snapshot.fromSequence,
                throughSequence: snapshot.throughSequence,
                text: "Old summary",
                expectedFromSequence: snapshot.fromSequence
            )
            XCTFail("Should have thrown staleGeneration")
        } catch let failure as ConversationCompactor.Failure {
            XCTAssertEqual(failure, .staleGeneration)
        }
    }

    func testStaleWatermarkSummaryRejected() async throws {
        // Add 8 tasks
        for i in 1...8 {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let msg = ChatMessage(id: UUID(), role: "user", text: "Task \(i)", date: Date(), artifacts: [])
            try history.stage(msg, run: run, grants: [])
            _ = try await history.flush()
            try await history.finish(run, outcome: .success)
        }

        let opened: AssistantConversationHistory.Opened
        if let current = history.currentOpened {
            opened = current
        } else {
            _ = try await history.restore()
            opened = history.currentOpened!
        }
        let generation = opened.scope.generation
        let boundary = history.compactionBoundary(keepingRecentTasks: 3)!

        // First install a valid summary
        try await history.installSummary(
            generation: generation,
            fromSequence: 1,
            throughSequence: boundary,
            text: "First summary"
        )
        XCTAssertEqual(history.latestSummary?.throughSequence, boundary)

        // Attempting to install a summary with an older or same sequence must throw staleSummary
        do {
            try await history.installSummary(
                generation: generation,
                fromSequence: 1,
                throughSequence: boundary - 1,
                text: "Regressive summary"
            )
            XCTFail("Should have thrown staleSummary")
        } catch let failure as ConversationCompactor.Failure {
            XCTAssertEqual(failure, .staleSummary)
        }
    }

    func testCompactionAfterNewMessageRequiresTheSameCoveredPrefix() async throws {
        let compactor = ConversationCompactor(history: history)
        for index in 1...8 {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(id: UUID(), role: "user", text: "Task \(index)", date: Date(), artifacts: [])
            try history.stage(message, run: run, grants: [])
            _ = try await history.flush()
            try await history.finish(run, outcome: .success)
        }
        let snapshot = try XCTUnwrap(try compactor.snapshot())
        XCTAssertNil(ConversationCompactor.compactionPrompt(
            records: snapshot.records, byteBudget: snapshot.prompt.utf8.count - 1))

        let nextRun = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let nextMessage = ChatMessage(id: UUID(), role: "user", text: "New request", date: Date(), artifacts: [])
        try history.stage(nextMessage, run: nextRun, grants: [])
        _ = try await history.flush()

        do {
            try await history.installSummary(
                generation: snapshot.generation,
                fromSequence: snapshot.fromSequence,
                throughSequence: snapshot.throughSequence,
                text: "Stale summary",
                expectedFromSequence: snapshot.fromSequence,
                expectedThroughDigest: Data()
            )
            XCTFail("A mismatched prefix must invalidate the background snapshot.")
        } catch let failure as ConversationCompactor.Failure {
            XCTAssertEqual(failure, .staleSummary)
        }
        XCTAssertNil(history.latestSummary)
        try await history.installSummary(
            generation: snapshot.generation,
            fromSequence: snapshot.fromSequence,
            throughSequence: snapshot.throughSequence,
            text: "Valid summary",
            expectedFromSequence: snapshot.fromSequence,
            expectedThroughDigest: snapshot.throughDigest
        )
        XCTAssertEqual(history.latestSummary?.throughSequence, snapshot.throughSequence)
        let context = try XCTUnwrap(compactor.localContextExcerpt(
            excluding: [ModelMessage(role: "user", content: "Task 1")], byteBudget: 512))
        XCTAssertTrue(context.contains("Task 2"))
        XCTAssertFalse(context.contains("Task 1"))
        XCTAssertFalse(context.contains("Valid summary"))
        XCTAssertFalse(context.contains("New request"))
        XCTAssertNil(compactor.localContextExcerpt(excluding: [], byteBudget: 20))
        let restored = try await history.restore()
        XCTAssertEqual(restored.messages.count, 9)
    }

    // MARK: - Non-blocking Background Compaction & Cancellation Tests

    func testBackgroundCompactionDoesNotBlockForegroundWork() async throws {
        let compactor = ConversationCompactor(history: history)

        for i in 1...8 {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let msg = ChatMessage(id: UUID(), role: "user", text: "Task \(i)", date: Date(), artifacts: [])
            try history.stage(msg, run: run, grants: [])
            _ = try await history.flush()
            try await history.finish(run, outcome: .success)
        }

        // Start background compaction with a slow summarizer (simulating long inference)
        let slowSummarizer: ConversationCompactor.Summarizer = { _ in
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            return "{\"summary\": \"Completed tasks.\"}"
        }

        compactor.compactInBackground(summarizer: slowSummarizer)
        XCTAssertTrue(compactor.isCompacting)

        // Foreground continues immediately! Can stage and flush new messages without blocking!
        let newRun = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let newMsg = ChatMessage(id: UUID(), role: "user", text: "Urgent foreground query", date: Date(), artifacts: [])
        try history.stage(newMsg, run: newRun, grants: [])
        let flushed = try await history.flush()
        XCTAssertEqual(flushed.count, 1)

        // Foreground cancellation of compactor is immediate
        compactor.cancel()
        XCTAssertFalse(compactor.isCompacting)
        XCTAssertEqual(compactor.lastRejectionReason, .cancelled)

        // History is completely intact
        let restored = try await history.restore()
        XCTAssertTrue(restored.messages.contains(where: { $0.text == "Urgent foreground query" }))
    }

    // MARK: - AssistantStore Compactor Wiring Tests

    func testAssistantStoreCompactorIsWiredAndTriggerableAtTaskBoundary() async throws {
        let store = AssistantStore(conversationHistory: history)
        XCTAssertNotNil(store.compactor)
        XCTAssertFalse(store.compactor.isCompacting)

        // Seed 8 completed tasks in history
        for i in 1...8 {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let msg = ChatMessage(id: UUID(), role: "user", text: "Historical task \(i)", date: Date(), artifacts: [])
            try history.stage(msg, run: run, grants: [])
            _ = try await history.flush()
            try await history.finish(run, outcome: .success)
        }

        // Trigger compaction via store's compactor entry point
        store.compactor.compactInBackground()
        XCTAssertTrue(store.compactor.isCompacting || store.compactor.lastCompactedThrough != nil)

        // Cancel via store's clearConversation
        store.clearConversation()
        XCTAssertFalse(store.compactor.isCompacting)
    }
}
