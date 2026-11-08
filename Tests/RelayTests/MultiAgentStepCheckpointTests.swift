import Foundation
import Testing
@testable import Relay

@MainActor @Suite(.serialized) struct MultiAgentStepCheckpointTests {
    private func context(task: UUID, scope: UUID = UUID(), revision: Int = 0,
                         configuration: ModelConfiguration = .init()) -> MultiAgentContinuation.Context {
        .init(logicalTaskID: task, configuration: configuration, scopeID: scope, sourceRevision: revision)
    }

    @Test func repeatedSameNestedConfigurationKeepsTheOriginalPlanAndScope() throws {
        let endpoint = try LMStudioEndpoint(host: .ipv4, port: 12_345)
        let server = try LMStudioConfiguration(endpoint: endpoint, modelID: "owned-cafe\u{301}")
        let configuration = ModelConfiguration(backend: .lmStudio, model: "Owned nested configuration", lmStudio: server)
        let task = UUID(), scope = context(task: task, configuration: configuration)
        let cache = MultiAgentStepCheckpoint(logicalTaskID: task)
        let first = try cache.begin(goal: "A stable acknowledged task.", context: scope)
        try cache.install([PlanStep(role: .executor, title: "One bounded step")], lease: first, goalOnlyPlanner: true)
        let retained = try cache.begin(goal: "A stable acknowledged task.", context: scope)
        let tokens = try #require(retained.entries?.map(\.token))
        for _ in 0..<64 {
            let next = try cache.begin(goal: "A stable acknowledged task.", context: scope)
            #expect(next.entries?.map(\.token) == tokens && next.startIndex == 0 && !next.requiresReconciliation)
        }
    }

    @Test func duplicateTitlesAndModelIDsNeverCollapseAppOwnedStepPositions() throws {
        let task = UUID(), cache = MultiAgentStepCheckpoint(logicalTaskID: task), scope = context(task: task)
        let first = try cache.begin(goal: "Perform both distinct scheduled steps.", context: scope)
        let plan = [PlanStep(id: "duplicate", role: .executor, title: "Same title"), PlanStep(id: "duplicate", role: .executor, title: "Same title")]
        try cache.install(plan, lease: first, goalOnlyPlanner: true)
        try cache.enterStep(at: 0, lease: first); try cache.willDispatchExecutor(at: 0, lease: first)
        try cache.complete(at: 0, lease: first)
        let next = try cache.begin(goal: "Perform both distinct scheduled steps.", context: scope)
        let entries = try #require(next.entries)
        #expect(entries.count == 2 && entries[0].token != entries[1].token)
        #expect(entries[0].step.id == entries[1].step.id && entries[0].step.title == entries[1].step.title)
        #expect(next.startIndex == 1 && !next.requiresReconciliation)
        let board = MultiAgentBlackboard(); board.setPlan(plan)
        board.completeStep(at: 0)
        #expect(board.structuredPlan[0].status == .verified && board.structuredPlan[1].status == .pending)
        board.completeStep(at: 1)
        #expect(board.completedSteps.count == 2 && board.isComplete)
    }

    @Test(arguments: ["executor-started", "possibly-dispatched", "reconciling"])
    func onlyPossiblyDispatchedOrReconcilingExecutorsRequireCritic(_ stage: String) throws {
        let task = UUID(), cache = MultiAgentStepCheckpoint(logicalTaskID: task), scope = context(task: task)
        let first = try cache.begin(goal: "Write once.", context: scope)
        try cache.install([PlanStep(role: .executor, title: "Write once")], lease: first, goalOnlyPlanner: true)
        try cache.enterStep(at: 0, lease: first)
        if stage == "possibly-dispatched" { try cache.willDispatchExecutor(at: 0, lease: first) }
        if stage == "reconciling" { try cache.beginReconciliation(at: 0, lease: first) }
        let next = try cache.begin(goal: "Write once.", context: scope)
        #expect(next.requiresReconciliation == (stage != "executor-started") && next.startIndex == 0)
        #expect(throws: MultiAgentStepCheckpoint.Failure.staleRun) { try cache.complete(at: 0, lease: first) }
    }

    @Test func aDeclineAfterPossibleDispatchSurvivesInterruptedReconciliation() throws {
        let task = UUID(), scope = context(task: task), cache = MultiAgentStepCheckpoint(logicalTaskID: task)
        let first = try cache.begin(goal: "A bounded owned action.", context: scope)
        try cache.install([PlanStep(role: .executor, title: "Perform the bounded action")], lease: first, goalOnlyPlanner: true)
        try cache.enterStep(at: 0, lease: first); try cache.willDispatchExecutor(at: 0, lease: first)
        try cache.decline(at: 0, lease: first)
        let reconciliation = try cache.begin(goal: "A bounded owned action.", context: scope)
        #expect(reconciliation.declined && reconciliation.requiresReconciliation)
        try cache.beginReconciliation(at: 0, lease: reconciliation)
        let next = try cache.begin(goal: "A bounded owned action.", context: scope)
        #expect(next.declined && next.requiresReconciliation)
        #expect(throws: MultiAgentStepCheckpoint.Failure.declined) { try cache.enterStep(at: 0, lease: next) }
        #expect(throws: MultiAgentStepCheckpoint.Failure.declined) { try cache.willDispatchExecutor(at: 0, lease: next) }
        #expect(throws: MultiAgentStepCheckpoint.Failure.declined) { try cache.complete(at: 0, lease: next) }
    }

    @Test func aFinishedCursorStillRequiresFreshReadInsteadOfPretendingItIsGoalProof() throws {
        let task = UUID(), cache = MultiAgentStepCheckpoint(logicalTaskID: task), scope = context(task: task)
        let first = try cache.begin(goal: "Write once.", context: scope)
        try cache.install([PlanStep(role: .executor, title: "Write once")], lease: first, goalOnlyPlanner: true)
        try cache.enterStep(at: 0, lease: first); try cache.complete(at: 0, lease: first)
        let next = try cache.begin(goal: "Write once.", context: scope)
        #expect(next.requiresReconciliation && next.startIndex == 0)
        try cache.beginReconciliation(at: 0, lease: next); try cache.complete(at: 0, lease: next)
        #expect(try cache.begin(goal: "Write once.", context: scope).requiresReconciliation)
    }

    @Test(arguments: ["configuration", "grant-epoch", "source-revision", "new-task", "changed-goal", "unicode-goal"])
    func staleContextAndChangedInstructionsRefuseWithoutReplanning(_ change: String) throws {
        let task = UUID(), scopeID = UUID(), cache = MultiAgentStepCheckpoint(logicalTaskID: task)
        let original = context(task: task, scope: scopeID)
        let lease = try cache.begin(goal: "Save caf\u{e9} once.", context: original)
        try cache.install([PlanStep(role: .executor, title: "Save once")], lease: lease, goalOnlyPlanner: true)
        var changed = original, goal = "Save caf\u{e9} once."
        switch change {
        case "configuration": var configuration = original.configuration; configuration.modelPath = "/changed/model"; changed = context(task: task, scope: scopeID, configuration: configuration)
        case "grant-epoch": changed = context(task: task)
        case "source-revision": changed = context(task: task, scope: scopeID, revision: 1)
        case "new-task": changed = context(task: UUID(), scope: scopeID)
        case "unicode-goal": goal = "Save cafe\u{301} once."
        default: goal += " Then overwrite it again."
        }
        #expect(throws: MultiAgentStepCheckpoint.Failure.self) { try cache.begin(goal: goal, context: changed) }
    }

    @Test func cacheAdmissionKeepsWholeEntriesAndNeverTruncatesAPrivateOrOverBudgetPlan() throws {
        let task = UUID(), scope = context(task: task), cache = MultiAgentStepCheckpoint(logicalTaskID: task)
        let first = try cache.begin(goal: "A bounded task.", context: scope)
        try cache.install([PlanStep(role: .executor, title: String(repeating: "x", count: MultiAgentStepCheckpoint.maximumRetainedPlanBytes))], lease: first, goalOnlyPlanner: true)
        #expect(throws: MultiAgentStepCheckpoint.Failure.planBudget) { try cache.begin(goal: "A bounded task.", context: scope) }
        let other = MultiAgentStepCheckpoint(logicalTaskID: task)
        let privateLease = try other.begin(goal: "An ordinary task.", context: scope)
        try other.install([PlanStep(role: .executor, title: "DERIVED_PRIVATE_PLAN")], lease: privateLease, goalOnlyPlanner: false)
        #expect(throws: MultiAgentStepCheckpoint.Failure.historicalPlannerContext) { try other.begin(goal: "An ordinary task.", context: scope) }
    }

    @Test func stopBeforeAReplyCanResumeFreshExecutorAndCompleteOnlyOneActualWrite() async throws {
        let rig = Rig(); rig.interruptBeforeExecutorReply = true
        await #expect(throws: CancellationError.self) { try await rig.make().executeTask(goal: rig.goal) }
        #expect(rig.executors == 1 && rig.writes == 0)
        rig.resuming = true; rig.interruptBeforeExecutorReply = false
        let result = try await rig.make().executeTask(goal: rig.goal)
        #expect(result.isSuccess && rig.planners == 1 && rig.executors == 2 && rig.reads == 1 && rig.writes == 1)
        #expect(rig.resumeRoles.first == "executor" && rig.verdicts == 1)
    }

    @Test func explicitlyDeclinedReviewCannotBeReofferedOnContinue() async throws {
        let rig = Rig(); rig.declineReview = true
        #expect(!(try await rig.make().executeTask(goal: rig.goal)).isSuccess)
        let inferences = rig.inferences
        #expect(rig.writes == 0 && rig.executors == 1)
        rig.resuming = true; rig.declineReview = false
        let result = try await rig.make().executeTask(goal: rig.goal)
        #expect(!result.isSuccess && rig.inferences == inferences && rig.writes == 0 && rig.executors == 1)
        #expect(rig.reads == 0)
    }

    @Test(arguments: ["goal", "configuration"])
    func cacheByteBudgetNeverBecomesAnInitialModelOrTaskLimit(_ large: String) async throws {
        let task = UUID(), cache = MultiAgentStepCheckpoint(logicalTaskID: task)
        var configuration = ModelConfiguration(), goal = "A supported task."
        if large == "goal" { goal = String(repeating: "g", count: MultiAgentStepCheckpoint.maximumRetainedPlanBytes + 1) }
        else { configuration.model = String(repeating: "m", count: MultiAgentStepCheckpoint.maximumRetainedPlanBytes + 1) }
        let scope = context(task: task, configuration: configuration)
        var sends = 0, effects = 0
        let engine = MultiAgentOrchestrator(configuration: configuration, complete: { messages, _, _ in
            sends += 1
            let role = messages.first?.content ?? ""
            if role.contains("ROLE: Executor") {
                return .init(content: "", toolCalls: [.init(id: "large-cache-original", name: "write_file", arguments: ["path": .string("/owned/initial.txt"), "content": .string("Initial allowed effect")])])
            }
            if role.contains("ROLE: Critic") { return .init(content: "VERIFIED: The inert adapter checked this initial effect.", toolCalls: []) }
            if messages.last?.content.contains("Synthesize") == true { return .init(content: "The initial model route and effect were reached.", toolCalls: []) }
            return .init(content: #"{"steps":[{"role":"Executor","title":"Perform the initial owned effect"}]}"#, toolCalls: [])
        }, execute: { _ in effects += 1; return .init(summary: "Initial owned effect", evidence: "Trusted inert adapter oracle", verified: true) }, stepCheckpoint: cache, stepContext: scope)
        #expect(try await engine.executeTask(goal: goal).isSuccess)
        #expect(sends == 4 && effects == 1)
        await #expect(throws: MultiAgentStepCheckpoint.Failure.planBudget) { try await engine.executeTask(goal: goal) }
        #expect(sends == 4 && effects == 1)
    }

    @Test func partialBatchIsReconciledWithoutRecreatingAnyOldAcceptedCall() async throws {
        let rig = Rig(); rig.batch = true
        await #expect(throws: CancellationError.self) { try await rig.make().executeTask(goal: rig.goal) }
        #expect(rig.writes == 1 && rig.executors == 1)
        rig.resuming = true; rig.actualPostcondition = false; rig.omitted = 1
        let result = try await rig.make().executeTask(goal: rig.goal)
        #expect(!result.isSuccess && rig.writes == 1 && rig.executors == 1 && rig.planners == 1)
        #expect(rig.reads == 1 && rig.resumeRoles.first == "critic-read")
    }

    @Test func freshSnapshotReplacesOldRunValidatorAndPermitsOnlyReadReconciliation() async throws {
        let rig = Rig()
        await #expect(throws: CancellationError.self) { try await rig.make().executeTask(goal: rig.goal) }
        let previousValidations = rig.oldValidations
        rig.resuming = true; rig.oldSnapshotCurrent = false; rig.omitted = 1
        let result = try await rig.make().executeTask(goal: rig.goal)
        #expect(result.isSuccess && rig.writes == 1 && rig.executors == 1 && rig.planners == 1)
        #expect(rig.oldValidations == previousValidations && rig.freshValidations > 0 && rig.reads == 1)
        #expect(rig.resumeRoles == ["critic-read", "critic-verdict", "synthesis"])
        #expect(rig.verdictSawPrivateReadBody && !rig.synthesisSawPrivateReadBody)
        #expect(result.verifiedResults.contains { $0.evidence == rig.privateReadBody })
    }

    @Test(arguments: ["included", "omitted"])
    func historicalInitialPlannerCannotBecomeAReusableGoalOnlyPlan(_ kind: String) async throws {
        let rig = Rig(); rig.initialPrivate = kind == "included"; rig.omitted = kind == "omitted" ? 1 : 0
        await #expect(throws: CancellationError.self) { try await rig.make().executeTask(goal: rig.goal) }
        let inferences = rig.inferences
        rig.resuming = true
        await #expect(throws: MultiAgentStepCheckpoint.Failure.historicalPlannerContext) { try await rig.make().executeTask(goal: rig.goal) }
        #expect(rig.inferences == inferences && rig.writes == 1)
    }

    @MainActor private final class Rig {
        let task = UUID(), scopeID = UUID(), goal = "Create the owned output once, then check its complete postcondition."
        lazy var checkpoint = MultiAgentStepCheckpoint(logicalTaskID: task)
        var context: MultiAgentContinuation.Context { .init(logicalTaskID: task, configuration: .init(), scopeID: scopeID, sourceRevision: 0) }
        var resuming = false, interruptBeforeExecutorReply = false, batch = false, actualPostcondition = true
        var oldSnapshotCurrent = true, initialPrivate = false, omitted = 0, declineReview = false
        var planners = 0, executors = 0, writes = 0, reads = 0, verdicts = 0, inferences = 0
        var oldValidations = 0, freshValidations = 0, resumeRoles: [String] = []
        let privateReadBody = "FRESH_READ_BODY_ONLY_THIS_VERDICT"
        var verdictSawPrivateReadBody = false, synthesisSawPrivateReadBody = false
        func make() -> MultiAgentOrchestrator {
            MultiAgentOrchestrator(allTools: MacTools.definitions.filter { ["write_file", "read_file"].contains($0.name) }, complete: { [self] input, tools, _ in
                inferences += 1
                let role = input.first?.content ?? ""
                if role.contains("ROLE: Planner") {
                    if input.last?.content.contains("Synthesize") == true {
                        if resuming { resumeRoles.append("synthesis") }
                        synthesisSawPrivateReadBody = input.map(\.content).joined().contains(privateReadBody)
                        return .init(content: "The current read supports the owned postcondition.", toolCalls: [])
                    }
                    planners += 1
                    return .init(content: #"{"steps":[{"id":"duplicate","role":"Executor","title":"Create the owned output once"}]}"#, toolCalls: [])
                }
                if role.contains("ROLE: Executor") {
                    executors += 1
                    if resuming { resumeRoles.append("executor") }
                    if interruptBeforeExecutorReply { throw CancellationError() }
                    let one = ToolCall(id: "original-provider-id", name: "write_file", arguments: ["path": .string("/owned/one.txt"), "content": .string("one")])
                    let two = ToolCall(id: "second-original-id", name: "write_file", arguments: ["path": .string("/owned/two.txt"), "content": .string("two")])
                    return .init(content: "", toolCalls: batch ? [one, two] : [one])
                }
                if !tools.isEmpty {
                    #expect(tools.allSatisfy { ToolPartitioning.allowedToolNames(for: .critic).contains($0.name) })
                    if resuming { resumeRoles.append("critic-read") }
                    return .init(content: "Inspect before drawing a conclusion.", toolCalls: [.init(id: "original-provider-id", name: "read_file", arguments: ["path": .string("/owned/one.txt")])])
                }
                verdicts += 1
                if resuming { resumeRoles.append("critic-verdict") }
                #expect(input.contains { $0.role == "tool" && $0.toolName == "read_file" })
                verdictSawPrivateReadBody = input.map(\.content).joined().contains(privateReadBody)
                return .init(content: actualPostcondition ? "VERIFIED: The current complete postcondition matches." : "UNVERIFIED: Some requested output is missing.", toolCalls: [])
            }, execute: { [self] call in
                if call.name == "write_file" {
                    writes += 1
                    if !resuming { throw CancellationError() }
                    return .init(summary: "One actual inert write.", evidence: "Current owned effect only.", verified: true)
                }
                reads += 1
                return .init(summary: "A fresh owned read", evidence: privateReadBody, verified: true)
            }, priorReceipts: { [self] _ in
                let fresh = resuming
                let included = !fresh && initialPrivate ? 1 : 0
                let content = included == 0 && omitted == 0 ? "" : "Historical coverage: included=\(included), omitted=\(omitted)." + (included > 0 ? " PRIVATE_SOURCE_BODY" : "")
                return .init(modelContext: content, included: included, omitted: omitted, validate: { [self] in
                    if fresh { freshValidations += 1 }
                    else { oldValidations += 1; guard oldSnapshotCurrent else { throw CancellationError() } }
                })
            }, admitReadback: { call, _, result in
                // Explicitly trusted inert constants only. Actual Store tests
                // below use the production selected-file proof callback.
                #expect(call.name == "read_file" && result.summary == "A fresh owned read")
                return {}
            }, reviewReason: { [self] _ in declineReview ? "Exact owned inert review" : nil },
            requestReview: { [self] _, _ in !declineReview },
            stepCheckpoint: checkpoint, stepContext: context)
        }
    }
}
