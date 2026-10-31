import Foundation
import Darwin
import Testing
@testable import Relay

struct LocalStateFileTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-state-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func regularUTF8AndEmptyFilesReadWithinExactLimits() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        let data = Data("{\"note\":\"café 🌍\"}".utf8)
        try data.write(to: file)
        #expect(try LocalStateFile.read(file, maximumBytes: data.count) == data)
        #expect(try LocalStateFile.read(file, maximumBytes: data.count + 10) == data)
        let empty = root.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(try LocalStateFile.read(empty, maximumBytes: 0).isEmpty)
        #expect(try LocalStateFile.read(empty, maximumBytes: 10).isEmpty)
    }

    @Test func oversizedFilesAndInvalidLimitsAreRefusedBeforeReading() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("data")
        try Data("abcd".utf8).write(to: file)
        #expect(throws: LocalStateFileError.sizeLimitExceeded) { try LocalStateFile.read(file, maximumBytes: 3) }
        #expect(throws: LocalStateFileError.sizeLimitExceeded) { try LocalStateFile.read(file, maximumBytes: 0) }
        for maximum in [-1, LocalStateFile.maximumAllowedBytes + 1, Int.max, Int.min] {
            #expect(throws: LocalStateFileError.invalidLimit) { try LocalStateFile.read(file, maximumBytes: maximum) }
        }
    }

    @Test func finalSymlinkAndDirectoryAreNotFollowedOrRead() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("regular")
        try Data("synthetic".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: LocalStateFileError.notRegularFile) { try LocalStateFile.read(link, maximumBytes: 100) }
        #expect(throws: LocalStateFileError.notRegularFile) { try LocalStateFile.read(root, maximumBytes: 100) }
        #expect(try Data(contentsOf: file) == Data("synthetic".utf8))
    }

    @Test func fifoWithoutWriterIsRejectedWithoutBlocking() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe")
        #expect(fifo.path.withCString { mkfifo($0, mode_t(0o600)) } == 0)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: LocalStateFileError.notRegularFile) { try LocalStateFile.read(fifo, maximumBytes: 100) }
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func nonlocalAndParameterizedURLsAreRefused() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("sample".utf8).write(to: file)
        let invalid = [
            try #require(URL(string: "https://example.com/state.json")),
            try #require(URL(string: "file://remote-server/share/state.json")),
            try #require(URL(string: file.absoluteString + "?token=secret")),
            try #require(URL(string: file.absoluteString + "#fragment")),
            URL(fileURLWithPath: root.path + "/bad\0name")
        ]
        for url in invalid {
            #expect(throws: LocalStateFileError.invalidURL) { try LocalStateFile.read(url, maximumBytes: 100) }
        }
    }

    @Test func literalPercentFilenamesAreAllowedWhileEncodedNulURLsAreRefused() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("synthetic percent-name content".utf8)
        for name in ["literal%00name.txt", "literal%2Fname.txt", "literal%name.txt"] {
            let file = root.appendingPathComponent(name)
            try data.write(to: file)
            #expect(try LocalStateFile.read(file, maximumBytes: 100) == data)
        }
        let nul = try #require(URL(string: root.absoluteString + "/encoded%00name"))
        #expect(nul.path.contains("%00")) // Foundation's legacy .path preserves encoded NUL.
        #expect(nul.path(percentEncoded: false).contains("\0"))
        #expect(throws: LocalStateFileError.invalidURL) { try LocalStateFile.read(nul, maximumBytes: 100) }
    }

    @Test func datalessMetadataIsRejectedWithoutOpeningAnyCloudFile() {
        var metadata = stat()
        metadata.st_mode = mode_t(S_IFREG | 0o600)
        metadata.st_size = 3
        metadata.st_flags = UInt32(SF_DATALESS)
        #expect(throws: LocalStateFileError.datalessFile) { try LocalStateFile.validateMetadata(metadata, maximumBytes: 10) }
        metadata.st_flags = 0
        #expect(throws: Never.self) { try LocalStateFile.validateMetadata(metadata, maximumBytes: 10) }
    }

    @Test func changedIdentitySizeAndNanosecondTimesCannotPassStabilityCheck() throws {
        var original = stat()
        original.st_mode = mode_t(S_IFREG | 0o600)
        original.st_dev = 1
        original.st_ino = 2
        original.st_nlink = 1
        original.st_size = 3
        original.st_mtimespec = timespec(tv_sec: 100, tv_nsec: 200)
        original.st_ctimespec = timespec(tv_sec: 101, tv_nsec: 300)
        try LocalStateFile.validateUnchanged(before: original, after: original)
        var inode = original; inode.st_ino += 1
        var size = original; size.st_size += 1
        var modified = original; modified.st_mtimespec.tv_nsec += 1
        var changed = original; changed.st_ctimespec.tv_nsec += 1
        var links = original; links.st_nlink = 0
        for value in [inode, size, modified, changed, links] {
            #expect(throws: LocalStateFileError.changedDuringRead) { try LocalStateFile.validateUnchanged(before: original, after: value) }
        }
    }
}
