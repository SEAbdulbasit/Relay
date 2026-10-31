import Foundation
import Darwin
import Testing
@testable import Relay

struct ConversationExportWriterTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-export-writer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func stagingFiles(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".relay-private-write-") }
    }

    @Test func unicodeExportIsPrivateBeforeBytesAndVerifiedAfterInstallation() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("محادثة café 🌍.md")
        let data = Data("Private café transcript 🌍\nمرحبا".utf8)
        var inspected = false
        let hooks = ConversationExportWriteHooks(afterPrivateStageCreated: { stage in
            inspected = true
            let attributes = try FileManager.default.attributesOfItem(atPath: stage.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect((attributes[.size] as? NSNumber)?.intValue == 0)
        })
        try ConversationExportWriter.write(data: data, to: target, hooks: hooks)
        #expect(inspected)
        #expect(try LocalStateFile.read(target, maximumBytes: 1_000) == data)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try stagingFiles(root).isEmpty)
    }

    @Test func confirmedRegularReplacementIsAtomicAndPrivateAndEmptyExportWorks() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("conversation.json")
        try Data("original".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try ConversationExportWriter.write(data: Data("replacement".utf8), to: target)
        #expect(try LocalStateFile.read(target, maximumBytes: 100) == Data("replacement".utf8))
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try ConversationExportWriter.write(data: Data(), to: target)
        #expect(try LocalStateFile.read(target, maximumBytes: 0).isEmpty)
        #expect(try stagingFiles(root).isEmpty)
    }

    @Test func symlinkDirectoryAndFifoTargetsAreRefusedWithoutMutation() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try Data("unchanged".utf8).write(to: original)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: ConversationExportWriteError.unsafeDestination) { try ConversationExportWriter.write(data: Data("new".utf8), to: link) }
        #expect(throws: (any Error).self) { try ConversationExportWriter.write(data: Data("new".utf8), to: root) }
        let fifo = root.appendingPathComponent("fifo")
        #expect(fifo.path.withCString { mkfifo($0, mode_t(0o600)) } == 0)
        #expect(throws: ConversationExportWriteError.unsafeDestination) { try ConversationExportWriter.write(data: Data("new".utf8), to: fifo) }
        #expect(try LocalStateFile.read(original, maximumBytes: 100) == Data("unchanged".utf8))
        #expect(try stagingFiles(root).isEmpty)
    }

    @Test func stagingFailurePreservesOriginalAndCleansPrivateTemporaryFile() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("conversation.md")
        try Data("keep original".utf8).write(to: target)
        let hooks = ConversationExportWriteHooks(beforeCommit: { throw RelayError.message("Synthetic stage failure") })
        #expect(throws: ConversationExportWriteError.privateStagingFailed) { try ConversationExportWriter.write(data: Data("private new bytes".utf8), to: target, hooks: hooks) }
        #expect(try LocalStateFile.read(target, maximumBytes: 100) == Data("keep original".utf8))
        #expect(try stagingFiles(root).isEmpty)
    }

    @Test func newCompetingDestinationIsPreservedBeforeCommit() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("conversation.md")
        let hooks = ConversationExportWriteHooks(beforeCommit: { try Data("competing writer".utf8).write(to: target) })
        #expect(throws: ConversationExportWriteError.destinationChanged) { try ConversationExportWriter.write(data: Data("our snapshot".utf8), to: target, hooks: hooks) }
        #expect(try LocalStateFile.read(target, maximumBytes: 100) == Data("competing writer".utf8))
        #expect(try stagingFiles(root).isEmpty)
    }

    @Test func postCommitFailureReportsUncertaintyInsteadOfClaimingNothingWasWritten() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("conversation.md")
        let hooks = ConversationExportWriteHooks(afterCommit: { throw RelayError.message("Synthetic readback failure") })
        #expect(throws: ConversationExportWriteError.outcomeUncertain) { try ConversationExportWriter.write(data: Data("installed snapshot".utf8), to: target, hooks: hooks) }
        #expect(try LocalStateFile.read(target, maximumBytes: 100) == Data("installed snapshot".utf8))
        #expect(ConversationExportWriteError.outcomeUncertain.localizedDescription.contains("may have been written"))
        #expect(try stagingFiles(root).isEmpty)
    }

    @Test func remoteVolumeMetadataIsRefusedWithoutAccessingAnyNetworkMount() throws {
        #expect(throws: ConversationExportWriteError.invalidDestination) { try ConversationExportWriter.validateLocalVolume(flags: 0) }
        try ConversationExportWriter.validateLocalVolume(flags: UInt32(MNT_LOCAL))
    }

    @Test func invalidOrOversizedExportsDoNotCreateDestinationsOrStages() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("conversation.md")
        #expect(throws: ConversationExportWriteError.outputTooLarge) { try ConversationExportWriter.write(data: Data(repeating: 65, count: ConversationExportWriter.maximumBytes + 1), to: target) }
        #expect(throws: ConversationExportWriteError.invalidDestination) { try ConversationExportWriter.write(data: Data(), to: #require(URL(string: "https://example.com/private"))) }
        #expect(throws: ConversationExportWriteError.invalidDestination) { try ConversationExportWriter.write(data: Data(), to: root.appendingPathComponent("missing/target.md")) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try stagingFiles(root).isEmpty)
    }
}
