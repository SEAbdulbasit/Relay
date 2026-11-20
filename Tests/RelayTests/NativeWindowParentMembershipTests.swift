import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Actual-used relational algorithm with inert graphs; never an AX/source grant.
@MainActor @Suite struct NativeWindowParentMembershipTests {
    private typealias Membership = NativeWindowParentMembership
    private enum Refusal: Error, Equatable { case source, reader }
    private enum Operation: Equatable { case role, parent, children }
    @MainActor private final class Graph {
        var parents = [2: 1, 1: 0]
        var children = [0: [1], 1: [2]]
        var roles = [0: "AXWindow", 1: "AXGroup", 2: "AXButton"]
        var pids = [0: 7, 1: 7, 2: 7]
        var active = true, revision = 1
        let originalRevision = 1
        let start: ContinuousClock.Instant
        var now: ContinuousClock.Instant
        var parentReads: [Int: Int] = [:], childReads: [Int: Int] = [:], roleReads: [Int: Int] = [:]
        var beforeRead: ((Operation, Int, Int) -> Void)?
        init() { let value = ContinuousClock.now; start = value; now = value }
        var totalReads: Int { parentReads.values.reduce(0,+) + childReads.values.reduce(0,+) + roleReads.values.reduce(0,+) }
        func validate() throws {
            try Task.checkCancellation()
            guard active, revision == originalRevision else { throw Refusal.source }
            try NativeStandardControlSurvey.requireMetadataDeadline(start.advanced(by: .milliseconds(750)), now: now)
        }
        private func read(_ operation: Operation, _ node: Int) throws {
            try validate()
            let count: Int
            switch operation {
            case .role: roleReads[node, default: 0] += 1; count = roleReads[node]!
            case .parent: parentReads[node, default: 0] += 1; count = parentReads[node]!
            case .children: childReads[node, default: 0] += 1; count = childReads[node]!
            }
            beforeRead?(operation, node, count)
            try validate()
            guard pids[node] == 7 else { throw Refusal.reader }
        }
        func access(check: (@MainActor () throws -> Void)? = nil) -> Membership.Access<Int> {
            .init(originalWindow: 0, identical: { $0 == $1 }, validate: {
                try check?(); try self.validate()
            }, liveRole: { node in
                try self.read(.role, node)
                guard let role = self.roles[node] else { throw Refusal.reader }; return role
            }, parent: { node in
                try self.read(.parent, node)
                guard let parent = self.parents[node] else { throw Refusal.reader }; return parent
            }, directChildren: { node in
                try self.read(.children, node)
                guard let children = self.children[node] else { throw Refusal.reader }; return children
            })
        }
    }

    @Test func reportedOriginalIsFastAndContradictoryWindowCannotUseAMatchingChain() throws {
        let graph = Graph()
        let direct = Membership.shortcut(status: .success, valuePresent: true, element: 0)
        let basis = try Membership.require(2, shortcut: direct, expectedRole: "AXButton", access: graph.access())
        #expect(basis == .windowShortcut && graph.totalReads == 0)
        #expect(throws: Membership.Failure.differentWindow) {
            try Membership.require(2, shortcut: .reported(9), expectedRole: "AXButton", access: graph.access())
        }
        #expect(graph.totalReads == 0)
    }

    @Test func onlyExactNoValueAndNilMayEnterTheAlternateProof() throws {
        let rejected: [(AXError, Bool, Int?)] = [
            (.attributeUnsupported, false, nil), (.invalidUIElement, false, nil), (.cannotComplete, false, nil),
            (.apiDisabled, false, nil), (.failure, false, nil), (.noValue, true, 0), (.noValue, true, nil),
            (.success, false, nil), (.success, true, nil), (.noValue, false, 0)
        ]
        for (status, present, node) in rejected {
            let graph = Graph(), shortcut = Membership.shortcut(status: status, valuePresent: present, element: node)
            #expect(throws: Membership.Failure.invalidShortcut) {
                try Membership.require(2, shortcut: shortcut, expectedRole: "AXButton", access: graph.access())
            }
            #expect(graph.totalReads == 0)
        }
        let graph = Graph(), shortcut: Membership.Shortcut<Int> = Membership.shortcut(status: .noValue, valuePresent: false, element: nil)
        #expect(try Membership.require(2, shortcut: shortcut, expectedRole: "AXButton", access: graph.access()) == .currentParentChain)
    }

    @Test func everyEdgeUsesCurrentParentAndDirectChildrenThenACompleteFinalRecheck() throws {
        let graph = Graph()
        let basis = try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: graph.access())
        #expect(basis == .currentParentChain)
        // Initial edge, immediate recheck, and final recheck; a saved Row.children
        // or just the last parent cannot satisfy these actual-used operations.
        #expect(graph.parentReads[2] == 3 && graph.parentReads[1] == 3)
        #expect(graph.childReads[1] == 3 && graph.childReads[0] == 3)
        #expect((graph.roleReads[0] ?? 0) > 1 && (graph.roleReads[2] ?? 0) > 1)
    }

    @Test func missingDuplicateOverboundAndCyclicRelationshipsNeverPublish() throws {
        let missing = Graph(); missing.children[1] = []
        #expect(throws: Membership.Failure.missingChild) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: missing.access())
        }
        let duplicate = Graph(); duplicate.children[1] = [2,2]
        #expect(throws: Membership.Failure.duplicateChild) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: duplicate.access())
        }
        let tooMany = Graph(); tooMany.children[1] = [2] + Array(100..<612)
        #expect(throws: Membership.Failure.childBound) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: tooMany.access())
        }
        for cyclic in [2,1] {
            let graph = Graph(); graph.parents[cyclic] = 2
            #expect(throws: Membership.Failure.cycle) {
                try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: graph.access())
            }
        }
        let different = Graph(); different.roles[1] = "AXWindow"
        #expect(throws: Membership.Failure.unexpectedRoot) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: different.access())
        }
        let invalidRoot = Graph(); invalidRoot.roles[0] = "AXGroup"
        #expect(throws: Membership.Failure.invalidWindowRole) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: invalidRoot.access())
        }
        let absentParent = Graph(); absentParent.parents[2] = nil
        #expect(throws: Refusal.reader) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: absentParent.access())
        }
    }

    @Test func exactlyTwentyLiveNodesCanReachOnlyTheRetainedOriginal() throws {
        for count in [20,21] {
            let graph = Graph(); graph.parents = [:]; graph.children = [:]; graph.roles = [:]; graph.pids = [:]
            for node in 0..<count {
                graph.roles[node] = node == 0 ? "AXWindow" : node == count-1 ? "AXButton" : "AXGroup"
                graph.pids[node] = 7
                if node > 0 { graph.parents[node] = node-1; graph.children[node-1] = [node] }
            }
            if count == 20 {
                #expect(try Membership.require(count-1, shortcut: .missingValue, expectedRole: "AXButton", access: graph.access()) == .currentParentChain)
            } else {
                #expect(throws: Membership.Failure.nodeBound) {
                    try Membership.require(count-1, shortcut: .missingValue, expectedRole: "AXButton", access: graph.access())
                }
            }
        }
    }

    @Test func relatedPathDriftAndWrongPIDAreCaughtBeforeReturningMembership() throws {
        let reparent = Graph()
        reparent.beforeRead = { [weak reparent] operation,node,count in
            if operation == .parent && node == 2 && count == 2 { reparent?.parents[2] = 3 }
        }
        #expect(throws: Membership.Failure.changedParent) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: reparent.access())
        }
        let finalEdge = Graph()
        finalEdge.beforeRead = { [weak finalEdge] operation,node,count in
            if operation == .children && node == 1 && count == 3 { finalEdge?.children[1] = [] }
        }
        #expect(throws: Membership.Failure.missingChild) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: finalEdge.access())
        }
        let foreign = Graph(); foreign.pids[1] = 99
        #expect(throws: Refusal.reader) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: foreign.access())
        }
        let role = Graph(); role.roles[2] = "AXTextField"
        #expect(throws: Membership.Failure.changedRole) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: role.access())
        }
    }

    @Test func sourceStopRevisionAndSame750MillisecondDeadlineCannotRenewTheProof() throws {
        for stop in [true,false] {
            let graph = Graph()
            graph.beforeRead = { [weak graph] operation,node,count in
                guard let graph else { return }
                if operation == .parent && node == 2 && count == 1 {
                    if stop { graph.active = false } else { graph.revision += 1 }
                }
            }
            #expect(throws: Refusal.source) {
                try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: graph.access())
            }
        }
        let timed = Graph()
        timed.beforeRead = { [weak timed] operation,node,count in
            if operation == .parent && node == 2 && count == 1, let timed { timed.now = timed.start.advanced(by: .milliseconds(750)) }
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: timed.access())
        }
        #expect(timed.parentReads[2] == 1 && timed.childReads.isEmpty)
    }

    @Test func cancellationAndAnEscapedPhaseRefuseWithoutMoreRelationshipReads() async throws {
        let canceled = Graph()
        canceled.beforeRead = { operation,_,_ in
            if operation == .parent { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let child = Task { @MainActor in
            #expect(throws: CancellationError.self) {
                try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: canceled.access())
            }
        }
        await child.value
        #expect(canceled.parentReads[2] == 1 && canceled.childReads.isEmpty)

        let graph = Graph()
        let escaped = try NativeMetadataPhase.run(deadline: graph.start.advanced(by: .milliseconds(750)),
            boundary: graph.validate, query: graph.validate, now: { graph.now }) { phase in
                graph.access(check: { try phase.check() })
            }
        #expect(throws: NativeMetadataPhase.Failure.expired) {
            try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: escaped)
        }
        #expect(graph.totalReads == 0)
    }

    @Test func membershipCannotSupplyContainerPrivacyOrEditorCapabilityEvidence() throws {
        let graph = Graph()
        #expect(try Membership.require(2, shortcut: .missingValue, expectedRole: "AXButton", access: graph.access()) == .currentParentChain)
        let leaf: [Int] = try NativeStandardControlSurvey.terminalChildren(role: "AXButton", status: .noValue,
            value: nil, liveOriginalLeaf: true)
        #expect(leaf.isEmpty)
        for role in ["AXGroup", "AXWindow", "AXUnknown"] {
            #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                let _: [Int] = try NativeStandardControlSurvey.terminalChildren(role: role, status: .noValue,
                    value: nil, liveOriginalLeaf: true)
            }
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) {
            try NativeStandardControlSurvey.admitApplicationProtection([.reported(true), .unreported])
        }
        for role in ["AXSecureTextField", "AXUnknown"] {
            #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                try NativeStandardControlSurvey.admitEditorMetadata(role: role, subrole: "", protection: .unreported,
                    hidden: .unreported, enabled: .reported(true), valueWritable: true,
                    selectionWritable: true, selectedTextWritable: true)
            }
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeStandardControlSurvey.admitEditorMetadata(role: "AXTextField", subrole: "", protection: .unreported,
                hidden: .unreported, enabled: .reported(true), valueWritable: false,
                selectionWritable: true, selectedTextWritable: false)
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeStandardControlSurvey.admitEditorMetadata(role: "AXTextField", subrole: "", protection: .reported(true),
                hidden: .unreported, enabled: .reported(true), valueWritable: true,
                selectionWritable: true, selectedTextWritable: true)
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeStandardControlSurvey.admitEditorMetadata(role: "AXTextField", subrole: "", protection: .unreported,
                hidden: .reported(true), enabled: .reported(true), valueWritable: true,
                selectionWritable: true, selectedTextWritable: true)
        }
    }

    @Test func membershipDiagnosticsRemainClosedDataAndNeverAnIncompleteSuccess() throws {
        let samples = Samples(), audit = NativeReadAudit { samples.record($0) }
        let marker = "UNTRUSTED_ROLE_DO_NOT_RETAIN"
        NativeReadAudit.recordWindowMembership(nil, event: .missing, use: .surveyRow, phase: .revalidation, role: marker)
        NativeReadAudit.recordWindowMembership(audit, event: .missing, use: .surveyRow, phase: .revalidation, role: marker)
        NativeReadAudit.recordWindowMembership(audit, event: .verified, use: .terminalChildren, phase: .revalidation, role: marker)
        NativeReadAudit.recordWindowMembership(audit, event: .refused, use: .surveyRow, phase: .revalidation, role: marker, failure: .cycle)
        #expect(samples.values.map(\.stage) == [.policyWindowMembershipAttempt, .policyWindowMembershipVerified, .policyWindowMembershipRefused])
        #expect(samples.values.compactMap(\.metadata).map(\.origin) == [.windowMissingSurvey, .windowVerifiedTerminal, .windowParentCycle])
        let data = try JSONEncoder().encode(samples.values.compactMap(\.metadata))
        #expect(!String(decoding: data, as: UTF8.self).contains(marker))
    }

    nonisolated private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [NativeReadAudit.Sample] = []
        var values: [NativeReadAudit.Sample] { lock.lock(); defer { lock.unlock() }; return storage }
        func record(_ value: NativeReadAudit.Sample) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    }
}
