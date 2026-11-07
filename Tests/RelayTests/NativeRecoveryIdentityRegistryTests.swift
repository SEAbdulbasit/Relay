import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// AX application proxies are created in memory as equality-test objects. No AX
/// queries, process launches or permissions are used by these bookkeeping tests.
@MainActor
struct NativeRecoveryIdentityRegistryTests {
    private func target(launch: TimeInterval = 1) -> DesktopApplicationIdentity {
        DesktopApplicationIdentity(processID: 74_001, launchedAt: Date(timeIntervalSince1970: launch),
            bundleID: "org.example.inert-registry", bundleURL: URL(fileURLWithPath: "/inert/Fixture.app"))
    }

    @Test func exactObjectsAndDocumentAreRequiredWhileNewProxyWrappersCanMatch() throws {
        let registry = NativeRecoveryIdentityRegistry()
        let first = AXUIElementCreateApplication(74_001)
        let equalProxy = AXUIElementCreateApplication(74_001)
        let other = AXUIElementCreateApplication(74_002)
        let one = try #require(registry.registerWindow(target: target(), window: first, documentFingerprint: "doc-a", browser: nil))
        #expect(registry.registerWindow(target: target(), window: equalProxy, documentFingerprint: "doc-a", browser: nil) == one)
        #expect(registry.registerWindow(target: target(), window: other, documentFingerprint: "doc-a", browser: nil) != one)
        #expect(registry.registerWindow(target: target(), window: first, documentFingerprint: "doc-b", browser: nil) != one)
        #expect(registry.registerWindow(target: target(launch: 2), window: first, documentFingerprint: "doc-a", browser: nil) != one)
        let control = try #require(registry.registerControl(element: first, in: one, identityFingerprint: "same-label-and-role"))
        #expect(registry.registerControl(element: equalProxy, in: one, identityFingerprint: "same-label-and-role") == control)
        #expect(registry.registerControl(element: other, in: one, identityFingerprint: "same-label-and-role") != control,
            "A label/path/hash match cannot substitute for CFEqual.")
    }

    @Test func evictionCannotReuseAnOldSoftwareIdentity() throws {
        let registry = NativeRecoveryIdentityRegistry(maximumWindows: 1, maximumControls: 1)
        let first = AXUIElementCreateApplication(74_001)
        let other = AXUIElementCreateApplication(74_002)
        let one = try #require(registry.registerWindow(target: target(), window: first, documentFingerprint: "a", browser: nil))
        let control = try #require(registry.registerControl(element: first, in: one, identityFingerprint: "field"))
        _ = try #require(registry.registerWindow(target: target(), window: other, documentFingerprint: "b", browser: nil))
        #expect(!registry.contains(one) && !registry.contains(control))
        #expect(registry.registerControl(element: first, in: one, identityFingerprint: "field") == nil)
        let replacement = try #require(registry.registerWindow(target: target(), window: first, documentFingerprint: "a", browser: nil))
        #expect(replacement != one)
        registry.removeAll()
        #expect(!registry.contains(replacement))
    }

    @Test func aBrowserWindowWithoutExactCapturedDocumentProofRemainsUnbound() {
        let registry = NativeRecoveryIdentityRegistry()
        let browser = DesktopApplicationIdentity(processID: 74_001, launchedAt: Date(timeIntervalSince1970: 1),
            bundleID: "com.google.Chrome", bundleURL: URL(fileURLWithPath: "/inert/Chrome.app"))
        #expect(registry.registerWindow(target: browser, window: AXUIElementCreateApplication(74_001),
            documentFingerprint: "same-window-title", browser: nil) == nil)
    }
}
