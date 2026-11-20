import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import RelayJournal

/// App-owned direct literal workflow. No model reply, image or restored event
/// can construct an executable preparation or its lexical dispatch seal.
@MainActor final class NativeExactUnsentOperation {
    enum Failure: Error, Equatable {
        case wrongOwner, wrongPhase, spent, expired, sourceChanged, nonemptyEditor
        case incompleteEffects, readbackMismatch, unavailableReadback, busy
    }

    nonisolated struct Identity: Sendable, Equatable {
        let logicalTaskID: UUID, runID: UUID, attemptID: UUID, proposalID: UUID, anchorID: UUID, requestID: UUID
        let sourceID: UUID
        let phase: NativeControlSession.ExactUnsentEffect.Phase
        let literalDigest: Data, callDigest: Data
        let call: ToolCall

        @MainActor init(scope: NativeVisualTaskScope, purpose: NativeExactUnsentPurpose,
                        sourceID: UUID, phase: NativeControlSession.ExactUnsentEffect.Phase) throws {
            try purpose.validateCurrent(scope: scope)
            logicalTaskID = scope.logicalTaskID; runID = scope.run.taskID; attemptID = scope.run.attemptID
            proposalID = purpose.objective.id; anchorID = purpose.objective.anchor.id
            self.sourceID = sourceID; self.phase = phase
            literalDigest = Data(SHA256.hash(data: Data(purpose.objective.literal.utf8)))
            let fields = [Data("relay.direct.exact-unsent.v1".utf8), Data(runID.uuidString.utf8),
                Data(attemptID.uuidString.utf8), Data(proposalID.uuidString.utf8), Data(anchorID.uuidString.utf8),
                Data(sourceID.uuidString.utf8), Data(phase.rawValue.utf8), literalDigest]
            var framed = Data()
            for field in fields {
                var length = UInt64(field.count).bigEndian
                Swift.withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
                framed.append(field)
            }
            let requestBytes = Data(SHA256.hash(data: framed).prefix(16))
            requestID = requestBytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            call = ToolCall(id: "direct-exact-unsent:" + requestID.uuidString,
                name: phase == .focus ? "native_exact_unsent_focus" : "native_exact_unsent_insert",
                arguments: ["anchor_id": .string(anchorID.uuidString), "source_id": .string(sourceID.uuidString),
                    "literal_sha256": .string(literalDigest.base64EncodedString()),
                    "literal_utf8_bytes": .string(String(purpose.objective.literal.utf8.count))])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            callDigest = Data(SHA256.hash(data: try encoder.encode(call)))
        }
    }

    /// Constructed only inside this operation's real inserted journal action.
    /// It cannot be encoded/recovered or minted from a caller's validation Bool.
    @MainActor final class DispatchSeal {
        let identity: Identity
        let invocationID: UUID
        private weak var operation: NativeExactUnsentOperation?
        private let source: NativeControlSession.ExactUnsentPreparation
        private var active = true
        fileprivate init(operation: NativeExactUnsentOperation, source: NativeControlSession.ExactUnsentPreparation,
                     identity: Identity, intent: JournalIntent) throws {
            guard intent.proposalID == identity.proposalID, intent.callDigest == identity.callDigest,
                  intent.toolCallID.bytes == Data(identity.call.id.utf8), intent.toolName == identity.call.name else {
                throw Failure.wrongPhase
            }
            self.operation = operation; self.source = source; self.identity = identity
            invocationID = intent.invocationID
        }
        func validate(source: NativeControlSession.ExactUnsentPreparation, identity: Identity) throws {
            guard active, self.source === source, self.identity == identity, let operation else { throw Failure.expired }
            try operation.validateCurrent()
        }
        fileprivate func retire() { active = false; operation = nil }
    }

    nonisolated struct ReadbackSample {
        let value: String, selectedText: String
        let caret: NSRange
        let attributed: NSAttributedString
    }
    /// Pure byte/range predicate only. It does not mint a source/certificate.
    static func requireExactReadback(_ sample: ReadbackSample, literal: String) throws -> NativeAttributedTextSnapshot {
        guard Data(sample.value.utf8) == Data(literal.utf8), sample.selectedText.isEmpty,
              sample.caret == NSRange(location: literal.utf16.count, length: 0) else { throw Failure.readbackMismatch }
        return try NativeAttributedTextSnapshot(sample.attributed, expectedValue: sample.value)
    }

    private let scope: NativeVisualTaskScope
    private let purpose: NativeExactUnsentPurpose
    private let authority: NativeLocalTaskInputAuthority
    private let history: AssistantConversationHistory
    private let recordFact: @MainActor (NativeControlSession.ExactUnsentEffect) -> Void
    private let publishCompletion: @MainActor (Completion) -> Void
    private let readAudit: NativeReadAudit?
    private let processStarted: (@Sendable (OwnedNativeComputerUseClient.ProcessStarted) throws -> Void)?
    private var stopped = false
    private var running = false
    private var activeRun: Task<Outcome, Error>?
    private var opening: Task<NativeVisualTaskConnection.ExactUnsentConnection, Error>?
    private var dispatches: Set<NativeControlSession.ExactUnsentEffect.Phase> = []
    private var startedPhases: Set<NativeControlSession.ExactUnsentEffect.Phase> = []
    private var reported: Set<ObjectIdentifier> = []
    private var connection: NativeVisualTaskConnection.ExactUnsentConnection?
    private var source: NativeControlSession.ExactUnsentPreparation?
    private var focusObserved: NativeControlSession.ExactUnsentEffect?
    private var insertionObserved: NativeControlSession.ExactUnsentEffect?
    private var focusSaved: (NativeControlSession.ExactUnsentEffect, AssistantConversationHistory.NativeTextEffectSettlement)?
    private var insertionSaved: (NativeControlSession.ExactUnsentEffect, AssistantConversationHistory.NativeTextEffectSettlement)?
    private var completion: Completion?

    enum Outcome: Sendable { case completed(Completion), needsStorageRepair, needsInput }
    enum DependencyAvailability: Sendable, Equatable { case available, accessibilityRequired, nativeRuntimeUnavailable }

    @MainActor final class Completion {
        let focus: NativeControlSession.ExactUnsentEffect
        let insertion: NativeControlSession.ExactUnsentEffect
        let verification: NativeControlSession.ExactUnsentVerification
        private weak var operation: NativeExactUnsentOperation?
        fileprivate init(operation: NativeExactUnsentOperation, focus: NativeControlSession.ExactUnsentEffect,
                     insertion: NativeControlSession.ExactUnsentEffect,
                     verification: NativeControlSession.ExactUnsentVerification) {
            self.operation = operation; self.focus = focus; self.insertion = insertion; self.verification = verification
        }
        func validateCurrent() throws {
            guard let operation, operation.completion === self else { throw Failure.expired }
            try operation.validatePublicationMetadata()
            guard let focusSaved = operation.focusSaved, let insertionSaved = operation.insertionSaved,
                  focusSaved.0 === focus, insertionSaved.0 === insertion else { throw Failure.incompleteEffects }
            try focusSaved.1.validate(effect: focus); try insertionSaved.1.validate(effect: insertion)
            try operation.requireCompleteCoverage(focus: focus, insertion: insertion, verification: verification)
        }
    }

    /// Actual operation-owned final handoff, not a validator from a caller.
    /// The readonly request invokes it synchronously after its LAST SDK check
    /// and before releasing the actual client FIFO.
    @MainActor final class CompletionTransport {
        private weak var operation: NativeExactUnsentOperation?
        private let source: NativeControlSession.ExactUnsentPreparation
        private let focus: NativeControlSession.ExactUnsentEffect
        private let insertion: NativeControlSession.ExactUnsentEffect
        private var used = false
        fileprivate private(set) var result: Completion?
        fileprivate private(set) var failure: (any Error)?
        fileprivate init(operation: NativeExactUnsentOperation, source: NativeControlSession.ExactUnsentPreparation,
                         focus: NativeControlSession.ExactUnsentEffect, insertion: NativeControlSession.ExactUnsentEffect) {
            self.operation = operation; self.source = source; self.focus = focus; self.insertion = insertion
        }
        func publish(_ verification: NativeControlSession.ExactUnsentVerification) {
            guard !used else { return }
            used = true
            guard let operation else { failure = Failure.expired; return }
            do {
                guard operation.source === source, verification.sourceID == source.sourceID else { throw Failure.wrongOwner }
                try operation.validatePublicationMetadata()
                try operation.requireCompleteCoverage(focus: focus, insertion: insertion, verification: verification)
                let actual = Completion(operation: operation, focus: focus, insertion: insertion, verification: verification)
                operation.completion = actual
                do { try actual.validateCurrent() }
                catch { operation.completion = nil; throw error }
                result = actual
                // No SDK, IO, await, Boolean authority or action below these
                // fences. Store's transport publishes closed past-tense facts.
                operation.publishCompletion(actual)
            } catch { failure = error }
        }
    }

    init(scope: NativeVisualTaskScope, purpose: NativeExactUnsentPurpose,
         authority: NativeLocalTaskInputAuthority, history: AssistantConversationHistory,
         readAudit: NativeReadAudit? = nil,
         processStarted: (@Sendable (OwnedNativeComputerUseClient.ProcessStarted) throws -> Void)? = nil,
         publishCompletion: @escaping @MainActor (Completion) -> Void,
         recordFact: @escaping @MainActor (NativeControlSession.ExactUnsentEffect) -> Void = { _ in }) throws {
        guard case .directExactUnsent = scope.executionKind, authority.scope === scope,
              case .initialExactUnsent(let adopted) = authority.windowRequirement, adopted === purpose else { throw Failure.wrongOwner }
        self.scope = scope; self.purpose = purpose; self.authority = authority; self.history = history
        self.recordFact = recordFact
        self.publishCompletion = publishCompletion
        self.readAudit = readAudit; self.processStarted = processStarted
        try validateCurrent()
    }
    static func dependencyAvailability() -> DependencyAvailability {
        guard AXIsProcessTrusted() else { return .accessibilityRequired }
        return (try? OwnedNativeComputerUseClient.Runtime.discover()) == nil ? .nativeRuntimeUnavailable : .available
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; scope.stop(); opening?.cancel(); activeRun?.cancel(); connection?.stop()
    }
    func drain() async {
        if let activeRun { _ = try? await activeRun.value }
        if let opening {
            let late = try? await opening.value
            late?.stop(); await late?.drain()
        }
        await connection?.drain()
    }

    /// Each call advances a finite current operation. A pending saved-result
    /// callback may update its facts after explicit storage-only repair; it
    /// never starts this method or remints a phase by itself.
    func run() async throws -> Outcome {
        guard activeRun == nil, !running else { throw Failure.busy }
        let task = Task { @MainActor in try await self.advance() }
        activeRun = task
        defer { activeRun = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in self?.stop() }
        }
    }
    private func advance() async throws -> Outcome {
        running = true; defer { running = false }
        if let completion { try completion.validateCurrent(); return .completed(completion) }
        try validateCurrent()
        if connection == nil {
            let task = Task { @MainActor [scope, purpose, authority, readAudit, processStarted] in
                try await NativeVisualTaskConnection.openExactUnsent(scope: scope, purpose: purpose, authority: authority,
                    readAudit: readAudit, processStarted: processStarted)
            }
            opening = task
            let opened: NativeVisualTaskConnection.ExactUnsentConnection
            do { opened = try await task.value; opening = nil }
            catch { opening = nil; throw error }
            do { try validateCurrent(); connection = opened }
            catch { opened.stop(); await opened.drain(); throw error }
        }
        guard let connection else { throw Failure.wrongOwner }
        if source == nil { source = try await connection.prepare(); try validateCurrent() }
        guard let source else { throw Failure.wrongOwner }
        if focusSaved == nil {
            if startedPhases.contains(.focus) { return focusObserved == nil ? .needsInput : .needsStorageRepair }
            let identity = try Identity(scope: scope, purpose: purpose, sourceID: source.sourceID, phase: .focus)
            startedPhases.insert(.focus)
            do {
                let saved = try await history.performNativeTextEffect(identity.call, proposalID: identity.proposalID,
                    phase: .focus, run: scope.run, validate: { [weak self] in
                        guard let self else { throw Failure.expired }; try self.validateCurrent()
                    }, action: { [self] intent in
                        guard dispatches.insert(.focus).inserted else { throw Failure.spent }
                        let seal = try DispatchSeal(operation: self, source: source, identity: identity, intent: intent)
                        defer { seal.retire() }
                        let actual = try await connection.restoreFocus(source, identity: identity, dispatch: seal)
                        focusObserved = actual; publishFact(actual); return actual
                    }, unsavedEffect: { [weak self] effect in self?.observe(effect, identity: identity) },
                    settledEffect: { [weak self] effect, token in self?.settled(effect, token: token, identity: identity) })
                settled(saved.effect, token: saved.settlement, identity: identity)
            } catch {
                if stopped || Task.isCancelled { throw CancellationError() }
                if focusObserved != nil, focusSaved == nil { return .needsStorageRepair }
                throw error
            }
        }
        try validateCurrent()
        guard let focusSaved else { return .needsStorageRepair }
        try focusSaved.1.validate(effect: focusSaved.0)
        guard case .focus(let focus) = focusSaved.0.outcome, focus.verified else { return .needsInput }
        if insertionSaved == nil {
            if startedPhases.contains(.insertion) { return insertionObserved == nil ? .needsInput : .needsStorageRepair }
            try await connection.prepareInsertion(source, focus: focusSaved.0, saved: focusSaved.1)
            try validateCurrent()
            let identity = try Identity(scope: scope, purpose: purpose, sourceID: source.sourceID, phase: .insertion)
            startedPhases.insert(.insertion)
            do {
                let saved = try await history.performNativeTextEffect(identity.call, proposalID: identity.proposalID,
                    phase: .insertion, run: scope.run, validate: { [weak self] in
                        guard let self else { throw Failure.expired }; try self.validateCurrent()
                    }, action: { [self] intent in
                        guard dispatches.insert(.insertion).inserted else { throw Failure.spent }
                        let seal = try DispatchSeal(operation: self, source: source, identity: identity, intent: intent)
                        defer { seal.retire() }
                        let actual = try await connection.insert(source, identity: identity, dispatch: seal)
                        insertionObserved = actual; publishFact(actual); return actual
                    }, unsavedEffect: { [weak self] effect in self?.observe(effect, identity: identity) },
                    settledEffect: { [weak self] effect, token in self?.settled(effect, token: token, identity: identity) })
                settled(saved.effect, token: saved.settlement, identity: identity)
            } catch {
                if stopped || Task.isCancelled { throw CancellationError() }
                if insertionObserved != nil, insertionSaved == nil { return .needsStorageRepair }
                throw error
            }
        }
        try validateCurrent()
        guard let insertionSaved else { return .needsStorageRepair }
        try insertionSaved.1.validate(effect: insertionSaved.0)
        guard case .insertion(.inserted) = insertionSaved.0.outcome else { return .needsInput }
        let transport = CompletionTransport(operation: self, source: source, focus: focusSaved.0, insertion: insertionSaved.0)
        do {
            _ = try await connection.verify(source, focus: focusSaved.0, insertion: insertionSaved.0,
                focusSaved: focusSaved.1, insertionSaved: insertionSaved.1, publication: transport)
        } catch is CancellationError { throw CancellationError() }
        catch { try validatePublicationMetadata(); return .needsInput }
        if let failure = transport.failure { throw failure }
        guard let actual = transport.result else { throw Failure.incompleteEffects }
        // Publication already happened inside the readonly reservation. Do
        // not add an actor-return gap, new AX read or post-publication veto.
        return .completed(actual)
    }

    private func publishFact(_ effect: NativeControlSession.ExactUnsentEffect) {
        if reported.insert(ObjectIdentifier(effect)).inserted { recordFact(effect) }
    }
    private func observe(_ effect: NativeControlSession.ExactUnsentEffect, identity: Identity) {
        guard effect.identity == identity else { return }
        if identity.phase == .focus { focusObserved = effect } else { insertionObserved = effect }
        publishFact(effect)
    }
    private func settled(_ effect: NativeControlSession.ExactUnsentEffect,
                         token: AssistantConversationHistory.NativeTextEffectSettlement, identity: Identity) {
        guard effect.identity == identity else { return }
        do { try token.validate(effect: effect) } catch { return }
        observe(effect, identity: identity)
        if identity.phase == .focus { focusSaved = (effect, token) } else { insertionSaved = (effect, token) }
    }
    private func requireCompleteCoverage(focus: NativeControlSession.ExactUnsentEffect,
        insertion: NativeControlSession.ExactUnsentEffect, verification: NativeControlSession.ExactUnsentVerification) throws {
        guard focus.phase == .focus, insertion.phase == .insertion,
              focus.runID == scope.run.taskID, insertion.runID == scope.run.taskID,
              focus.attemptID == scope.run.attemptID, insertion.attemptID == scope.run.attemptID,
              focus.proposalID == purpose.objective.id, insertion.proposalID == purpose.objective.id,
              focus.anchorID == purpose.objective.anchor.id, insertion.anchorID == purpose.objective.anchor.id,
              focus.literalDigest == insertion.literalDigest,
              case .focus(let actual) = focus.outcome, actual.verified,
              actual.steps.count <= 3, Set(actual.steps.map(\.step)).count == actual.steps.count,
              actual.steps.allSatisfy({ $0.state == .returned }),
              case .insertion(.inserted) = insertion.outcome,
              verification.focusRequestID == focus.requestID, verification.insertionRequestID == insertion.requestID,
              verification.literalDigest == insertion.literalDigest,
              verification.utf16Count == purpose.objective.literal.utf16.count,
              dispatches == [.focus, .insertion] else { throw Failure.incompleteEffects }
    }
    private func validateCurrent() throws {
        guard !stopped else { throw NativeVisualTaskFailure.stopped }
        try scope.validate(); try authority.validate(); try purpose.validateCurrent(scope: scope); try scope.validate()
    }
    /// Genuine Store/ACK metadata checks only. Source/private SDK predicates
    /// have already finished inside the actual readonly FIFO request.
    private func validatePublicationMetadata() throws {
        guard !stopped else { throw NativeVisualTaskFailure.stopped }
        try scope.validate(); try purpose.validateAcknowledgmentMetadata(scope: scope); try scope.validate()
    }
}

extension NativeControlSession.ExactUnsentEffect {
    var genericFact: ToolResult {
        switch outcome {
        case .focus(let report):
            return ToolResult(summary: report.verified ? "The original window was focused." : "The original focus could not be verified.",
                evidence: report.steps.isEmpty ? "No focus operation was admitted." : "The recorded focus outcome is retained. It will not be repeated automatically.",
                verified: report.verified)
        case .insertion(let value):
            let summary: String, verified: Bool
            switch value {
            case .inserted: summary = "The text was inserted and checked locally."; verified = true
            case .unchanged: summary = "No text change was made."; verified = false
            case .notDispatched: summary = "No text insertion was admitted."; verified = false
            case .uncertain: summary = "The text insertion outcome is uncertain."; verified = false
            }
            return ToolResult(summary: summary,
                evidence: "The recorded outcome is retained. Independent original-editor verification is required; no action is repeated.", verified: verified)
        }
    }
    var journalKind: JournalOutcomeKind {
        switch outcome {
        case .focus(let report):
            return report.verified ? .returnedVerified : (report.steps.isEmpty ? .notDispatched : .effectUncertain)
        case .insertion(let result):
            switch result {
            case .inserted: return .returnedVerified
            case .notDispatched: return .notDispatched
            case .unchanged: return .returnedUnverified
            case .uncertain: return .effectUncertain
            }
        }
    }
}
