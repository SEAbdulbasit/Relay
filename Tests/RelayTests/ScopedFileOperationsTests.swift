import Foundation
import Darwin
import Testing
@testable import Relay

@MainActor
struct ScopedFileOperationsTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-file-ops-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func directory(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func recursiveSearchReturnsOnlyVisibleSelectedRegularFilesAndNeverFollowsLinks() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = try directory(root, "allowed"), nested = try directory(allowed, "nested"), outside = try directory(root, "outside")
        let found = nested.appendingPathComponent("My SF.webm")
        try Data("selected".utf8).write(to: found)
        try Data("hidden".utf8).write(to: allowed.appendingPathComponent(".sf.webm"))
        let hidden = try directory(allowed, ".private")
        try Data("hidden".utf8).write(to: hidden.appendingPathComponent("sf.webm"))
        let secret = outside.appendingPathComponent("outside-sf.webm")
        try Data("outside".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("escape-dir"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("escape-sf.webm"), withDestinationURL: secret)
        let result = try await ScopedFileOperations.search(query: "sf.webm", grants: [ScopeGrant(path: allowed.path)])
        #expect(result.matches.count == 1, "visited=\(result.visitedEntries) symlinks=\(result.skippedSymlinks) truncated=\(result.truncated) warnings=\(result.warnings)")
        #expect(result.matches.first?.path == (try ToolPolicy.canonicalURL(found.path).path))
        #expect(result.matches.first?.bytes == 8)
        #expect(result.skippedSymlinks == 2)
        #expect(!result.matches.contains { $0.path.contains("outside") || $0.name.hasPrefix(".") })
        #expect(try Data(contentsOf: secret) == Data("outside".utf8))
    }

    @Test func searchHasOutputDepthAndLiteralQueryBounds() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<100 {
            try Data().write(to: root.appendingPathComponent("needle-\(index)-" + String(repeating: "a", count: 120) + ".txt"))
        }
        let result = try await ScopedFileOperations.search(query: "needle", grants: [ScopeGrant(path: root.path)])
        #expect(result.truncated)
        #expect(result.matches.count < 100)
        #expect(result.matches.reduce(0) { $0 + $1.path.utf8.count + $1.name.utf8.count + 96 } <= 9000)
        #expect(result.visitedEntries <= 5000)
        var deep = root
        for index in 0..<10 { deep = try directory(deep, "level-\(index)") }
        try Data().write(to: deep.appendingPathComponent("deep-marker.txt"))
        let bounded = try await ScopedFileOperations.search(query: "deep-marker", grants: [ScopeGrant(path: root.path)])
        #expect(bounded.matches.isEmpty)
        #expect(bounded.truncated)
        for query in ["", "  ", "path/name", "name\nother", String(repeating: "é", count: 129)] {
            #expect(throws: (any Error).self) { try ScopedFileOperations.validatedQuery(query) }
        }
    }

    @Test func selectedSingleFileCanBeFoundWithoutGrantingItsSibling() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.txt")
        try Data("selected".utf8).write(to: selected)
        try Data("other".utf8).write(to: root.appendingPathComponent("selected-other.txt"))
        let result = try await ScopedFileOperations.search(query: "selected", grants: [ScopeGrant(path: selected.path)])
        #expect(result.matches.count == 1)
        #expect(result.matches[0].name == "selected.txt")
    }

    @Test func preparedMovePreservesBytesAndIdentityAndCanBeReversedWithNewPreview() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = try directory(root, "from"), to = try directory(root, "to")
        let source = from.appendingPathComponent("original.txt"), destination = to.appendingPathComponent("renamed.txt")
        let bytes = Data((0..<8000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let grants = [ScopeGrant(path: from.path, writable: true), ScopeGrant(path: to.path, writable: true)]
        let preview = try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants)
        #expect(preview.reviewText.contains("No overwrite"))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let moved = try await ScopedFileOperations.executeMove(preview, grants: grants)
        #expect(moved.verified)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == bytes)
        let reverse = try await ScopedFileOperations.prepareMove(source: destination.path, destination: source.path, grants: grants)
        #expect(reverse.sourceIdentity.inode == preview.sourceIdentity.inode)
        #expect(reverse.contentSHA256 == preview.contentSHA256)
        #expect(try await ScopedFileOperations.executeMove(reverse, grants: grants).verified)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func moveNeverOverwritesEvenWhenDestinationAppearsAfterPreview() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), destination = root.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)
        let grants = [ScopeGrant(path: root.path, writable: true)]
        let preview = try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants)
        try Data("do not overwrite".utf8).write(to: destination)
        await #expect(throws: (any Error).self) { try await ScopedFileOperations.executeMove(preview, grants: grants) }
        await #expect(throws: (any Error).self) { try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "do not overwrite")
    }

    @Test func moveRequiresBothWritableScopesAndRejectsTraversal() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = try directory(root, "allowed"), outside = try directory(root, "outside")
        let source = allowed.appendingPathComponent("source.txt"), destination = outside.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)
        for grants in [[ScopeGrant(path: allowed.path), ScopeGrant(path: outside.path, writable: true)], [ScopeGrant(path: allowed.path, writable: true), ScopeGrant(path: outside.path)], [ScopeGrant(path: allowed.path, writable: true)]] {
            await #expect(throws: (any Error).self) { try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants) }
        }
        await #expect(throws: (any Error).self) {
            try await ScopedFileOperations.prepareMove(source: source.path, destination: allowed.appendingPathComponent("../outside/escape.txt").path, grants: [ScopeGrant(path: allowed.path, writable: true)])
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func changedSourceAndGrantDriftInvalidatePreparedMove() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), destination = root.appendingPathComponent("destination.txt")
        try Data("before".utf8).write(to: source)
        let grants = [ScopeGrant(path: root.path, writable: true)]
        let original = try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants)
        try Data("after!".utf8).write(to: source)
        await #expect(throws: (any Error).self) { try await ScopedFileOperations.executeMove(original, grants: grants) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let fresh = try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants)
        var revoked = grants
        revoked[0].writable = false
        await #expect(throws: (any Error).self) { try await ScopedFileOperations.executeMove(fresh, grants: revoked) }
        let regenerated = [ScopeGrant(path: root.path, writable: true)]
        await #expect(throws: (any Error).self) { try await ScopedFileOperations.executeMove(fresh, grants: regenerated) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "after!")
    }

    @Test func symlinksHardlinksDirectoriesAndChangedParentCannotMove() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), alias = root.appendingPathComponent("alias.txt")
        try Data("source".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let grants = [ScopeGrant(path: root.path, writable: true)]
        let destinationParent = try directory(root, "destination")
        let destination = destinationParent.appendingPathComponent("new.txt")
        await #expect(throws: (any Error).self) { try await ScopedFileOperations.prepareMove(source: alias.path, destination: destination.path, grants: grants) }
        await #expect(throws: (any Error).self) { try await ScopedFileOperations.prepareMove(source: destinationParent.path, destination: root.appendingPathComponent("other-folder").path, grants: grants) }
        let hardlink = root.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: source, to: hardlink)
        await #expect(throws: (any Error).self) { try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants) }
        try FileManager.default.removeItem(at: hardlink)
        let preview = try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants)
        try FileManager.default.moveItem(at: destinationParent, to: root.appendingPathComponent("old-destination", isDirectory: true))
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await ScopedFileOperations.executeMove(preview, grants: grants) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancelledMoveCannotDispatch() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), destination = root.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)
        let grants = [ScopeGrant(path: root.path, writable: true)]
        let preview = try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants)
        let task = Task { @MainActor in try await ScopedFileOperations.executeMove(preview, grants: grants) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled move returned success") } catch is CancellationError {}
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    @Test func namedPipeIsRejectedWithoutWaitingForAWriter() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: (any Error).self) {
            try await ScopedFileOperations.prepareMove(source: fifo.path, destination: root.appendingPathComponent("renamed").path, grants: [ScopeGrant(path: root.path, writable: true)])
        }
        #expect(FileManager.default.fileExists(atPath: fifo.path))
    }

    @Test func visibleAliasCannotMoveIntoHiddenCanonicalFolder() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = try directory(root, ".hidden")
        let source = hidden.appendingPathComponent("source.txt")
        try Data("private".utf8).write(to: source)
        let alias = root.appendingPathComponent("visible-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: hidden)
        let grants = [ScopeGrant(path: root.path, writable: true)]
        await #expect(throws: (any Error).self) {
            try await ScopedFileOperations.prepareMove(source: alias.appendingPathComponent("source.txt").path,
                destination: root.appendingPathComponent("moved.txt").path, grants: grants)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func fileOnlyGrantDoesNotAuthorizeParentNamespaceRename() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = try directory(root, "source"), destinationFolder = try directory(root, "destination")
        let source = sourceFolder.appendingPathComponent("selected.txt")
        try Data("selected".utf8).write(to: source)
        await #expect(throws: (any Error).self) {
            try await ScopedFileOperations.prepareMove(source: source.path, destination: destinationFolder.appendingPathComponent("renamed.txt").path,
                grants: [ScopeGrant(path: source.path, writable: true), ScopeGrant(path: destinationFolder.path, writable: true)])
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func liveAuthorizationGateAfterHashBlocksRenameWithoutChangingEitherPath() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), destination = root.appendingPathComponent("destination.txt")
        let original = Data("Keep this exact source unchanged.".utf8)
        try original.write(to: source)
        let grants = [ScopeGrant(path: root.path, writable: true)]
        let preview = try await ScopedFileOperations.prepareMove(source: source.path, destination: destination.path, grants: grants)
        var checks = 0
        await #expect(throws: (any Error).self) {
            try await ScopedFileOperations.executeMove(preview, grants: grants, isStillAuthorized: {
                checks += 1
                return false
            })
        }
        #expect(checks == 1)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func datalessPlaceholderFlagsAreRefusedWithoutOpeningCloudContent() throws {
        try ScopedFileOperations.validateMaterializedFlags(0)
        try ScopedFileOperations.validateMaterializedFlags(UInt32(UF_NODUMP))
        for flags in [UInt32(SF_DATALESS), UInt32(SF_DATALESS) | UInt32(UF_NODUMP)] {
            do {
                try ScopedFileOperations.validateMaterializedFlags(flags)
                Issue.record("Dataless placeholder flags were accepted")
            } catch {
                #expect(error.localizedDescription.contains("Offline move refused"))
                #expect(error.localizedDescription.contains("will not request a download"))
            }
        }
        // Synthetic flags only. This test does not create or read a real provider placeholder.
    }

    @Test func writableScopeCannotAuthorizeLaunchConfigurationOrApplicationDataMoves() throws {
        for path in [NSHomeDirectory() + "/Library/LaunchAgents/example.plist", "/Library/LaunchDaemons/example.plist", "/System/example.txt", "/private/etc/example.txt", "/etc/example.txt", "/private/var/db/example.txt", "/var/db/example.txt", "/library/LaunchDaemons/example.plist", "/Applications/Example.app/Contents/Info.plist", "/tmp/Example.app/Contents/resource.txt"] {
            #expect(throws: (any Error).self, "Move exclusion must reject \(path)") { try ScopedFileOperations.validateOrdinaryMoveLocation(URL(fileURLWithPath: path)) }
        }
        try ScopedFileOperations.validateOrdinaryMoveLocation(URL(fileURLWithPath: "/tmp/LibraryNotes/example.txt"))
        try ScopedFileOperations.validateOrdinaryMoveLocation(URL(fileURLWithPath: "/tmp/example.plist"))
    }
    @Test func visibleSystemAliasCannotBypassOrdinaryLocationExclusion() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("visible-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: "/Library", isDirectory: true))
        #expect(throws: (any Error).self) {
            try ScopedFileOperations.validateOrdinaryMoveLocation(alias.appendingPathComponent("LaunchAgents/nonexistent-fixture.plist"))
        }
        #expect(throws: (any Error).self) {
            try ScopedFileOperations.validateOrdinaryMoveLocation(URL(string: "https://example.com/ordinary.txt")!)
        }
    }

}
