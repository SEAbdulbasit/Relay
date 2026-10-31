import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Relay

struct ModelDownloadCheckpointTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-checkpoint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func manifest(_ bytes: Data) -> ModelManifest {
        .init(displayName: "Synthetic model", filename: "fixture.litertlm", sourceURL: URL(string: "https://example.com/pinned/model.litertlm")!, size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    private func chunk(_ bytes: Data, in root: URL) throws -> URL {
        let url = root.appendingPathComponent("chunk-" + UUID().uuidString)
        try bytes.write(to: url, options: .withoutOverwriting)
        return url
    }
    private func metadata(in root: URL) throws -> URL {
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasPrefix(".relay-download-checkpoint-") && $0.hasSuffix(".json") })
        return root.appendingPathComponent(name)
    }

    @Test func appendsCommitPrivateCheckpointAndRestorePrefixThenFinishWithoutOverwritingModel() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("abcdef".utf8), pinned = manifest(bytes)
        let first = ModelDownloadCheckpoint()
        let initial = try await first.open(manifest: pinned, directory: root)
        #expect(initial.offset == 0 && initial.etag == nil)
        let chunk1 = try chunk(Data("abc".utf8), in: root)
        let partial = try await first.append(chunkURL: chunk1, expectedOffset: 0, etag: "\"same-entity\"")
        #expect(partial.offset == 3)
        let attrs = try FileManager.default.attributesOfItem(atPath: partial.partialURL.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await first.close()
        let resumed = ModelDownloadCheckpoint()
        let state = try await resumed.open(manifest: pinned, directory: root)
        #expect(state.offset == 3 && state.etag == "\"same-entity\"")
        #expect(state.partialURL == partial.partialURL)
        let chunk2 = try chunk(Data("def".utf8), in: root)
        #expect(try await resumed.append(chunkURL: chunk2, expectedOffset: 3, etag: "\"same-entity\"").offset == 6)
        #expect(try await resumed.fullDigest() == pinned.sha256)
        let final = try await resumed.finalURL()
        #expect(try Data(contentsOf: final) == bytes)
        let model = root.appendingPathComponent(pinned.filename)
        try Data("existing model".utf8).write(to: model)
        #expect(try String(contentsOf: model, encoding: .utf8) == "existing model")
        try await resumed.discardOwned()
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(try String(contentsOf: model, encoding: .utf8) == "existing model")
    }

    @Test func changedPrefixWithRestoredModificationTimeIsNotAppendedOrTruncated() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelDownloadCheckpoint()
        _ = try await store.open(manifest: manifest(Data("abcdef".utf8)), directory: root)
        let first = try chunk(Data("abc".utf8), in: root)
        let state = try await store.append(chunkURL: first, expectedOffset: 0, etag: "\"v1\"")
        var before = stat()
        #expect(lstat(state.partialURL.path, &before) == 0)
        let handle = try FileHandle(forWritingTo: state.partialURL)
        try handle.write(contentsOf: Data("xyz".utf8)); try handle.synchronize(); try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, state.partialURL.path, &times, 0) == 0)
        var after = stat()
        #expect(lstat(state.partialURL.path, &after) == 0)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
        let second = try chunk(Data("def".utf8), in: root)
        await #expect(throws: (any Error).self) { try await store.append(chunkURL: second, expectedOffset: 3, etag: "\"v1\"") }
        #expect(try Data(contentsOf: state.partialURL) == Data("xyz".utf8))
        try await store.close()
    }

    @Test func wrongOffsetChangedETagAndOversizedChunksDoNotChangeCommittedPrefix() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelDownloadCheckpoint(), bytes = Data("abcdef".utf8)
        _ = try await store.open(manifest: manifest(bytes), directory: root)
        let input = try chunk(Data("abc".utf8), in: root)
        let state = try await store.append(chunkURL: input, expectedOffset: 0, etag: "\"v1\"")
        for (offset, tag) in [(Int64(0), "\"v1\""), (Int64(3), "\"v2\""), (Int64(3), "W/\"v1\"")] {
            await #expect(throws: (any Error).self) { try await store.append(chunkURL: input, expectedOffset: offset, etag: tag) }
        }
        let tooLarge = try chunk(Data(repeating: 0, count: 33_554_433), in: root)
        await #expect(throws: (any Error).self) { try await store.append(chunkURL: tooLarge, expectedOffset: 3, etag: "\"v1\"") }
        #expect(try Data(contentsOf: state.partialURL) == Data("abc".utf8))
        try await store.discardOwned()
    }

    @Test func corruptPrefixAndMetadataArePreservedAndNeverResumed() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pinned = manifest(Data("abcdef".utf8)), original = ModelDownloadCheckpoint()
        _ = try await original.open(manifest: pinned, directory: root)
        let input = try chunk(Data("abc".utf8), in: root)
        let before = try await original.append(chunkURL: input, expectedOffset: 0, etag: "\"v1\"")
        try await original.close()
        try Data("bad".utf8).write(to: before.partialURL)
        let resumed = ModelDownloadCheckpoint()
        let fresh = try await resumed.open(manifest: pinned, directory: root)
        #expect(fresh.offset == 0 && fresh.partialURL != before.partialURL)
        #expect(try String(contentsOf: before.partialURL, encoding: .utf8) == "bad")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".relay-download-invalid-") })
        try await resumed.discardOwned()
    }

    @Test func forgedTraversalMetadataCannotReadOrDeleteAnOutsideFile() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("relay-unselected-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside untouched".utf8).write(to: outside)
        let pinned = manifest(Data("abc".utf8)), first = ModelDownloadCheckpoint()
        _ = try await first.open(manifest: pinned, directory: root)
        try await first.close()
        let record = try metadata(in: root)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        json["partialLeaf"] = "../" + outside.lastPathComponent
        try JSONSerialization.data(withJSONObject: json).write(to: record)
        let resumed = ModelDownloadCheckpoint()
        #expect(try await resumed.open(manifest: pinned, directory: root).offset == 0)
        try await resumed.discardOwned()
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside untouched")
    }

    @Test func exclusiveLockAndCancellationProtectPartialState() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pinned = manifest(Data(repeating: 7, count: 4_194_304)), first = ModelDownloadCheckpoint(), second = ModelDownloadCheckpoint()
        let state = try await first.open(manifest: pinned, directory: root)
        await #expect(throws: (any Error).self) { try await second.open(manifest: pinned, directory: root) }
        let input = try chunk(Data(repeating: 7, count: 4_194_304), in: root)
        let task = Task { try await first.append(chunkURL: input, expectedOffset: 0, etag: "\"v1\"") }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled append committed") } catch is CancellationError {}
        #expect(try Data(contentsOf: state.partialURL).isEmpty)
        try await first.close()
        #expect(try await second.open(manifest: pinned, directory: root).offset == 0)
        try await second.discardOwned()
    }

    @Test func strongETagSyntaxAndManifestURLRestrictionsAreExplicit() async throws {
        #expect(ModelDownloadCheckpoint.isStrongETag("\"v1\""))
        for value in ["W/\"v1\"", "v1", "\"bad tag\"", "\"bad\n\"", "\"embedded\"quote\""] { #expect(!ModelDownloadCheckpoint.isStrongETag(value)) }
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pinned = manifest(Data("abc".utf8))
        let signed = ModelManifest(displayName: pinned.displayName, filename: pinned.filename, sourceURL: URL(string: "https://example.com/model?signature=secret")!, size: pinned.size, sha256: pinned.sha256)
        let store = ModelDownloadCheckpoint()
        await #expect(throws: (any Error).self) { try await store.open(manifest: signed, directory: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test func replacedPartialSymlinkNeverReadsOrDiscardsOutsideData() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("relay-checkpoint-outside-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("unselected bytes".utf8).write(to: outside)
        let pinned = manifest(Data("abcdef".utf8)), first = ModelDownloadCheckpoint()
        let old = try await first.open(manifest: pinned, directory: root)
        try await first.close()
        try FileManager.default.removeItem(at: old.partialURL)
        try FileManager.default.createSymbolicLink(at: old.partialURL, withDestinationURL: outside)
        let resumed = ModelDownloadCheckpoint()
        let state = try await resumed.open(manifest: pinned, directory: root)
        #expect(state.offset == 0 && state.partialURL != old.partialURL)
        try await resumed.discardOwned()
        #expect(try String(contentsOf: outside, encoding: .utf8) == "unselected bytes")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: old.partialURL.path) == outside.path)
    }

    @Test func restoresHighestValidPrefixAndRetiresFiveSupersededRecordsWithoutTouchingUnknownPartial() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("abcdef".utf8), pinned = manifest(bytes), first = ModelDownloadCheckpoint()
        _ = try await first.open(manifest: pinned, directory: root)
        let input = try chunk(bytes, in: root)
        let original = try await first.append(chunkURL: input, expectedOffset: 0, etag: "\"v1\"")
        try await first.close()
        let active = try metadata(in: root)
        let base = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: active)) as? [String: Any])
        var staleFiles: [URL] = []
        for count in 1...5 {
            var record = base
            record["offset"] = count
            record["prefixSHA256"] = SHA256.hash(data: bytes.prefix(count)).map { String(format: "%02x", $0) }.joined()
            let file = root.appendingPathComponent(".relay-download-checkpoint-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: record).write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            staleFiles.append(file)
        }
        let unknown = root.appendingPathComponent(".relay-download-\(UUID().uuidString).partial")
        let unknownBytes = Data("unknown preserved bytes".utf8)
        try unknownBytes.write(to: unknown, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unknown.path)
        // A different manifest must not authorize deleting its referenced partial.
        var foreignRecord = base
        foreignRecord["sourceURL"] = "https://example.com/another-model.litertlm"
        foreignRecord["partialLeaf"] = unknown.lastPathComponent
        let foreignMetadata = root.appendingPathComponent(".relay-download-checkpoint-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: foreignRecord).write(to: foreignMetadata, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foreignMetadata.path)
        let resumed = ModelDownloadCheckpoint()
        let restored = try await resumed.open(manifest: pinned, directory: root)
        #expect(restored.offset == 6 && restored.partialURL == original.partialURL)
        #expect(try await resumed.fullDigest() == pinned.sha256)
        let leaves = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leaves.filter { $0.hasPrefix(".relay-download-checkpoint-") }.count == 1)
        #expect(leaves.filter { $0.hasPrefix(".relay-download-retired-") }.count == 5)
        #expect(staleFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: unknown) == unknownBytes)
        try await resumed.discardOwned()
        #expect(try Data(contentsOf: unknown) == unknownBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".relay-download-retired-") }.count == 5)
    }

}
