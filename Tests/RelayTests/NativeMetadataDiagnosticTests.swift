import ApplicationServices
import Foundation
import Testing
@testable import Relay

@MainActor @Suite struct NativeMetadataDiagnosticTests {
    private typealias Audit = NativeReadAudit

    private func sample(phase: Audit.MetadataPhase = .revalidation,
                        origin: Audit.MetadataOrigin = .optionalFlag) -> Audit.MetadataDiagnostic {
        .init(phase: phase, origin: origin, attribute: .containsProtectedContentOptional,
            role: .button, status: .attributeUnsupported, valueType: .missing, advertised: false)
    }

    @Test func nilAuditSkipsDiagnosticConstructionAndExistingSampleCallsRemainCompatible() throws {
        var constructions = 0
        func diagnostic() -> Audit.MetadataDiagnostic { constructions += 1; return sample() }
        Audit.incompleteMetadata(nil, diagnostic())
        #expect(constructions == 0)
        let samples = Samples(), audit = Audit { samples.record($0) }
        Audit.incompleteMetadata(audit, diagnostic())
        #expect(constructions == 1)
        let actual = try #require(samples.values.first)
        #expect(samples.values.count == 1 && actual.stage == .policyMetadataIncompleteReason)
        #expect(actual.elapsed == .zero && actual.metadata == sample())
        #expect(Audit.Sample(stage: .policyMetadata, elapsed: .zero).metadata == nil)
    }

    @Test func diagnosticsUseOneAlreadyReturnedMetadataResultWithoutRepeatingItsOperation() {
        var operations = 0
        let samples = Samples(), enabled = Audit { samples.record($0) }
        let audits: [Audit?] = [nil, enabled]
        for audit in audits {
            let result: (AXError, CFTypeRef?) = Audit.measure(audit, .policyMetadata) {
                operations += 1
                return (.noValue, nil)
            }
            Audit.incompleteMetadata(audit, .init(phase: .revalidation, origin: .optionalText,
                attribute: .subroleOptional, role: .textField, status: .init(result.0),
                valueType: .init(result.1), advertised: false))
            #expect(result.0 == .noValue && result.1 == nil)
        }
        #expect(operations == 2)
        #expect(samples.values.map(\.stage) == [.policyMetadata, .policyMetadataIncompleteReason])
        #expect(samples.values.last?.metadata?.status == .noValue)
        #expect(samples.values.last?.metadata?.valueType == .missing)
    }

    @Test func closedSerializationContainsNoUntrustedRoleAttributeOrStringValue() throws {
        let marker = "UNTRUSTED-SOURCE-LABEL-do-not-retain"
        let raw: CFString = marker as CFString
        let diagnosis = Audit.MetadataDiagnostic(phase: .initialCapture, origin: .unsupportedRoleOrSubrole,
            attribute: .init(marker), role: .init(marker), status: .init(.failure),
            valueType: .init(raw), advertised: true)
        let data = try JSONEncoder().encode(diagnosis)
        let decoded = try JSONDecoder().decode(Audit.MetadataDiagnostic.self, from: data)
        #expect(decoded == diagnosis && decoded.attribute == .otherMetadata && decoded.role == .other)
        #expect(decoded.status == .failure && decoded.valueType == .string)
        #expect(!String(decoding: data, as: UTF8.self).contains(marker))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["phase", "origin", "attribute", "role", "status", "valueType", "advertised"])
        #expect(data.count < 512)
    }

    @Test func unknownEnumPayloadIsRejectedRatherThanRetainedAsFreeText() throws {
        let data = try JSONEncoder().encode(sample())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["phase", "origin", "attribute", "role", "status", "valueType"] {
            var changed = object
            changed[key] = "arbitrary-source-text"
            let encoded = try JSONSerialization.data(withJSONObject: changed)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(Audit.MetadataDiagnostic.self, from: encoded)
            }
        }
        object["advertised"] = "not-a-boolean"
        let encoded = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Audit.MetadataDiagnostic.self, from: encoded) }
    }

    @Test func actualDiagnosticBufferBoundsStorageAndReportsOmissionWithoutAWorkLimit() throws {
        var buffer = Audit.MetadataBuffer()
        for _ in 0..<1_100 { buffer.append(sample()) }
        #expect(buffer.samples.count == 64 && buffer.omitted == 1_036)
        #expect(buffer.samples.allSatisfy { $0 == sample() })
        let data = try JSONEncoder().encode(buffer.samples)
        #expect(data.count < 32_768)
        #expect(try JSONDecoder().decode([Audit.MetadataDiagnostic].self, from: data) == buffer.samples)
    }

    @Test func scanPhasesAndEveryOriginRemainFiniteRoundTrippableTechnicalCases() throws {
        for phase in Audit.MetadataPhase.allCases {
            for origin in Audit.MetadataOrigin.allCases {
                let actual = sample(phase: phase, origin: origin)
                let data = try JSONEncoder().encode(actual)
                #expect(data.count < 512)
                #expect(try JSONDecoder().decode(Audit.MetadataDiagnostic.self, from: data) == actual)
            }
        }
        #expect(Audit.MetadataStatus(.success) == .success)
        #expect(Audit.MetadataStatus(.noValue) == .noValue)
        #expect(Audit.MetadataStatus(.attributeUnsupported) == .attributeUnsupported)
        #expect(Audit.MetadataStatus(.cannotComplete) == .cannotComplete)
        #expect(Audit.MetadataStatus(.invalidUIElement) == .invalidElement)
        #expect(Audit.MetadataValueType(nil) == .missing)
        #expect(Audit.MetadataValueType(kCFBooleanFalse) == .boolean)
        #expect(Audit.MetadataValueType(NSNumber(value: 3)) == .number)
        #expect(Audit.MetadataValueType(NSArray()) == .array)
    }

    nonisolated private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Audit.Sample] = []
        var values: [Audit.Sample] { lock.lock(); defer { lock.unlock() }; return storage }
        func record(_ value: Audit.Sample) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    }
}
