import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Exercises the production factory, exact source cache and real Session with
/// inert transport/metadata resources. No process discovery or AX query runs.
@Suite(.serialized) @MainActor struct NativeProductionTaskConnectionFactoryTests {
    @Test func realFactoryRetainsOneOriginalSourceForReadRefreshAndClosesOwnedResourceOnce() async throws {
        let rig = try Rig(), connection = try await rig.factory.open(policy: rig.policy)
        let initial = try await connection.observeRead(rig.admission)
        let second = try await connection.refreshOriginal(initial)
        #expect(initial.sourceID == second.sourceID && rig.opens == 1 && rig.canvas.captureCount == 2)
        #expect(try rig.factory.policyTarget(second.sourceID).sourceID == second.sourceID)
        #expect(rig.canvas.textReads == 0 && rig.canvas.textWrites == 0 && rig.canvas.commands.isEmpty)
        connection.stop(); connection.stop(); await connection.drain()
        #expect(rig.closes == 1)
        #expect(throws: (any Error).self) { try initial.validateOriginalSource() }
    }
    @Test func actualFactorySharedReaderReturnsAnExactSourceReceiptIndependentOfTheReleasedImage() async throws {
        let rig = try Rig()
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-native-factory-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json"))
        let service = NativeComputerTaskService(scope: rig.scope, history: history,
            factory: .init(missingDependencies: [], open: { scope, policy in
                try #require(scope === rig.scope); return try await rig.factory.open(policy: policy)
            }), inspect: { _, _ in throw NativeVisualTaskFailure.staleProposal },
            review: { _, _, _ in Issue.record("A read cannot request input review"); return false },
            complete: { _, _, _ in throw NativeVisualTaskFailure.staleProposal },
            completeRead: { _ in .init(content: "Private synthetic observation", toolCalls: []) },
            fallbackReadBackend: { _ in Issue.record("Shared owner must not open another reader"); throw NativeVisualTaskFailure.staleTask },
            unsavedFact: { _ in Issue.record("Read has no inner input checkpoint") },
            planningAdmission: .init(budget: TaskRunBudget(), admitProgress: { _ in }))
        let call = ToolCall(id: "actual-factory-read", name: NativeWindowReadTool.name,
            arguments: ["bundle_id": .string(rig.canvas.application.bundleID), "question": .string("What is visible?")])
        let proposal = UUID(), result = try await service.read(call, acceptedProposalID: proposal, objective: rig.scope.originalObjective)
        let captures = rig.canvas.captureCount
        let check = try await service.admitReadback(call, acceptedProposalID: proposal, result: result)
        try await check(); try await check()
        #expect(rig.opens == 1 && captures == 1 && rig.canvas.captureCount == captures)
        #expect(rig.canvas.textReads == 0 && rig.canvas.textWrites == 0 && rig.canvas.commands.isEmpty)
        await #expect(throws: (any Error).self) {
            try await service.admitReadback(call, acceptedProposalID: UUID(), result: result)
        }
        rig.canvas.sourceVersion += 1
        await #expect(throws: (any Error).self) { try await check() }
        service.stop(); await service.drain(); try await history.close()
        #expect(rig.closes == 1)
        await #expect(throws: (any Error).self) { try await check() }
    }

    @Test func foreignAdmissionRefusesBeforePlatformCaptureWithoutRetargeting() async throws {
        let rig = try Rig(), connection = try await rig.factory.open(policy: rig.policy)
        let other = DesktopApplicationIdentity(processID: 99, launchedAt: Date(timeIntervalSince1970: 1),
            bundleID: "test.foreign", bundleURL: URL(fileURLWithPath: "/Foreign.app"))
        await #expect(throws: (any Error).self) {
            try await connection.observeRead(.init(application: other, validate: {}))
        }
        #expect(rig.observations == 0 && rig.canvas.captureCount == 0)
        connection.stop(); await connection.drain(); #expect(rig.closes == 1)
    }
    @Test func taskRevokedWhileOpenAwaitsClosesTheLateControllerWithoutCapturing() async throws {
        let rig = try Rig(); var waiting: CheckedContinuation<Void, Never>?
        rig.pauseOpen = { await withCheckedContinuation { waiting = $0 } }
        let opening = Task { try await rig.factory.open(policy: rig.policy) }
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while waiting == nil { try #require(ContinuousClock.now < end); await Task.yield() }
        rig.current = false; waiting?.resume(); waiting = nil
        await #expect(throws: (any Error).self) { try await opening.value }
        #expect(rig.opens == 1 && rig.closes == 1 && rig.observations == 0)
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textReads == 0)
    }
    @Test func pinnedOldSessionIsExplicitlyUnavailableBeforeOpeningAReplacementClient() async throws {
        let rig = try Rig(), old = try await rig.canvas.read(), original = try rig.canvas.session.source(from: old)
        let input = try NativeLocalTaskInputAuthority.localUserInvocation(scope: rig.scope,
            windowRequirement: .pinned(original), validateAcknowledgedInputGrant: {})
        let factory = try NativeProductionTaskConnectionFactory(scope: rig.scope, inputAuthority: input, platform: rig.platform)
        await #expect(throws: (any Error).self) { try await factory.open(policy: rig.policy) }
        #expect(rig.opens == 0 && rig.canvas.commands.isEmpty)
        rig.canvas.session.stop(); await rig.canvas.session.drain()
    }
    @Test func foreignOwnerObservationCannotEnterTheRetainedSourceCache() async throws {
        let rig = try Rig(); rig.foreignSnapshot = true
        let connection = try await rig.factory.open(policy: rig.policy)
        await #expect(throws: (any Error).self) { try await connection.observeRead(rig.admission) }
        #expect(rig.opens == 1 && rig.observations == 1)
        #expect(throws: (any Error).self) { try rig.factory.policyTarget(rig.canvas.sourceID) }
        connection.stop(); await connection.drain()
    }
    @MainActor private final class Rig {
        let canvas = NextNativeControlRig(), foreign = NextNativeControlRig()
        let scope: NativeVisualTaskScope
        let policy: NativeOrdinaryVisualPolicy
        var current = true { didSet { if !current { scope.stop() } } }
        var opens = 0, closes = 0, observations = 0, foreignSnapshot = false
        var pauseOpen: (@MainActor () async -> Void)?
        lazy var platform = NativeProductionTaskConnectionFactory.Platform(open: { [self] policy, active in
            opens += 1; await pauseOpen?()
            canvas.session = NativeControlSession(backend: canvas.backend, sessionIsActive: active, authorizer: policy)
            return .init(controller: canvas.session, close: { [self] in closes += 1 })
        }, observeRead: { [self] controller, admission in
            observations += 1; try admission.validate()
            if foreignSnapshot { return try await foreign.read() }
            var target = canvas.target()
            target.policyTarget = { [self] in
                NativeOriginalPolicyTarget(sourceID: canvas.sourceID, application: canvas.application,
                    originalWindow: AXUIElementCreateApplication(canvas.application.processID), validateOriginalSource: {
                        try self.scope.validate()
                    })
            }
            return try await controller.observeForRead(target: target)
        })
        lazy var factory = try! NativeProductionTaskConnectionFactory(scope: scope,
            inputAuthority: .localUserInvocation(scope: scope, windowRequirement: .appScoped,
                validateAcknowledgedInputGrant: { [self] in guard current else { throw CancellationError() } }), platform: platform)
        var admission: NativeWindowTaskAdapter.ApplicationAdmission { .init(application: canvas.application, validate: {}) }
        init() throws {
            let task = UUID(), box = Current()
            let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
            let application = canvas.application
            let read = NativeLocalTaskReadAuthority.localUserInvocation(taskID: task,
                taskIsCurrent: { box.active }, resolve: { bundle in
                    guard bundle == application.bundleID else { throw NativeVisualTaskFailure.staleTask }
                    return .init(application: application, validate: { guard box.active else { throw CancellationError() } })
                })
            scope = try .init(logicalTaskID: task, runRevision: 1, run: run,
                originalObjective: "Read or navigate the original admitted synthetic source.",
                inferenceIdentity: .embedded(path: "/inert/not-loaded.litertlm", compute: "cpu"), readAuthority: read,
                validateAcknowledgedStoreRun: { guard box.active else { throw CancellationError() } })
            policy = NativeOrdinaryVisualPolicy(inspect: { _, _ in throw NativeVisualTaskFailure.staleProposal },
                review: { _, _, _ in Issue.record("Read-only tests must not request review"); return false })
        }
        private final class Current { var active = true }
    }
}
