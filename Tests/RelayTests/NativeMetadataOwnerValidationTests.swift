import Foundation
import Testing
@testable import Relay

/// Real scope/input/read wrappers with inert application resolution only.
/// These app-scoped tests do not fabricate a saved ACK or an initial AX source;
/// the genuine direct initial path remains an owned runtime acceptance gate.
@MainActor @Suite struct NativeMetadataOwnerValidationTests {
    private enum Refusal: Error, Equatable { case input, restriction }
    @MainActor private final class State {
        var input = true, restriction = true
        var inputChecks = 0, admissionChecks = 0
    }
    private func rig(direct: Bool) throws -> (State, NativeVisualTaskScope, NativeLocalTaskInputAuthority, DesktopApplicationIdentity) {
        let state = State(), task = UUID()
        let app = DesktopApplicationIdentity(processID: 42, launchedAt: Date(timeIntervalSince1970: 1),
            bundleID: "test.metadata.owner", bundleURL: URL(fileURLWithPath: "/Owned Metadata.app"))
        let admission = NativeWindowTaskAdapter.ApplicationAdmission(application: app, validate: {
            state.admissionChecks += 1
            guard state.restriction else { throw Refusal.restriction }
        })
        let read = NativeLocalTaskReadAuthority.localUserInvocation(taskID: task, taskIsCurrent: { true }, restrictions: [admission])
        let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
        let scope: NativeVisualTaskScope
        if direct {
            scope = try .init(directExactUnsent: task, runRevision: 1, run: run,
                originalObjective: "Known owner checks only.", readAuthority: read, validateAcknowledgedStoreRun: {})
        } else {
            scope = try .init(logicalTaskID: task, runRevision: 1, run: run,
                originalObjective: "Known owner checks only.",
                inferenceIdentity: .embedded(path: "/inert/not-loaded.litertlm", compute: "cpu"),
                readAuthority: read, validateAcknowledgedStoreRun: {})
        }
        let authority = try NativeLocalTaskInputAuthority.localUserInvocation(scope: scope, windowRequirement: .appScoped,
            validateAcknowledgedInputGrant: {
                state.inputChecks += 1
                guard state.input else { throw Refusal.input }
            })
        return (state, scope, authority, app)
    }
    @Test(arguments: [false, true])
    func metadataOwnerNeverCachesARevokedActualInputContract(_ direct: Bool) throws {
        let (state, _, authority, _) = try rig(direct: direct)
        try authority.validateMetadataOwner()
        let before = state.inputChecks
        state.input = false
        #expect(throws: Refusal.input) { try authority.validateMetadataOwner() }
        #expect(state.inputChecks == before + 1)
    }
    @Test(arguments: [false, true])
    func applicationAdmissionIsStillValidatedForEveryMetadataQuery(_ direct: Bool) throws {
        let (state, _, authority, app) = try rig(direct: direct)
        try authority.metadataScopeBinding(for: app).withAuthorization { authorization in
            try authorization.check()
            let before = state.admissionChecks
            try authorization.check()
            #expect(state.admissionChecks == before + 1)
            state.restriction = false
            #expect(throws: Refusal.restriction) { try authorization.check() }
            #expect(state.admissionChecks == before + 2)
        }
    }
    @Test(arguments: [false, true])
    func scopeStopPreventsAnotherInertMetadataQuery(_ direct: Bool) throws {
        let (_, scope, authority, app) = try rig(direct: direct)
        var queries = 0
        try authority.metadataScopeBinding(for: app).withAuthorization { authorization in
            try authorization.check(); queries += 1
            scope.stop()
            #expect(throws: NativeVisualTaskFailure.stopped) { try authorization.check(); queries += 1 }
        }
        #expect(queries == 1)
    }
}
