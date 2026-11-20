import XCTest
import Foundation
@testable import Relay

@MainActor
final class SidekickInstructionStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var memoryURL: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        await awaitParitySuiteQuietWindow()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-instruction-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        memoryURL = tempDirectory.appendingPathComponent("RelayMemory.md")
        defaultsSuite = "relay.test.instructions." + UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsSuite)!
    }

    override func tearDown() async throws {
        SidekickInstructionStore.endTeardown()
        defaults.removePersistentDomain(forName: defaultsSuite)
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    func testInitialReadMigratesFromDefaultsOrCreatesEmpty() throws {
        defaults.set("Default instructions", forKey: RelayInstructionStore.memoryDefaultsKey)
        let snapshot = try SidekickInstructionStore.read(defaults: defaults, memoryURL: memoryURL)
        XCTAssertEqual(snapshot.text, "Default instructions")
        XCTAssertFalse(snapshot.revision.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryURL.path))
    }

    func testAtomicWriteAndConflictDetection() throws {
        // Initial write
        let first = try SidekickInstructionStore.write("Initial instructions", defaults: defaults, memoryURL: memoryURL)
        XCTAssertEqual(first.text, "Initial instructions")

        // Concurrent update (simulated user edit in Settings)
        try SidekickInstructionStore.saveUserEdit("User changed instructions", defaults: defaults, memoryURL: memoryURL)

        // Agent attempts write using stale first.revision -> must throw Failure.stale!
        XCTAssertThrowsError(
            try SidekickInstructionStore.write("Agent update", expectedRevision: first.revision, defaults: defaults, memoryURL: memoryURL)
        ) { error in
            XCTAssertEqual(error as? SidekickInstructionStore.Failure, .stale)
        }

        // Reading again gives updated revision
        let refreshed = try SidekickInstructionStore.read(defaults: defaults, memoryURL: memoryURL)
        XCTAssertEqual(refreshed.text, "User changed instructions")

        // Agent now updates with valid expected revision -> succeeds
        let updated = try SidekickInstructionStore.write(
            "Agent update",
            expectedRevision: refreshed.revision,
            defaults: defaults,
            memoryURL: memoryURL
        )
        XCTAssertEqual(updated.text, "Agent update")
        XCTAssertEqual(try String(contentsOf: memoryURL, encoding: .utf8), "Agent update")
    }

    func testUnicodeNormalizationByteAccuracy() throws {
        let composed = "Café\n"
        let decomposed = "Cafe\u{0301}\n"

        let snap1 = try SidekickInstructionStore.write(composed, defaults: defaults, memoryURL: memoryURL)
        // Revision is SHA256 of UTF8 bytes, so composed and decomposed have different hashes
        let snap2 = try SidekickInstructionStore.write(decomposed, expectedRevision: snap1.revision, defaults: defaults, memoryURL: memoryURL)
        XCTAssertNotEqual(snap1.revision, snap2.revision)
    }

    func testTeardownPreventsAccess() throws {
        SidekickInstructionStore.beginTeardown()
        defer { SidekickInstructionStore.endTeardown() }

        XCTAssertThrowsError(try SidekickInstructionStore.read(defaults: defaults, memoryURL: memoryURL)) { error in
            XCTAssertEqual(error as? SidekickInstructionStore.Failure, .unavailable)
        }
        XCTAssertThrowsError(try SidekickInstructionStore.write("Test", defaults: defaults, memoryURL: memoryURL)) { error in
            XCTAssertEqual(error as? SidekickInstructionStore.Failure, .unavailable)
        }
    }

    func testSnapshotWithReadError() {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/invalid/directory/memory.md")
        let snap = SidekickInstructionStore.snapshot(defaults: defaults, memoryURL: invalidURL)
        XCTAssertTrue(snap.promptBlock.contains("RELAY MEMORY UNAVAILABLE"))
    }
}
