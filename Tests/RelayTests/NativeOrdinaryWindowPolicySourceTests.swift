import Foundation
import ApplicationServices
import Testing
@testable import Relay

@MainActor @Suite struct NativeOrdinaryWindowPolicySourceTests {
    @MainActor private final class Harness {
        var metadata: [Int: NativeOrdinaryWindowPolicySource.Metadata] = [
            0: .init(role: "AXWindow", subrole: "AXStandardWindow", protectedContent: false,
                     hidden: false, modal: false, minimized: false),
            1: .init(role: "AXTextArea", subrole: "", protectedContent: false,
                     hidden: false, modal: false, minimized: nil)
        ]
        var children: [Int: [Int]] = [0: [1]]
        var childStatus: [Int: AXError] = [:]
        var labels: [Int: NativeOrdinaryWindowPolicySource.Labels] = [:]
        var readLabels: [Int] = []
        var metadataReads = 0
        var validations = 0
        var revoked = false
        var afterMetadata: ((Int) -> Void)?
        let sourceID = UUID()
        var application = DesktopApplicationIdentity(processID: 40, launchedAt: .init(timeIntervalSince1970: 1),
            bundleID: "dev.relay.owned.synthetic", bundleURL: URL(fileURLWithPath: "/Owned Synthetic.app"))
        func inspect(maximumNodes: Int = 512,
                     now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) throws -> NativeOrdinaryWindowPolicySource.Facts {
            try NativeOrdinaryWindowPolicySource.inspect(sourceID: sourceID, application: application,
                access: .init(root: 0, identical: ==, validate: {
                    self.validations += 1
                    if self.revoked { throw CancellationError() }
                }, metadata: { key in
                    self.metadataReads += 1
                    let metadata = try #require(self.metadata[key])
                    self.afterMetadata?(key)
                    return metadata
                }, children: { key in
                    try NativeOrdinaryWindowPolicySource.childScope(role: self.metadata[key]?.role ?? "",
                        status: self.childStatus[key] ?? .success, value: self.children[key] ?? [])
                }, labels: { key in
                    self.readLabels.append(key)
                    return self.labels[key] ?? .init(title: nil, description: nil, identifier: nil)
                }), maximumNodes: maximumNodes, now: now)
        }
        func button(_ key: Int, title: String) {
            metadata[key] = .init(role: "AXButton", subrole: "", protectedContent: false,
                                  hidden: false, modal: false, minimized: nil)
            labels[key] = .init(title: title, description: nil, identifier: nil)
            children[0, default: []].append(key)
        }
    }

    @Test func ordinaryEditorInspectionNeverRequestsEditorLabelsOrValues() throws {
        let h = Harness()
        let facts = try h.inspect()
        #expect(facts.context == .ordinary)
        #expect(facts.visitedNodes == 2)
        #expect(h.readLabels.isEmpty)
        #expect(h.validations > h.metadataReads)
        try facts.admitPrivateEditorPlanning()
    }
    @Test func completeMetadataPassRefusesSecureDescendantBeforeAnyLabels() throws {
        let h = Harness(); h.button(2, title: "Ordinary")
        h.metadata[1] = .init(role: "AXTextField", subrole: "AXSecureTextField", protectedContent: true,
                              hidden: false, modal: false, minimized: nil)
        let facts = try h.inspect()
        #expect(facts.context == .protected)
        #expect(h.readLabels.isEmpty)
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) { try facts.admitPrivateEditorPlanning() }
    }
    @Test func actualSecurityProviderRefusesBeforeAnyOSLabelsOrTreeReads() throws {
        let h = Harness()
        h.application = .init(processID: 40, launchedAt: .init(timeIntervalSince1970: 1),
            bundleID: "com.apple.securityagent", bundleURL: URL(fileURLWithPath: "/Owned Security Test.app"))
        let facts = try h.inspect()
        #expect(facts.context == .protected)
        #expect(h.metadataReads == 0)
        #expect(h.readLabels.isEmpty)
    }
    @Test func unrelatedSendButtonDoesNotReclassifyPlainEditorAsASubmission() throws {
        let h = Harness(); h.button(2, title: "Send")
        let facts = try h.inspect()
        #expect(facts.context == .ordinary)
        #expect(facts.visibleDedicatedControls == [.submission])
        try facts.admitPrivateEditorPlanning()
        #expect(h.readLabels == [2])
    }
    @Test func modalPermissionAndConsequentialContextsCannotBeAdmittedForPrivateEditorPlanning() throws {
        for (label, expected) in [("Grant access", NativeOrdinaryWindowPolicySource.Context.protected),
                                  ("Delete account", .dedicated(.destructive))] {
            let h = Harness()
            h.metadata[2] = .init(role: "AXSheet", subrole: "AXDialog", protectedContent: false,
                                  hidden: false, modal: true, minimized: nil)
            h.children[0, default: []].append(2)
            h.labels[2] = .init(title: label, description: nil, identifier: nil)
            let facts = try h.inspect()
            #expect(facts.context == expected)
            #expect(throws: (any Error).self) { try facts.admitPrivateEditorPlanning() }
        }
    }
    @Test func partialMissingAndOverBudgetMetadataNeverProducePositiveFacts() throws {
        let h = Harness()
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) { try h.inspect(maximumNodes: 1) }
        #expect(h.readLabels.isEmpty)
        let started = ContinuousClock.now
        var reads = 0
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try h.inspect(now: { reads += 1; return started.advanced(by: reads > 2 ? .seconds(1) : .zero) })
        }
        #expect(h.readLabels.isEmpty)
    }
    @Test func revocationAfterMetadataStopsBeforeChildrenOrLabels() throws {
        let h = Harness(); h.button(2, title: "Ordinary")
        h.afterMetadata = { _ in h.revoked = true }
        #expect(throws: CancellationError.self) { try h.inspect() }
        #expect(h.metadataReads == 1)
        #expect(h.readLabels.isEmpty)
    }
    @Test func metadataReceiptDigestKeepsExactUnicodeBytes() throws {
        let h = Harness(); h.button(2, title: "caf\u{e9}")
        let first = try h.inspect()
        h.labels[2] = .init(title: "cafe\u{301}", description: nil, identifier: nil)
        let second = try h.inspect()
        #expect(first.digest != second.digest)
    }
    @Test func reportedChildrenAndUnsupportedKnownAppKitLeafRemainQualified() throws {
        let h = Harness(); h.childStatus[1] = .attributeUnsupported
        let facts = try h.inspect()
        #expect(facts.coverage == .complete)
        try facts.admitPrivateEditorPlanning()
        #expect(h.readLabels.isEmpty)
    }
    @Test func missingContainerTraversalIsExplicitlyIncompleteRatherThanAnEmptyWindow() throws {
        let h = Harness(); h.childStatus[0] = .attributeUnsupported
        let facts = try h.inspect()
        #expect(facts.visitedNodes == 1)
        #expect(facts.coverage == .incomplete([.containerChildren]))
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) { try facts.admitPrivateEditorPlanning() }
    }
    @Test func unavailableLeafValueAndUnknownWindowPrivacyFlagsCannotAdmitPrivatePlanning() throws {
        let h = Harness(); h.childStatus[1] = .noValue
        var facts = try h.inspect()
        #expect(facts.coverage == .incomplete([.containerChildren]))
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) { try facts.admitPrivateEditorPlanning() }
        h.childStatus[1] = .success
        h.metadata[0] = .init(role: "AXWindow", subrole: "AXStandardWindow", protectedContent: nil,
                              hidden: nil, modal: nil, minimized: false)
        facts = try h.inspect()
        #expect(facts.coverage == .incomplete([.privacyFlags, .modalFlag]))
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) { try facts.admitPrivateEditorPlanning() }
    }
    @Test func escapedMetadataBindingStillRequiresItsControllerOwner() throws {
        let application = Harness().application
        var active = true, originalChecks = 0
        let raw = NativeOriginalPolicyTarget(sourceID: UUID(), application: application,
            originalWindow: AXUIElementCreateApplication(999_999), validateOriginalSource: { originalChecks += 1 })
        let bound = raw.addingSourceValidation { if !active { throw CancellationError() } }
        try bound.validateSource()
        #expect(originalChecks == 1)
        active = false
        #expect(throws: CancellationError.self) { try bound.validateSource() }
        #expect(originalChecks == 1)
    }
    @Test func unknownControlPrivacySkipsItsLabelsAndMarksCoverageIncomplete() throws {
        let h = Harness(); h.button(2, title: "Synthetic confidential label")
        h.metadata[2] = .init(role: "AXButton", subrole: "", protectedContent: nil,
                              hidden: nil, modal: false, minimized: nil)
        let facts = try h.inspect()
        #expect(h.readLabels.isEmpty)
        #expect(facts.coverage == .incomplete([.privacyFlags]))
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) { try facts.admitPrivateEditorPlanning() }
    }
}
