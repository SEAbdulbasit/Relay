import Foundation
import Testing
@testable import Relay

struct DesktopApplicationTargetTests {
    private func identity(_ pid: Int32, bundleID: String = "com.google.Chrome", path: String = "/Applications/Google Chrome.app", launchedAt: Double = 1) -> DesktopApplicationIdentity {
        .init(processID: pid, launchedAt: Date(timeIntervalSince1970: launchedAt), bundleID: bundleID,
              bundleURL: URL(fileURLWithPath: path))
    }

    @Test func duplicateProfilesRequireTheExactForegroundProcess() {
        let first = identity(100)
        let second = identity(200)
        #expect(DesktopApplicationTarget.select([first, second], foreground: 200) == second)
        #expect(DesktopApplicationTarget.select([first, second], foreground: 100) == first)
        #expect(DesktopApplicationTarget.select([first, second], foreground: nil) == nil)
        #expect(DesktopApplicationTarget.select([first, second], foreground: 300) == nil)
        #expect(DesktopApplicationTarget.select([first], foreground: 300) == first)
    }

    @Test func nameCollisionsAndDifferentApplicationCopiesNeverBecomeProfiles() {
        let first = identity(100)
        #expect(DesktopApplicationTarget.select([first, identity(200, bundleID: "other.application")], foreground: 200) == nil)
        #expect(DesktopApplicationTarget.select([first, identity(200, path: "/tmp/Other Chrome.app")], foreground: 200) == nil)
        #expect(DesktopApplicationTarget.select([first, identity(100, launchedAt: 2)], foreground: 100) == nil)
        #expect(first != identity(100, launchedAt: 2))
    }
}
