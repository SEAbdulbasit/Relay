import Foundation
import Testing
@testable import Relay

@MainActor
struct ApplicationDiscoveryTests {
    private func app(_ name: String, id: String, path: String) -> MacTools.InstalledApplication {
        .init(url: URL(fileURLWithPath: path), bundleID: id, displayName: name, names: [name, URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent])
    }

    @Test func displayNameAndFilenameResolveTheSameInstalledApp() throws {
        let memos = app("Voice Memos", id: "com.apple.VoiceMemos", path: "/System/Applications/VoiceMemos.app")
        for query in ["  VOICE   memos ", "VoiceMemos.app", "com.apple.VoiceMemos"] {
            #expect(try MacTools.matchingInstalledApplication(query, in: [memos])?.bundleID == memos.bundleID)
        }
        #expect(try MacTools.matchingInstalledApplication("Voice Recorder Pro", in: [memos]) == nil)
    }

    @Test func ambiguousInstalledNamesRequireAChoice() throws {
        let first = app("Recorder", id: "example.one", path: "/Applications/Recorder.app")
        let second = app("Recorder", id: "example.two", path: "/Users/test/Applications/Recorder.app")
        #expect(throws: (any Error).self) { try MacTools.matchingInstalledApplication("Recorder", in: [first, second]) }
        #expect(try MacTools.matchingInstalledApplication("example.two", in: [first, second])?.url == second.url)
    }

    @Test func duplicateDiscoveryRecordsDoNotCreateFalseAmbiguity() throws {
        let app = app("TextEdit", id: "com.apple.TextEdit", path: "/System/Applications/TextEdit.app")
        #expect(try MacTools.matchingInstalledApplication("TextEdit", in: [app, app])?.url == app.url)
    }
}
