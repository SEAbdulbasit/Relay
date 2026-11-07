import Foundation
import Testing
@testable import Relay

@MainActor
struct NativeLocalTaskReadAuthorityTests {
    @Test func ordinaryLocalInvocationCanResolveMultipleAppsWithoutAModelMintedGrant() throws {
        let first = identity(1, "test.first"), second = identity(2, "test.second")
        var current = true, resolved: [String] = []
        let authority = NativeLocalTaskReadAuthority.localUserInvocation(taskID: UUID(), taskIsCurrent: { current },
            resolve: { requested in
                resolved.append(requested)
                guard let selected = [first, second].first(where: { $0.bundleID == requested }) else {
                    throw NativeWindowTaskAdapter.Failure.unadmittedApplication
                }
                return .init(application: selected, validate: {})
            })
        let original = try authority.admit(first.bundleID)
        #expect(original.application == first)
        #expect(try authority.admit(second.bundleID).application == second)
        #expect(resolved == [first.bundleID, second.bundleID])
        current = false
        #expect(throws: (any Error).self) { try original.validate() }
        #expect(throws: (any Error).self) { try authority.admit("test.other") }
        #expect(resolved.count == 2, "Expired user-task authority must refuse before resolving another app.")
    }

    @Test func originalNarrowScopeRefusesForeignAndAmbiguousTargetsBeforeResolver() throws {
        let first = identity(1, "test.first"), other = identity(2, "test.first")
        var resolves = 0
        let authority = NativeLocalTaskReadAuthority.localUserInvocation(taskID: UUID(), taskIsCurrent: { true },
            restrictions: [.init(application: first, validate: {})], resolve: { _ in
                resolves += 1; return .init(application: other, validate: {})
            })
        #expect(try authority.admit(first.bundleID).application == first)
        #expect(throws: (any Error).self) { try authority.admit("test.foreign") }
        let ambiguous = NativeLocalTaskReadAuthority.localUserInvocation(taskID: UUID(), taskIsCurrent: { true },
            restrictions: [.init(application: first, validate: {}), .init(application: other, validate: {})])
        #expect(throws: (any Error).self) { try ambiguous.admit(first.bundleID) }
        #expect(resolves == 0)
    }

    @Test func invalidSelectorsAndWrongResolvedIdentityCreateNoAdmission() throws {
        var resolves = 0
        let authority = NativeLocalTaskReadAuthority.localUserInvocation(taskID: UUID(), taskIsCurrent: { true },
            resolve: { _ in resolves += 1; return .init(application: identity(1, "test.wrong"), validate: {}) })
        for value in ["", "not a bundle", "test.bad\u{0}"] {
            #expect(throws: (any Error).self) { try authority.admit(value) }
        }
        #expect(resolves == 0)
        #expect(throws: (any Error).self) { try authority.admit("test.requested") }
        #expect(resolves == 1)
    }

    private func identity(_ pid: Int32, _ bundle: String) -> DesktopApplicationIdentity {
        .init(processID: pid, launchedAt: Date(timeIntervalSince1970: Double(pid)),
            bundleID: bundle, bundleURL: URL(fileURLWithPath: "/Applications/\(pid).app"))
    }
}
