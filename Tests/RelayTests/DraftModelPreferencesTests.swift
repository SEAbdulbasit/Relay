import Foundation
import Testing
@testable import Relay

@MainActor
struct DraftModelPreferencesTests {
    @Test func separateDraftModelPersistsAndInvalidReplacementKeepsTheChoice() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appending(path: "draft.json")
        let package = folder.appending(path: "draft.litertlm")
        try Data([1]).write(to: package)
        let settings = DraftModelPreferences(location: config)
        #expect(settings.model == nil)
        settings.select(package)
        settings.selectBackend("gpu")
        settings.select(folder.appending(path: "wrong.txt"))
        #expect(settings.model?.modelPath == package.path)
        let restored = DraftModelPreferences(location: config)
        #expect(restored.model?.computeBackend == "gpu")
        restored.useChatModel()
        #expect(DraftModelPreferences(location: config).model == nil)
    }
}
