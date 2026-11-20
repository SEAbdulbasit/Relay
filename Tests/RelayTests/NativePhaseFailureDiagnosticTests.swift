import Foundation
import Testing
@testable import Relay

@MainActor @Suite struct NativePhaseFailureDiagnosticTests {
    private typealias Audit = NativeReadAudit

    @Test func exclusivityRefusalsKeepClosedTechnicalCauseAndStrongExitPrecedence() throws {
        let cases: [(TargetBoundNativeObservation.Failure, Audit.PolicyFailureCode)] = [
            (.missingExclusiveApplication, .missingExclusiveApplication),
            (.multipleExclusiveApplications, .multipleExclusiveApplications),
            (.changedExclusiveApplication, .changedExclusiveApplication)]
        for (failure, code) in cases {
            let samples = Samples(), audit = Audit { samples.record($0) }
            var boundaries = 0
            #expect(throws: failure) {
                try NativeMetadataPhase.run(deadline: .now.advanced(by: .milliseconds(750)), boundary: {
                    boundaries += 1
                    if boundaries == 2 { throw failure }
                }, query: {}, readAudit: audit) { _ in
                    throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
                }
            }
            #expect(boundaries == 2)
            #expect(samples.values.compactMap { $0.metadata?.failure } == [
                .init(domain: .policy, code: .protectedContext), .init(domain: .observer, code: code)])
            for sample in samples.values {
                let value = try #require(sample.metadata)
                let data = try JSONEncoder().encode(value)
                #expect(data.count < 512)
                #expect(try JSONDecoder().decode(Audit.MetadataDiagnostic.self, from: data) == value)
            }
        }
    }

    @Test func unchangedExitPreservesProtectedBodyAndRecordsItsActualLocation() throws {
        let samples = Samples(), audit = Audit { samples.record($0) }
        var boundaries = 0, queries = 0
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) {
            try NativeMetadataPhase.run(deadline: .now.advanced(by: .milliseconds(750)), boundary: {
                boundaries += 1
            }, query: { queries += 1 }, readAudit: audit) { phase in
                try phase.check(); throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
            }
        }
        #expect(boundaries == 2 && queries == 1)
        let records = samples.values
        #expect(records.count == 1 && records[0].stage == .policyMetadataPhaseFailure)
        #expect(records[0].metadata?.origin == .phaseBodyRefusal)
        #expect(records[0].metadata?.failure == .init(domain: .policy, code: .protectedContext))
    }

    @Test func strongExitKeepsPrecedenceAndSeparatelyReportsTheEarlierProtectedBody() throws {
        let samples = Samples(), audit = Audit { samples.record($0) }
        var boundaries = 0
        #expect(throws: TargetBoundNativeObservation.Failure.changedTarget) {
            try Audit.inspectPolicy(audit) {
                try NativeMetadataPhase.run(deadline: .now.advanced(by: .milliseconds(750)), boundary: {
                    boundaries += 1
                    if boundaries == 2 { throw TargetBoundNativeObservation.Failure.changedTarget }
                }, query: {}, readAudit: audit) { _ in
                    throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
                }
            }
        }
        let records = samples.values
        #expect(boundaries == 2)
        #expect(records.map(\.stage) == [.policyMetadataPhaseFailure, .policyMetadataPhaseFailure, .policyOtherRefusal])
        #expect(records.compactMap { $0.metadata?.origin } == [.phaseBodyRefusal, .phaseExitRefusal, .policyInspectionRefusal])
        #expect(records.compactMap { $0.metadata?.failure } == [
            .init(domain: .policy, code: .protectedContext),
            .init(domain: .observer, code: .changedTarget), .init(domain: .observer, code: .changedTarget)])
    }

    @Test func failedEntryStillRunsStrongExitAndNeverRunsItsBody() throws {
        let samples = Samples(), audit = Audit { samples.record($0) }
        var boundaries = 0, bodies = 0, queries = 0
        #expect(throws: NativeVisualTaskFailure.staleTask) {
            try NativeMetadataPhase.run(deadline: .now.advanced(by: .milliseconds(750)), boundary: {
                boundaries += 1; throw NativeVisualTaskFailure.staleTask
            }, query: { queries += 1 }, readAudit: audit) { _ in bodies += 1 }
        }
        #expect(boundaries == 2 && bodies == 0 && queries == 0)
        #expect(samples.values.compactMap { $0.metadata?.origin } == [.phaseEntryRefusal, .phaseExitRefusal])
        #expect(samples.values.allSatisfy { $0.metadata?.failure == .init(domain: .scope, code: .staleTask) })
    }

    @Test func nilAuditPreservesCallbacksAndExactThrownObjectWithoutDiagnostics() throws {
        let original = MarkerError()
        var boundaries = 0, bodies = 0, queries = 0
        do {
            try NativeMetadataPhase.run(deadline: .now.advanced(by: .milliseconds(750)), boundary: {
                boundaries += 1
            }, query: { queries += 1 }) { phase in
                bodies += 1; try phase.check(); throw original
            }
            Issue.record("Expected the original body error")
        } catch { #expect((error as? MarkerError) === original) }
        #expect(boundaries == 2 && bodies == 1 && queries == 1)
    }

    @Test func associatedReasonsAndUnknownNSErrorFieldsCannotEnterClosedRecords() throws {
        let secret = "UNTRUSTED-ROLE-PATH-BODY-DO-NOT-RETAIN"
        let errors: [any Error] = [NativeVisualTaskFailure.dedicatedWorkflow(secret),
            NativeVisualTaskFailure.noInput(secret), NSError(domain: secret, code: 7,
                userInfo: [NSLocalizedDescriptionKey: secret])]
        let samples = Samples(), audit = Audit { samples.record($0) }
        for error in errors { Audit.recordPhaseFailure(audit, origin: .phaseBodyRefusal, error: error) }
        #expect(samples.values.compactMap { $0.metadata?.failure } == [
            .init(domain: .scope, code: .dedicatedWorkflow), .init(domain: .scope, code: .noInput),
            .init(domain: .unknown, code: .unknown)])
        for record in samples.values {
            let metadata = try #require(record.metadata), data = try JSONEncoder().encode(metadata)
            #expect(data.count < 512 && !String(decoding: data, as: UTF8.self).contains(secret))
            #expect(try JSONDecoder().decode(Audit.MetadataDiagnostic.self, from: data) == metadata)
        }
    }

    @Test func oldSevenFieldJSONIsPreservedAndUnknownFailurePayloadIsRejected() throws {
        let old = Audit.MetadataDiagnostic(phase: .initialCapture, origin: .optionalFlag,
            attribute: .hiddenOptional, role: .textField, status: .noValue, valueType: .missing, advertised: false)
        let data = try JSONEncoder().encode(old)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["phase", "origin", "attribute", "role", "status", "valueType", "advertised"])
        #expect(try JSONDecoder().decode(Audit.MetadataDiagnostic.self, from: data) == old)
        object["failure"] = ["domain": "arbitrary-private-string", "code": "unknown"]
        let unknownDomain = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Audit.MetadataDiagnostic.self, from: unknownDomain) }
        object["failure"] = ["domain": "observer", "code": "arbitrary-private-string"]
        let unknownCode = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Audit.MetadataDiagnostic.self, from: unknownCode) }
    }

    @Test func typedCancellationBudgetReadAndControllerFailuresStayDistinct() {
        let pairs: [(any Error, Audit.PolicyFailure)] = [
            (NativeMetadataPhase.Failure.expired, .init(domain: .phase, code: .expired)),
            (CancellationError(), .init(domain: .cancellation, code: .cancelled)),
            (TaskRunBudget.Limit.activeWork, .init(domain: .budget, code: .activeWork)),
            (TaskRunBudget.Limit.lifetime, .init(domain: .budget, code: .lifetime)),
            (NativeWindowTaskAdapter.Failure.unadmittedApplication, .init(domain: .read, code: .unadmittedApplication)),
            (NativeControlSession.Failure.wrongOwner, .init(domain: .controller, code: .wrongOwner))]
        for (error, expected) in pairs { #expect(Audit.classifyPolicyFailure(error) == expected) }
    }

    @Test func diagnosticsCannotRenewTheAbsoluteDeadlineOrRunAnExpiredBody() throws {
        let samples = Samples(), audit = Audit { samples.record($0) }
        let start = ContinuousClock.now
        var now = start, boundaries = 0, bodies = 0
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeMetadataPhase.run(deadline: start.advanced(by: .milliseconds(750)), boundary: {
                boundaries += 1; now = start.advanced(by: .milliseconds(751))
            }, query: {}, readAudit: audit, now: { now }) { _ in bodies += 1 }
        }
        #expect(boundaries == 2 && bodies == 0)
        #expect(samples.values.filter { $0.stage == .policyDeadlineRefusal }.count == 2)
        #expect(samples.values.compactMap { $0.metadata?.failure } == [
            .init(domain: .policy, code: .incomplete), .init(domain: .policy, code: .incomplete)])
    }

    private final class MarkerError: Error {}
    nonisolated private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Audit.Sample] = []
        var values: [Audit.Sample] { lock.withLock { storage } }
        func record(_ value: Audit.Sample) { lock.withLock { storage.append(value) } }
    }
}
