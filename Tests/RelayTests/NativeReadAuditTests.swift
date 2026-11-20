import Foundation
import Testing
@testable import Relay

@Suite struct NativeReadAuditTests {
    private enum SyntheticFailure: Error, Equatable { case expected }
    nonisolated private final class OriginalFailure: Error {}
    @Test func metadataCostStagesPreserveValuesErrorIdentityAndNilBehaviorWithoutPayloads() throws {
        let samples = Samples(), audit = NativeReadAudit { samples.record($0) }
        let stages: [NativeReadAudit.Stage] = [.policyMetadataReferenceValidation, .policyMetadataScopeAuthorization,
            .policyMetadataSealedScope, .policyMetadataOpaqueScope,
            .retainedEditorIdentityValidation, .retainedEditorOwnerValidation, .retainedEditorProcessValidation,
            .retainedEditorPIDValidation, .retainedEditorFocusedWindowRead, .retainedEditorFocusedEditorRead, .retainedEditorWindowRead,
            .retainedWindowInfoValidation, .retainedWindowInfoRequiredBatchRead, .retainedWindowInfoOptionalAttributesRead,
            .retainedUniqueWindowValidation, .retainedUniqueWindowListRead, .retainedUniqueWindowTitleRead, .retainedUniqueWindowCurrentValidation]
        let original = OriginalFailure()
        for stage in stages {
            let value = try NativeReadAudit.measure(audit, stage) { () throws -> Int in 17 }
            #expect(value == 17)
            do { _ = try NativeReadAudit.measure(audit, stage) { () throws -> Int in throw original }; Issue.record("Audit swallowed the actual error") }
            catch { #expect((error as? OriginalFailure) === original) }
            let nilValue = NativeReadAudit.measure(nil, stage) { 23 }
            #expect(nilValue == 23)
        }
        #expect(samples.snapshot().map(\.stage) == stages.flatMap { [$0, $0] })
        #expect(samples.snapshot().allSatisfy { $0.metadata == nil && $0.elapsed >= .zero })
    }
    @Test func finiteAuditObservesAttemptsAndPreservesReturnedValuesAndOriginalErrors() throws {
        let samples = Samples()
        let audit = NativeReadAudit { samples.record($0) }
        let result = NativeReadAudit.measure(audit, .policyMetadata) { 42 }
        #expect(result == 42)
        #expect(throws: SyntheticFailure.expected) {
            try NativeReadAudit.measure(audit, .editorValue) { throw SyntheticFailure.expected }
        }
        #expect(samples.snapshot().map(\.stage) == [.policyMetadata, .editorValue])
        #expect(samples.snapshot().allSatisfy { $0.elapsed >= .zero })
        let nilResult = NativeReadAudit.measure(nil, .nativeStateWriteAttempt) { 7 }
        #expect(nilResult == 7 && samples.snapshot().count == 2)
        #expect(throws: SyntheticFailure.expected) {
            try NativeReadAudit.measure(nil, .editorStyle) { throw SyntheticFailure.expected }
        }
    }
    /// Sendable sink stores only the finite samples passed by the audit. This
    /// synchronization is diagnostics-only, never a source/admission gate.
    nonisolated private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [NativeReadAudit.Sample] = []
        func record(_ sample: NativeReadAudit.Sample) { lock.lock(); defer { lock.unlock() }; values.append(sample) }
        func snapshot() -> [NativeReadAudit.Sample] { lock.lock(); defer { lock.unlock() }; return values }
    }
}
