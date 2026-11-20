import XCTest
import Foundation
@testable import Relay

@MainActor
final class KnowledgeVaultValidationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        await awaitParitySuiteQuietWindow()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-vault-val-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testValidationPassesWithRootOverviewAndValidWikilinks() throws {
        let staging = tempDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let readmeContent = """
        # Personal Overview

        Welcome to the knowledge base.
        Refer to [[Projects: Relay]] and [[People: Alice]] for details.
        """
        try readmeContent.write(to: staging.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let projectsDir = staging.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try "# Relay\nDetails on Relay.".write(to: projectsDir.appendingPathComponent("Relay.md"), atomically: true, encoding: .utf8)

        let peopleDir = staging.appendingPathComponent("People", isDirectory: true)
        try FileManager.default.createDirectory(at: peopleDir, withIntermediateDirectories: true)
        try "# Alice\nNotes on Alice.".write(to: peopleDir.appendingPathComponent("Alice.md"), atomically: true, encoding: .utf8)

        let summary = try KnowledgeVaultValidation.validate(staging: staging, verifyWikilinks: true)
        XCTAssertEqual(summary.files, 3)
        XCTAssertEqual(summary.wikilinksChecked, 2)
        XCTAssertFalse(summary.fingerprint.isEmpty)
    }

    func testValidationFailsWhenMissingRootOverview() throws {
        let staging = tempDir.appendingPathComponent("staging-no-readme", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "# Note\nSome note.".write(to: staging.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try KnowledgeVaultValidation.validate(staging: staging)) { error in
            XCTAssertEqual(error as? KnowledgeVaultValidation.Failure, .missingIndex)
        }
    }

    func testValidationFailsOnDanglingWikilink() throws {
        let staging = tempDir.appendingPathComponent("staging-dangling", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let readme = """
        # Root Overview
        Links to [[MissingNote]] which does not exist!
        """
        try readme.write(to: staging.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try KnowledgeVaultValidation.validate(staging: staging, verifyWikilinks: true)) { error in
            if case .danglingWikilink(let target) = (error as? KnowledgeVaultValidation.Failure) {
                XCTAssertEqual(target, "MissingNote")
            } else {
                XCTFail("Expected danglingWikilink error, got \(error)")
            }
        }
    }

    func testCatastrophicShrinkDetection() throws {
        let original = tempDir.appendingPathComponent("original-vault", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)

        try "# Overview\nLots of knowledge.".write(to: original.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for i in 1...15 {
            let content = "# Note \(i)\n" + String(repeating: "Content line\n", count: 100)
            try content.write(to: original.appendingPathComponent("Note\(i).md"), atomically: true, encoding: .utf8)
        }

        let staging = tempDir.appendingPathComponent("shrunk-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Staging only has README.md (1 file vs 16 files, <20%)
        try "# Overview\nShrunk to almost nothing.".write(to: staging.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try KnowledgeVaultValidation.validate(staging: staging, replacing: original)) { error in
            XCTAssertEqual(error as? KnowledgeVaultValidation.Failure, .catastrophicShrink)
        }
    }
}
