import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Relay

/// Tests the actual-used single-control 3-label batch decoder and pre/post fence
/// orchestration using in-memory CoreFoundation values and closure seams only.
@MainActor @Suite struct NativeControlLabelBatchTests {
    private typealias Batch = NativeControlLabelBatch
    private typealias Policy = NativeOrdinaryWindowPolicySource

    private struct RecordedIncomplete: Equatable {
        let origin: NativeReadAudit.MetadataOrigin
        let attribute: NativeReadAudit.MetadataAttribute
        let status: NativeReadAudit.MetadataStatus
        let valueType: NativeReadAudit.MetadataValueType
        let advertised: Bool?
    }

    nonisolated private final class IncompleteCollector {
        var values: [RecordedIncomplete] = []
    }

    private func boxedError(_ status: AXError) throws -> AXValue {
        try #require(Batch.boxedError(status))
    }

    private func recordIncomplete(_ collector: IncompleteCollector) -> Batch.IncompleteRecorder {
        { origin, name, status, value, advertised in
            collector.values.append(
                RecordedIncomplete(
                    origin: origin,
                    attribute: name.map(NativeReadAudit.MetadataAttribute.init) ?? .structural,
                    status: status.map(NativeReadAudit.MetadataStatus.init) ?? .notApplicable,
                    valueType: status == nil ? .notApplicable : .init(value),
                    advertised: advertised
                )
            )
            return .incomplete
        }
    }

    @Test func attributeOrderAndUnsortedSlotJoiningRemainExact() throws {
        #expect(Batch.attributeNames == [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute])
        let slots: [AnyObject] = ["Zebra" as CFString, "Alpha" as CFString, "Middle" as CFString]
        let joined = try Batch.decode(
            status: .success,
            rawValues: slots as CFArray,
            advertisedNames: Set(Batch.attributeNames)
        )
        #expect(joined == "Zebra Alpha Middle")
    }

    @Test func boxedNoValueAndUnadvertisedUnsupportedAreAbsentWhileAdvertisedUnsupportedRefusesAll() throws {
        let noValue = try boxedError(.noValue)
        let unsupported = try boxedError(.attributeUnsupported)

        // Boxed .noValue is absent whether advertised or unadvertised.
        let withNoValue: [AnyObject] = ["Save" as CFString, noValue, "doc.save" as CFString]
        let decodedNoValue = try Batch.decode(
            status: .success,
            rawValues: withNoValue as CFArray,
            advertisedNames: Set(Batch.attributeNames)
        )
        #expect(decodedNoValue == "Save doc.save")

        // All 3 slots absent yields empty string.
        let allAbsent: [AnyObject] = [noValue, unsupported, noValue]
        let empty = try Batch.decode(
            status: .success,
            rawValues: allAbsent as CFArray,
            advertisedNames: [kAXTitleAttribute, kAXIdentifierAttribute]
        )
        #expect(empty.isEmpty)

        // Boxed .attributeUnsupported when advertised in any slot refuses the entire batch.
        let expectedAttributes: [NativeReadAudit.MetadataAttribute] = [
            .titleOptional,
            .descriptionOptional,
            .identifierOptional,
        ]
        for (slotIndex, name) in Batch.attributeNames.enumerated() {
            var slots: [AnyObject] = ["Title" as CFString, "Description" as CFString, "Identifier" as CFString]
            slots[slotIndex] = unsupported
            let diagnostics = IncompleteCollector()
            #expect(throws: Policy.Failure.incomplete) {
                _ = try Batch.decode(
                    status: .success,
                    rawValues: slots as CFArray,
                    advertisedNames: [name],
                    incomplete: recordIncomplete(diagnostics)
                )
            }
            #expect(diagnostics.values == [
                RecordedIncomplete(
                    origin: .labelValue,
                    attribute: expectedAttributes[slotIndex],
                    status: .attributeUnsupported,
                    valueType: .missing,
                    advertised: true
                )
            ])
        }
    }

    @Test func boxedErrorsMalformedAXValuesCFNullNonStringsWrongCountsAndTopLevelFailuresRefuseAll() throws {
        let hardErrors: [AXError] = [
            .cannotComplete,
            .invalidUIElement,
            .apiDisabled,
            .failure,
            .illegalArgument,
            .notImplemented,
        ]
        for error in hardErrors {
            let boxed = try boxedError(error)
            for slotIndex in 0..<3 {
                var slots: [AnyObject] = ["ValidTitle" as CFString, "ValidDesc" as CFString, "ValidID" as CFString]
                slots[slotIndex] = boxed
                let diagnostics = IncompleteCollector()
                #expect(throws: Policy.Failure.incomplete) {
                    _ = try Batch.decode(
                        status: .success,
                        rawValues: slots as CFArray,
                        advertisedNames: [],
                        incomplete: recordIncomplete(diagnostics)
                    )
                }
                #expect(diagnostics.values.count == 1)
                #expect(diagnostics.values.first?.origin == .labelValue)
                #expect(diagnostics.values.first?.status == NativeReadAudit.MetadataStatus(error))
                #expect(diagnostics.values.first?.valueType == .missing)
            }
        }

        // Boxed .success inside an .axError wrapper is malformed and refused.
        let boxedSuccess = try boxedError(.success)
        #expect(throws: Policy.Failure.incomplete) {
            _ = try Batch.decode(
                status: .success,
                rawValues: ([boxedSuccess, "Desc" as CFString, "ID" as CFString] as [AnyObject]) as CFArray,
                advertisedNames: []
            )
        }

        // Non-error AXValue (e.g. .cgPoint) in any slot is refused.
        var point = CGPoint(x: 1, y: 2)
        let pointValue = try #require(AXValueCreate(.cgPoint, &point))
        let pointDiagnostics = IncompleteCollector()
        #expect(throws: Policy.Failure.incomplete) {
            _ = try Batch.decode(
                status: .success,
                rawValues: (["Title" as CFString, pointValue, "ID" as CFString] as [AnyObject]) as CFArray,
                advertisedNames: [kAXDescriptionAttribute],
                incomplete: recordIncomplete(pointDiagnostics)
            )
        }
        #expect(pointDiagnostics.values == [
            RecordedIncomplete(
                origin: .labelValue,
                attribute: .descriptionOptional,
                status: .success,
                valueType: .axValue,
                advertised: true
            )
        ])

        // CFNull, CFNumber, CFBoolean and nested CFArray in any slot are refused.
        let invalidNull: CFNull = kCFNull
        let invalidNumber: CFNumber = NSNumber(value: 42)
        let invalidBoolean: CFBoolean = kCFBooleanTrue
        let invalidArray: CFArray = (["nested" as CFString] as [AnyObject]) as CFArray
        let invalidObjects: [(CFTypeRef, NativeReadAudit.MetadataValueType)] = [
            (invalidNull, .other),
            (invalidNumber, .number),
            (invalidBoolean, .boolean),
            (invalidArray, .array),
        ]
        for (invalid, expectedType) in invalidObjects {
            let diagnostics = IncompleteCollector()
            #expect(throws: Policy.Failure.incomplete) {
                _ = try Batch.decode(
                    status: .success,
                    rawValues: (["Title" as CFString, "Desc" as CFString, invalid] as [AnyObject]) as CFArray,
                    advertisedNames: [kAXIdentifierAttribute],
                    incomplete: recordIncomplete(diagnostics)
                )
            }
            #expect(diagnostics.values == [
                RecordedIncomplete(
                    origin: .labelValue,
                    attribute: .identifierOptional,
                    status: .success,
                    valueType: expectedType,
                    advertised: true
                )
            ])
        }

        // Top-level AXError != .success, nil rawValues, non-array rawValues and wrong slot counts refuse all.
        for topStatus in [AXError.cannotComplete, .invalidUIElement, .failure, .noValue, .attributeUnsupported] {
            let diagnostics = IncompleteCollector()
            #expect(throws: Policy.Failure.incomplete) {
                _ = try Batch.decode(
                    status: topStatus,
                    rawValues: (["A" as CFString, "B" as CFString, "C" as CFString] as [AnyObject]) as CFArray,
                    advertisedNames: Set(Batch.attributeNames),
                    incomplete: recordIncomplete(diagnostics)
                )
            }
            #expect(diagnostics.values.first?.status == NativeReadAudit.MetadataStatus(topStatus))
            #expect(diagnostics.values.first?.attribute == .structural)
        }

        let emptyArray: [AnyObject] = []
        let wrongPayloads: [CFTypeRef?] = [
            nil,
            "not-an-array" as CFString,
            emptyArray as CFArray,
            (["one" as CFString] as [AnyObject]) as CFArray,
            (["one" as CFString, "two" as CFString] as [AnyObject]) as CFArray,
            (["one" as CFString, "two" as CFString, "three" as CFString, "four" as CFString] as [AnyObject]) as CFArray,
        ]
        for payload in wrongPayloads {
            #expect(throws: Policy.Failure.incomplete) {
                _ = try Batch.decode(
                    status: .success,
                    rawValues: payload,
                    advertisedNames: Set(Batch.attributeNames)
                )
            }
        }
    }

    @Test func perLabelAndAggregate1024UTF8ByteBoundsEnforceExactLimitsWithoutLeakingRawText() throws {
        let noValue = try boxedError(.noValue)
        let exactSingle = String(repeating: "a", count: 1_024)
        let overSingle = String(repeating: "a", count: 1_025)
        let multibyteOverSingle = String(repeating: "é", count: 513) // 1,026 UTF-8 bytes

        let singleOK = try Batch.decode(
            status: .success,
            rawValues: ([exactSingle as CFString, noValue, noValue] as [AnyObject]) as CFArray,
            advertisedNames: [kAXTitleAttribute]
        )
        #expect(singleOK.utf8.count == 1_024)

        for oversized in [overSingle, multibyteOverSingle] {
            let diagnostics = IncompleteCollector()
            #expect(throws: Policy.Failure.incomplete) {
                _ = try Batch.decode(
                    status: .success,
                    rawValues: ([oversized as CFString, noValue, noValue] as [AnyObject]) as CFArray,
                    advertisedNames: [kAXTitleAttribute],
                    incomplete: recordIncomplete(diagnostics)
                )
            }
            #expect(diagnostics.values == [
                RecordedIncomplete(
                    origin: .labelValue,
                    attribute: .titleOptional,
                    status: .success,
                    valueType: .string,
                    advertised: true
                )
            ])
        }

        // Aggregate 400 + 400 + 224 == 1,024 UTF-8 bytes succeeds.
        let partA = String(repeating: "a", count: 400)
        let partB = String(repeating: "b", count: 400)
        let partCExact = String(repeating: "c", count: 224)
        let combinedOK = try Batch.decode(
            status: .success,
            rawValues: ([partA as CFString, partB as CFString, partCExact as CFString] as [AnyObject]) as CFArray,
            advertisedNames: Set(Batch.attributeNames)
        )
        #expect(combinedOK == "\(partA) \(partB) \(partCExact)")

        // Aggregate 400 + 400 + 225 == 1,025 UTF-8 bytes fails with .labelBound.
        let partCOver = String(repeating: "c", count: 225)
        let boundDiagnostics = IncompleteCollector()
        #expect(throws: Policy.Failure.incomplete) {
            _ = try Batch.decode(
                status: .success,
                rawValues: ([partA as CFString, partB as CFString, partCOver as CFString] as [AnyObject]) as CFArray,
                advertisedNames: Set(Batch.attributeNames),
                incomplete: recordIncomplete(boundDiagnostics)
            )
        }
        #expect(boundDiagnostics.values == [
            RecordedIncomplete(
                origin: .labelBound,
                attribute: .structural,
                status: .notApplicable,
                valueType: .notApplicable,
                advertised: nil
            )
        ])

        // Verify NativeReadAudit never serializes raw private label text on failure.
        let secretMarker = "SECRET_PRIVATE_LABEL_DO_NOT_RECORD_" + String(repeating: "X", count: 1_024)
        let samples = AuditSamples()
        let audit = NativeReadAudit { samples.append($0) }
        #expect(throws: Policy.Failure.incomplete) {
            _ = try Batch.decode(
                status: .success,
                rawValues: ([secretMarker as CFString, noValue, noValue] as [AnyObject]) as CFArray,
                advertisedNames: [kAXTitleAttribute],
                incomplete: { origin, name, status, value, advertised in
                    NativeReadAudit.incompleteMetadata(
                        audit,
                        .init(
                            phase: .labelPreparation,
                            origin: origin,
                            attribute: name.map(NativeReadAudit.MetadataAttribute.init) ?? .structural,
                            role: .button,
                            status: status.map(NativeReadAudit.MetadataStatus.init) ?? .notApplicable,
                            valueType: status == nil ? .notApplicable : .init(value),
                            advertised: advertised
                        )
                    )
                    return .incomplete
                }
            )
        }
        let encoded = try JSONEncoder().encode(samples.values.compactMap(\.metadata))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("SECRET_PRIVATE_LABEL_DO_NOT_RECORD_"))
    }

    @Test func preFenceFailureExecutesZeroTransportAndPostFenceFailurePublishesNoResult() throws {
        let noValue = try boxedError(.noValue)
        let validPayload: CFArray = (["Send" as CFString, noValue, "composer.send" as CFString] as [AnyObject]) as CFArray

        // 1. Pre-fence failure -> 0 transport calls, 0 published labels or boundaries.
        for preFailure in [Policy.Failure.changedContext, .protectedContext, .incomplete, .unavailable] {
            var fenceCalls = 0
            var transportCalls = 0
            var boundaries: Set<Policy.Dedicated> = []
            var labels: [String] = []
            let access = NativeStandardControlSurvey.AncestryAccess<Int>(
                originalWindow: 0,
                identical: ==,
                validate: {},
                hidden: { _ in .unreported },
                parent: { _ in 0 },
                reportedChildren: { _ in [1] }
            )
            #expect(throws: preFailure) {
                try Batch.inspectControl(
                    1,
                    access: access,
                    read: {
                        try Batch.read(
                            advertisedNames: Set(Batch.attributeNames),
                            validatePrivateScope: {
                                fenceCalls += 1
                                throw preFailure
                            },
                            transport: {
                                transportCalls += 1
                                return .init(status: .success, values: validPayload)
                            }
                        )
                    },
                    boundaries: &boundaries,
                    labels: &labels
                )
            }
            #expect(fenceCalls == 1 && transportCalls == 0)
            #expect(boundaries.isEmpty && labels.isEmpty)
        }

        // 2. Post-fence failure -> pre-fence passes, 1 transport call executes, post-fence throws, no result published.
        for postFailure in [Policy.Failure.changedContext, .protectedContext, .incomplete, .unavailable] {
            var fenceCalls = 0
            var transportCalls = 0
            var boundaries: Set<Policy.Dedicated> = []
            var labels: [String] = []
            let access = NativeStandardControlSurvey.AncestryAccess<Int>(
                originalWindow: 0,
                identical: ==,
                validate: {},
                hidden: { _ in .unreported },
                parent: { _ in 0 },
                reportedChildren: { _ in [1] }
            )
            #expect(throws: postFailure) {
                try Batch.inspectControl(
                    1,
                    access: access,
                    read: {
                        try Batch.read(
                            advertisedNames: Set(Batch.attributeNames),
                            validatePrivateScope: {
                                fenceCalls += 1
                                if fenceCalls == 2 { throw postFailure }
                            },
                            transport: {
                                transportCalls += 1
                                return .init(status: .success, values: validPayload)
                            }
                        )
                    },
                    boundaries: &boundaries,
                    labels: &labels
                )
            }
            #expect(fenceCalls == 2 && transportCalls == 1)
            #expect(boundaries.isEmpty && labels.isEmpty)
        }
    }

    @Test func outerVisibilityGateAndUncachedMultiControlFencesPreserveClassificationAndScope() throws {
        let noValue = try boxedError(.noValue)
        var hidden: [Int: NativeStandardControlSurvey.OptionalFlag] = [
            0: .unreported,
            1: .reported(true),
            2: .unreported,
            3: .unreported,
        ]
        let parents = [1: 0, 2: 0, 3: 0]
        let children = [0: [1, 2, 3]]
        var fenceCounts: [Int: Int] = [:]
        var transportCounts: [Int: Int] = [:]
        var boundaries: Set<Policy.Dedicated> = []
        var labels: [String] = []

        func access() -> NativeStandardControlSurvey.AncestryAccess<Int> {
            .init(
                originalWindow: 0,
                identical: ==,
                validate: {},
                hidden: { node in try #require(hidden[node]) },
                parent: { node in try #require(parents[node]) },
                reportedChildren: { node in try #require(children[node]) }
            )
        }

        let payloads: [Int: CFArray] = [
            1: (["Hidden Password" as CFString, noValue, noValue] as [AnyObject]) as CFArray,
            2: (["Send" as CFString, "Send message" as CFString, "composer.send" as CFString] as [AnyObject]) as CFArray,
            3: (["Cancel" as CFString, noValue, "composer.cancel" as CFString] as [AnyObject]) as CFArray,
        ]

        for node in [1, 2, 3] {
            try Batch.inspectControl(
                node,
                access: access(),
                read: {
                    try Batch.read(
                        advertisedNames: Set(Batch.attributeNames),
                        validatePrivateScope: {
                            fenceCounts[node, default: 0] += 1
                            guard try NativeStandardControlSurvey.visibleOriginalAncestry(from: node, access: access()) else {
                                throw Policy.Failure.changedContext
                            }
                        },
                        transport: {
                            transportCounts[node, default: 0] += 1
                            return .init(status: .success, values: payloads[node])
                        }
                    )
                },
                boundaries: &boundaries,
                labels: &labels
            )
        }

        // Hidden node 1 was skipped by outer visibility gate with 0 fences and 0 transports.
        #expect(fenceCounts[1, default: 0] == 0 && transportCounts[1, default: 0] == 0)
        // Visible nodes 2 and 3 each executed their own pre- and post-fences (2 each) and 1 transport each.
        #expect(fenceCounts[2] == 2 && transportCounts[2] == 1)
        #expect(fenceCounts[3] == 2 && transportCounts[3] == 1)
        #expect(boundaries == [.submission])
        #expect(labels == ["Send Send message composer.send", "Cancel composer.cancel"])

        // Sensitive label in description/identifier refuses immediately before later controls are queried.
        hidden[1] = .unreported
        var sensitiveTransports = 0
        var sensitiveLabels: [String] = []
        var sensitiveBoundaries: Set<Policy.Dedicated> = []
        #expect(throws: Policy.Failure.protectedContext) {
            for node in [1, 2] {
                try Batch.inspectControl(
                    node,
                    access: access(),
                    read: {
                        try Batch.read(
                            advertisedNames: Set(Batch.attributeNames),
                            validatePrivateScope: {},
                            transport: {
                                sensitiveTransports += 1
                                return .init(
                                    status: .success,
                                    values: ([noValue, "Enter two-factor code" as CFString, noValue] as [AnyObject]) as CFArray
                                )
                            }
                        )
                    },
                    boundaries: &sensitiveBoundaries,
                    labels: &sensitiveLabels
                )
            }
        }
        #expect(sensitiveTransports == 1 && sensitiveLabels.isEmpty && sensitiveBoundaries.isEmpty)

        // Decode failure after passing pre- and post-fences publishes no result.
        let badSlot = try boxedError(.cannotComplete)
        var badFences = 0
        var badTransports = 0
        var badLabels: [String] = []
        var badBoundaries: Set<Policy.Dedicated> = []
        #expect(throws: Policy.Failure.incomplete) {
            try Batch.inspectControl(
                2,
                access: access(),
                read: {
                    try Batch.read(
                        advertisedNames: Set(Batch.attributeNames),
                        validatePrivateScope: { badFences += 1 },
                        transport: {
                            badTransports += 1
                            return .init(
                                status: .success,
                                values: (["Publish" as CFString, badSlot, "post.id" as CFString] as [AnyObject]) as CFArray
                            )
                        }
                    )
                },
                boundaries: &badBoundaries,
                labels: &badLabels
            )
        }
        #expect(badFences == 2 && badTransports == 1 && badLabels.isEmpty && badBoundaries.isEmpty)
    }

    nonisolated private final class AuditSamples: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [NativeReadAudit.Sample] = []
        var values: [NativeReadAudit.Sample] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        func append(_ sample: NativeReadAudit.Sample) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(sample)
        }
    }
}
