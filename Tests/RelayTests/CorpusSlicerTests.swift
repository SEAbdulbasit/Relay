import XCTest
import Foundation
@testable import Relay

@MainActor
final class CorpusSlicerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        await awaitParitySuiteQuietWindow()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-corpus-slicer-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testSliceRespectsItemBoundariesAndByteBudget() {
        var items: [CorpusItem] = []
        for i in 1...10 {
            // Each item has ~200 bytes
            let item = CorpusItem(
                id: "item-\(i)",
                title: "Title \(i)",
                text: "Body text content for item number \(i). " + String(repeating: "x", count: 120),
                itemDate: Date(),
                sourceID: "src-1"
            )
            items.append(item)
        }

        // Set budget to ~500 bytes: each slice will hold ~2 items without splitting
        let slices = CorpusSlicer.slice(items, budget: 500, maximumItems: 50)
        XCTAssertGreaterThan(slices.count, 1)

        // Flattened items must match original order and elements
        let flattened = slices.flatMap { $0 }
        XCTAssertEqual(flattened, items)

        // Verify each slice doesn't cross the budget unless a single item alone exceeded it
        let df = CorpusSlicer.dateFormatter()
        for slice in slices {
            if slice.count > 1 {
                let totalBytes = slice.enumerated().reduce(0) { sum, pair in
                    sum + CorpusSlicer.render(pair.element, index: pair.offset, df: df).utf8.count + 2
                }
                XCTAssertLessThanOrEqual(totalBytes, 600) // generous upper bound
            }
        }
    }

    func testSliceRespectsMaximumItems() {
        var items: [CorpusItem] = []
        for i in 1...20 {
            let item = CorpusItem(id: "item-\(i)", title: "T\(i)", text: "Short")
            items.append(item)
        }

        // Large budget, but maximumItems = 5
        let slices = CorpusSlicer.slice(items, budget: 100_000, maximumItems: 5)
        XCTAssertEqual(slices.count, 4)
        for slice in slices {
            XCTAssertEqual(slice.count, 5)
        }
    }

    func testStagingSnapshotSaveLoadAndDelete() throws {
        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let items = [
            CorpusItem(id: "1", title: "Note 1", text: "Alpha"),
            CorpusItem(id: "2", title: "Note 2", text: "Beta")
        ]

        try CorpusSlicer.saveCorpus(items, in: stagingDir)

        let loaded = CorpusSlicer.loadCorpus(from: stagingDir)
        XCTAssertEqual(loaded, items)

        CorpusSlicer.deleteCorpus(in: stagingDir)
        XCTAssertNil(CorpusSlicer.loadCorpus(from: stagingDir))
    }

    func testVaultSliceCheckpointRestoreAndDiscard() throws {
        let stagingDir = tempDir.appendingPathComponent("staging-chk", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let fileA = stagingDir.appendingPathComponent("A.txt")
        try "Original content".write(to: fileA, atomically: true, encoding: .utf8)

        // Create checkpoint
        let checkpoint = try VaultSliceCheckpoint(staging: stagingDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.backup.path))

        // Modify staging (simulating a failed or interrupted slice update)
        try "Corrupted partial batch".write(to: fileA, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "Corrupted partial batch")

        // Restore checkpoint
        try checkpoint.restore()
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "Original content")

        // Discard backup
        checkpoint.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.backup.path))
    }
}
