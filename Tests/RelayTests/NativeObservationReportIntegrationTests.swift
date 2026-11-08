import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@Suite(.serialized) @MainActor struct NativeObservationReportIntegrationTests {
    @Test(arguments: NativeObservationReport.Kind.allCases)
    func actualServiceReturnsOneUnverifiedReportWithoutReviewFocusOrInput(_ kind: NativeObservationReport.Kind) async throws {
        let rig = try await Rig(); defer { rig.removeFiles() }
        rig.flags.kind = kind
        let service = rig.service()
        let result = try await service.control(rig.outerCall, acceptedProposalID: UUID())
        #expect(!result.verified && result.evidence.contains(rig.flags.secret))
        #expect(rig.flags.models == 1 && rig.flags.opens == 1)
        #expect(rig.flags.inspections == 0 && rig.flags.reviews == 0 && rig.flags.prepares == 0 && rig.flags.executes == 0)
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0 && rig.canvas.textReads == 0)
        let events = try await rig.records()
        let intents = events.compactMap { row -> JournalIntent? in if case .intent(let value) = row.event.payload { value } else { nil } }
        let outcomes = events.compactMap { row -> JournalToolOutcome? in if case .result(let value) = row.event.payload { value } else { nil } }
        #expect(intents.map(\.toolName) == ["native_control_prepare", NativeWindowControlTools.observeName])
        #expect(intents.allSatisfy { $0.effect == .readOnly })
        #expect(outcomes.map(\.invocationID) == intents.map(\.invocationID))
        #expect(outcomes.map(\.kind) == [.returnedVerified, .returnedUnverified])
        #expect(events.map { $0.event.payload }.allSatisfy { payload in
            if case .result(let value) = payload { return value.evidence?.text.contains(rig.flags.secret) != true }
            return true
        })
        #expect(!rig.flags.unsaved.contains { $0.summary.contains(rig.flags.secret) || $0.evidence.contains(rig.flags.secret) })
        service.stop(); await service.drain(); try await rig.close()
    }

    @Test func refreshThenTerminalReportSettlesSequentiallyAndMintsEachAcceptedReplyOnce() async throws {
        let rig = try await Rig(); defer { rig.removeFiles() }; rig.flags.refreshes = 1
        let result = try await rig.loop.control(rig.outerIdentity)
        #expect(!result.verified && rig.flags.models == 2 && rig.flags.accepts == 2)
        #expect(rig.flags.rounds == [0, 1] && rig.flags.prepares == 0 && rig.flags.executes == 0)
        let events = try await rig.records()
        let intents = events.compactMap { row -> JournalIntent? in if case .intent(let value) = row.event.payload { value } else { nil } }
        let outcomes = events.compactMap { row -> JournalToolOutcome? in if case .result(let value) = row.event.payload { value } else { nil } }
        #expect(intents.count == 3 && outcomes.count == 3 && intents.allSatisfy { $0.effect == .readOnly })
        #expect(intents[1].toolCallID == intents[2].toolCallID && intents[1].proposalID != intents[2].proposalID)
        #expect(outcomes.map(\.kind) == [.returnedVerified, .returnedVerified, .returnedUnverified])
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0)
        try await rig.close()
    }

    @Test(arguments: [JournalFault.beforeCommit, .afterCommit])
    func reportResultSaveFaultAndSourceRevocationNeverLeakDetailOrRepeatPlanning(_ fault: JournalFault) async throws {
        let rig = try await Rig(); defer { rig.removeFiles() }
        await rig.core.injectResultFault(fault, forToolName: NativeWindowControlTools.observeName)
        let grant = rig.grant
        await rig.core.atNextResultBoundary(.beforeCommit, forToolName: NativeWindowControlTools.observeName) { grant.revoke() }
        await #expect(throws: (any Error).self) { try await rig.loop.control(rig.outerIdentity) }
        #expect(rig.flags.models == 1 && rig.flags.accepts == 1)
        #expect(rig.flags.unsaved.count == 1)
        #expect(rig.flags.unsaved.allSatisfy { !$0.verified && !$0.summary.contains(rig.flags.secret) && !$0.evidence.contains(rig.flags.secret) })
        #expect(!rig.grant.isActive && rig.flags.executes == 0 && rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0)
        let modelCount = rig.flags.models, acceptCount = rig.flags.accepts
        try await rig.history.retryResultSaves()
        #expect(rig.flags.models == modelCount && rig.flags.accepts == acceptCount && rig.flags.unsaved.count == 1)
        let events = try await rig.records()
        let reportIntents = events.compactMap { row -> JournalIntent? in if case .intent(let value) = row.event.payload, value.toolName == NativeWindowControlTools.observeName { value } else { nil } }
        #expect(reportIntents.count == 1)
        let results = events.compactMap { row -> JournalToolOutcome? in if case .result(let value) = row.event.payload { value } else { nil } }
        #expect(results.count == 2 && results.last?.kind == .returnedUnverified)
        #expect(results.allSatisfy { $0.evidence?.text.contains(rig.flags.secret) != true })
        try await rig.close()
    }

    @Test func sourceRevokedAtSuccessfulReportCommitBlocksDetailPublicationAfterSettlement() async throws {
        let rig = try await Rig(); defer { rig.removeFiles() }; let grant = rig.grant
        await rig.core.atNextResultBoundary(.afterCommit, forToolName: NativeWindowControlTools.observeName) { grant.revoke() }
        await #expect(throws: (any Error).self) { try await rig.loop.control(rig.outerIdentity) }
        #expect(rig.flags.models == 1 && rig.flags.accepts == 1 && rig.flags.unsaved.isEmpty)
        let results = try await rig.records().compactMap { row -> JournalToolOutcome? in if case .result(let value) = row.event.payload { value } else { nil } }
        #expect(results.count == 2 && results.last?.kind == .returnedUnverified)
        #expect(results.allSatisfy { $0.evidence?.text.contains(rig.flags.secret) != true })
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0 && rig.flags.executes == 0)
        try await rig.close()
    }

    @Test func failedPreparationSaveCannotReachReportOrRemintItsAcceptedIdentity() async throws {
        let rig = try await Rig(); defer { rig.removeFiles() }
        await rig.core.injectResultFault(.afterCommit, forToolName: "native_control_prepare")
        await #expect(throws: (any Error).self) { try await rig.loop.control(rig.outerIdentity) }
        #expect(rig.flags.models == 1 && rig.flags.accepts == 1 && rig.flags.unsaved.count == 1)
        #expect(rig.flags.unsaved.allSatisfy { !$0.summary.contains(rig.flags.secret) && !$0.evidence.contains(rig.flags.secret) })
        try await rig.history.retryResultSaves()
        let intents = try await rig.records().compactMap { row -> JournalIntent? in if case .intent(let value) = row.event.payload { value } else { nil } }
        #expect(intents.count == 1 && intents[0].toolName == "native_control_prepare")
        #expect(rig.flags.models == 1 && rig.flags.accepts == 1 && rig.canvas.commands.isEmpty)
        try await rig.close()
    }

    @Test func sameAcceptedOuterProposalCannotRestartAReportedStep() async throws {
        let rig = try await Rig(); defer { rig.removeFiles() }
        _ = try await rig.loop.control(rig.outerIdentity)
        await #expect(throws: (any Error).self) { try await rig.loop.control(rig.outerIdentity) }
        #expect(rig.flags.models == 1 && rig.flags.accepts == 1 && rig.flags.executes == 0)
        try await rig.close()
    }

    @Test(arguments: ["budget", "progress"])
    func everyInnerRefreshUsesTheActualTaskBudgetAndTrustedProgressAdmission(_ cause: String) async throws {
        let rig = try await Rig(); defer { rig.removeFiles() }; rig.flags.refreshes = 10
        if cause == "budget" { rig.flags.expireAfterFirstPlan = true } else { rig.flags.rejectSecondRound = true }
        await #expect(throws: (any Error).self) { try await rig.loop.control(rig.outerIdentity) }
        #expect(rig.flags.models == 1 && rig.flags.accepts <= 1 && rig.canvas.captureCount == 1)
        #expect(rig.flags.rounds == (cause == "budget" ? [0] : [0, 1]))
        #expect(rig.flags.prepares == 0 && rig.flags.executes == 0 && rig.canvas.commands.isEmpty)
        try await rig.close()
    }

    @Test func budgetExpiryAfterSettledPreparationBlocksTheSecondRefreshBeforeItsRead() async throws {
        let rig = try await Rig(); defer { rig.removeFiles() }; rig.flags.refreshes = 10
        let clock = rig.flags.clock
        await rig.core.atNextResultBoundary(.afterCommit, forToolName: "native_control_prepare") { clock.set(2) }
        await #expect(throws: (any Error).self) { try await rig.loop.control(rig.outerIdentity) }
        #expect(rig.flags.models == 1 && rig.flags.accepts == 1 && rig.canvas.captureCount == 1)
        #expect(rig.flags.rounds == [0] && rig.flags.executes == 0 && rig.canvas.commands.isEmpty)
        try await rig.close()
    }

    @Test(arguments: [false, true])
    func sourceRevocationDuringModelReplyNeverReachesReportSettlementOrPrivatePublication(_ modelThrows: Bool) async throws {
        let rig = try await Rig(); defer { rig.removeFiles() }
        rig.flags.revokeDuringModel = true; rig.flags.throwDuringModel = modelThrows
        await #expect(throws: (any Error).self) { try await rig.loop.control(rig.outerIdentity) }
        #expect(rig.flags.models == 1 && rig.flags.accepts == 0 && rig.flags.prepares == 0 && rig.flags.executes == 0)
        let intents = try await rig.records().compactMap { row -> JournalIntent? in if case .intent(let value) = row.event.payload { value } else { nil } }
        #expect(intents.count == 1 && intents.first?.toolName == "native_control_prepare")
        #expect(rig.flags.unsaved.allSatisfy { !$0.summary.contains(rig.flags.secret) && !$0.evidence.contains(rig.flags.secret) })
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0)
        try await rig.close()
    }

    @Test func currentStoreDoesNotAdvertiseOrDispatchAnInnerReportAsAnOuterAction() async throws {
        var turns = 0, dispatched = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, tools, _ in
            turns += 1
            #expect(!tools.contains { $0.name == NativeWindowControlTools.observeName || $0.name == NativeWindowControlTools.outerName })
            return .init(content: "No app operation is needed.", toolCalls: [])
        }, execute: { _ in dispatched += 1; throw NativeVisualTaskFailure.staleTask })
        defer { store.stop() }
        store.configuration = .init(modelPath: "/inert/not-loaded.litertlm")
        store.draft = "Explain one ordinary synthetic UI state without operating an app."
        let ticket = try #require(store.send())
        #expect(await ticket.waitForAcknowledgment() == .saved)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isRunning { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(2)) }
        #expect(turns == 1 && dispatched == 0)
    }

    @MainActor private final class Flags {
        var current = true, kind = NativeObservationReport.Kind.appearsSatisfied
        var secret = "PRIVATE SYNTHETIC MODEL DETAIL " + UUID().uuidString
        var models = 0, accepts = 0, opens = 0, inspections = 0, reviews = 0, prepares = 0, executes = 0
        var refreshes = 0, expireAfterFirstPlan = false, rejectSecondRound = false, revokeDuringModel = false, throwDuringModel = false
        let clock = Clock()
        var now: TimeInterval { get { clock.read() } set { clock.set(newValue) } }
        var rounds: [UInt64] = []
        var unsaved: [ToolResult] = []
    }
    nonisolated private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: TimeInterval = 0
        func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return instant }
        func set(_ value: TimeInterval) { lock.lock(); instant = value; lock.unlock() }
    }
    nonisolated private final class Grant: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
        func revoke() { lock.lock(); active = false; lock.unlock() }
        @MainActor func validate() throws { guard isActive else { throw NativeVisualTaskFailure.staleTask } }
    }
    @MainActor private final class Rig {
        let canvas = NextNativeControlRig(), flags = Flags(), grant = Grant()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relay-report-pure-" + UUID().uuidString)
        let history: AssistantConversationHistory
        let scope: NativeVisualTaskScope
        let core: ConversationJournal
        let journal: NativeVisualTaskJournal
        let policy: NativeOrdinaryVisualPolicy
        let owner: NativeComputerTaskSession
        let factory: NativeVisualTaskConnectionFactory
        let planningAdmission: NativeVisualPlanningAdmission
        let complete: NativeWindowControlPlanningPhase.Complete
        let outerCall: ToolCall
        let outerIdentity: NativeVisualProposalIdentity
        var loop: NativeWindowControlTaskLoop!
        init() async throws {
            let canvas = self.canvas, flags = self.flags, grant = self.grant, taskID = UUID()
            history = AssistantConversationHistory(stateURL: folder.appendingPathComponent("state.json"))
            let run = try AssistantConversationHistory.Run(logicalTaskID: taskID, cause: .newRequest)
            let read = NativeLocalTaskReadAuthority.localUserInvocation(taskID: taskID, taskIsCurrent: { flags.current },
                resolve: { bundle in
                    try grant.validate()
                    guard bundle == canvas.application.bundleID else { throw NativeVisualTaskFailure.staleTask }
                    return .init(application: canvas.application, validate: { try grant.validate() })
                })
            scope = try NativeVisualTaskScope(logicalTaskID: taskID, runRevision: 1, run: run,
                originalObjective: "Inspect the original synthetic canvas and report honestly without forced input.",
                inferenceIdentity: .embedded(path: "/inert/not-loaded.litertlm", compute: "cpu"), readAuthority: read,
                validateAcknowledgedStoreRun: { guard flags.current else { throw NativeVisualTaskFailure.staleTask } })
            try await history.prepare(run); core = try await history.journalForTesting()
            journal = NativeVisualTaskJournal(history: history, scope: scope, unsavedFact: { flags.unsaved.append($0) })
            policy = NativeOrdinaryVisualPolicy(inspect: { _, _ in flags.inspections += 1; throw NativeVisualTaskFailure.staleTask },
                review: { _, _, _ in flags.reviews += 1; return false })
            planningAdmission = .init(budget: TaskRunBudget(activeLimit: 1, now: { flags.now }), admitProgress: { round in
                flags.rounds.append(round.ordinal)
                if flags.rejectSecondRound, round.ordinal > 0 { throw NativeVisualTaskFailure.noInput("Trusted progress gate refused another unchanged planning round.") }
            })
            complete = { _, _, vision in
                flags.models += 1; try vision.validate()
                let refresh = flags.models <= flags.refreshes
                var args: [String: JSONValue] = ["observation_id": .string(vision.frame.observationID.uuidString),
                    "image_id": .string(vision.frame.id.uuidString), "disposition": .string(refresh ? "refresh" : flags.kind.rawValue)]
                if !refresh { args["detail"] = .string(flags.secret) }
                if flags.expireAfterFirstPlan { flags.now = 2 }
                if flags.revokeDuringModel { flags.current = false; grant.revoke() }
                if flags.throwDuringModel { throw NativeVisualTaskFailure.staleTask }
                return .init(content: "", toolCalls: [.init(id: "provider-id-reused-by-later-accepted-replies", name: NativeWindowControlTools.observeName, arguments: args)])
            }
            factory = .init(missingDependencies: [], open: { _, _ in
                flags.opens += 1
                @MainActor func source(_ observation: NativeControlSession.Observation) throws -> NativeVisualTaskSource {
                    let original = try canvas.session.source(from: observation)
                    let validate: @MainActor () throws -> Void = { try grant.validate(); try canvas.session.validateOriginalSource(original) }
                    return .init(observation: observation, sourceID: original.id, validateOriginalSource: validate,
                        validatePlanningObservation: { try validate(); try canvas.session.validatePlanningObservation(observation) }, validateForInput: { throw NativeVisualTaskFailure.staleTask })
                }
                return NativeVisualTaskConnection(controller: canvas.session, observeRead: { _ in
                    try grant.validate(); return try source(await canvas.read())
                }, refreshOriginal: { previous in
                    try previous.validateOriginalSource()
                    let original = try canvas.session.source(from: previous.observation)
                    return try source(await canvas.session.refreshOriginalForRead(original))
                }, refreshForInputPlanning: { previous in try previous.validateOriginalSource(); return previous },
                    prepareForReview: { _, _, _, _ in flags.prepares += 1; throw NativeVisualTaskFailure.staleTask },
                    executeAdmitted: { _ in flags.executes += 1; return .uncertain("An observation report has no input path.") }, closeOwnedClient: {})
            })
            owner = NativeComputerTaskSession(scope: scope, factory: factory, policy: policy)
            outerCall = .init(id: "accepted-outer-call", name: NativeWindowControlTools.outerName,
                arguments: ["bundle_id": .string(canvas.application.bundleID), "instruction": .string("Report this original step's state without forced input.")])
            outerIdentity = try NativeVisualProposalIdentity(scope: scope, acceptedReplyID: UUID(), call: outerCall)
            let scope = self.scope
            loop = NativeWindowControlTaskLoop(owner: owner, journal: journal, complete: complete, acceptReply: { operation in
                flags.accepts += 1
                return try NativeVisualProposalIdentity(scope: scope, acceptedReplyID: UUID(), call: operation.call)
            }, planningAdmission: planningAdmission)
        }
        func service() -> NativeComputerTaskService {
            let flags = flags
            return NativeComputerTaskService(scope: scope, history: history, factory: factory,
                inspect: { _, _ in flags.inspections += 1; throw NativeVisualTaskFailure.staleTask },
                review: { _, _, _ in flags.reviews += 1; return false }, complete: complete,
                completeRead: { _ in throw NativeVisualTaskFailure.staleTask },
                fallbackReadBackend: { _ in throw NativeVisualTaskFailure.staleTask }, unsavedFact: { flags.unsaved.append($0) },
                planningAdmission: planningAdmission)
        }
        func records() async throws -> [JournalRecord] {
            let expected = try await core.scope(); var cursor: JournalCursor?, rows: [JournalRecord] = []
            repeat {
                let page = try await core.page(after: cursor, expectedScope: expected)
                rows += page.records; cursor = page.hasLater ? page.cursor : nil
            } while cursor != nil
            return rows
        }
        func close() async throws { owner.stop(); await owner.drain(); try await history.close(); canvas.session = nil }
        func removeFiles() { try? FileManager.default.removeItem(at: folder) }
    }
}
