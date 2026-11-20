import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Actual shared control orchestration + actual lexical phase lifetime with
/// inert metadata/CF strings. No production Binding/Survey/AX grant is minted.
@MainActor @Suite struct NativeLabelMetadataGroupTests {
    private typealias Batch = NativeControlLabelBatch
    private typealias Policy = NativeOrdinaryWindowPolicySource
    private enum Refusal: Error, Equatable { case source, stopped, phaseStillLive, extraValidation }

    @MainActor private final class Groups {
        let deadline: ContinuousClock.Instant
        var now: ContinuousClock.Instant
        var current = true, sourceCurrent = true
        var failGroup: String?, failWith = Refusal.source
        var afterNames: (@MainActor () -> Void)?
        var advanceToDeadlineAtPre = false
        var phases: [NativeMetadataPhase] = []
        var kinds: [String] = []
        var strongChecks = 0, cheapChecks = 0, privateFences = 0, transports = 0

        init() {
            let start = ContinuousClock.now
            now = start; deadline = start.advanced(by: .milliseconds(750))
        }
        func strong() throws {
            strongChecks += 1
            guard current else { throw Refusal.stopped }
            guard sourceCurrent else { throw Refusal.source }
        }
        func retired() throws {
            for phase in phases {
                do { try phase.check(); throw Refusal.phaseStillLive }
                catch NativeMetadataPhase.Failure.expired { }
            }
        }
        func group<Value>(_ kind: String, body: (NativeMetadataPhase) throws -> Value) throws -> Value {
            kinds.append(kind)
            return try NativeMetadataPhase.run(deadline: deadline, boundary: strong, query: {
                self.cheapChecks += 1
                guard self.current else { throw Refusal.stopped }
            }, now: { self.now }) { phase in
                phases.append(phase)
                let value = try body(phase)
                if let failGroup, kind == failGroup {
                    if failWith == .stopped { current = false } else { sourceCurrent = false }
                }
                if advanceToDeadlineAtPre {
                    if kind == "visibility" { now = deadline.advanced(by: .milliseconds(-350)) }
                    if kind == "names" { now = deadline.advanced(by: .milliseconds(-50)) }
                    if kind == "pre" { now = deadline }
                }
                return value
            }
        }
        func access(node: Int, phase: NativeMetadataPhase, hidden: Bool) -> NativeStandardControlSurvey.AncestryAccess<Int> {
            .init(originalWindow: 0, identical: ==, validate: { try phase.check() },
                hidden: { current in try phase.check(); return hidden && current == node ? .reported(true) : .unreported },
                parent: { _ in try phase.check(); return 0 },
                reportedChildren: { _ in try phase.check(); return [1,2] })
        }
        func inspect(_ node: Int, hidden: Bool = false,
                     boundaries: inout Set<Policy.Dedicated>, labels: inout [String]) throws {
            var fence = 0
            try Batch.inspectControl(visibility: {
                try self.retired()
                return try self.group("visibility") { phase in
                    try NativeStandardControlSurvey.visibleOriginalForLabels(from: node,
                        access: self.access(node: node, phase: phase, hidden: hidden))
                }
            }, read: {
                try self.retired()
                let names: Set<String> = try self.group("names") { phase in
                    try phase.check(); return Set(Batch.attributeNames)
                }
                try self.retired(); self.afterNames?()
                return try Batch.read(advertisedNames: names, validatePrivateScope: {
                    // No earlier group's lease may be live at a private fence.
                    try self.retired(); self.privateFences += 1; try self.strong()
                    fence += 1
                    let visible = try self.group(fence == 1 ? "pre" : "post") { phase in
                        try NativeStandardControlSurvey.visibleOriginalAncestry(from: node,
                            access: self.access(node: node, phase: phase, hidden: hidden))
                    }
                    guard visible else { throw Policy.Failure.changedContext }
                    try self.retired()
                }, transport: {
                    // Represents the unchanged strong transport bracket, not
                    // an SDK or a producer source-binding substitute.
                    try self.retired(); try self.strong()
                    try NativeStandardControlSurvey.requireMetadataDeadline(self.deadline, now: self.now)
                    self.transports += 1
                    let values: [AnyObject] = [(node == 1 ? "Alpha" : "Beta") as CFString,
                        "Details" as CFString, "control.identifier" as CFString]
                    try self.strong()
                    try NativeStandardControlSurvey.requireMetadataDeadline(self.deadline, now: self.now)
                    return .init(status: .success, values: values as CFArray)
                })
            }, boundaries: &boundaries, labels: &labels)
        }
    }

    @Test func separateControlGroupsRetireBeforeEveryPrivateFenceTransportAndNextControl() throws {
        let groups = Groups()
        var boundaries: Set<Policy.Dedicated> = [], labels: [String] = []
        try groups.inspect(1, boundaries: &boundaries, labels: &labels)
        try groups.inspect(2, boundaries: &boundaries, labels: &labels)
        try groups.retired()
        #expect(groups.kinds == ["visibility", "names", "pre", "post", "visibility", "names", "pre", "post"])
        #expect(groups.phases.count == 8 && groups.privateFences == 4 && groups.transports == 2)
        #expect(groups.cheapChecks > 0 && groups.strongChecks > 0)
        #expect(labels == ["Alpha Details control.identifier", "Beta Details control.identifier"] && boundaries.isEmpty)
    }

    @Test func hiddenOuterGroupReturnsOnlyVisibilityAndNeverQueriesNamesOrPrivateLabels() throws {
        let groups = Groups()
        var boundaries: Set<Policy.Dedicated> = [], labels: [String] = []
        try groups.inspect(1, hidden: true, boundaries: &boundaries, labels: &labels)
        try groups.retired()
        #expect(groups.kinds == ["visibility"] && groups.privateFences == 0 && groups.transports == 0)
        #expect(labels.isEmpty && boundaries.isEmpty)
    }

    @Test func originalNodeWrapperRetainsItsAdditionalValidationBeforeTheSharedRead() {
        var checks = 0, reads = 0
        var boundaries: Set<Policy.Dedicated> = [], labels: [String] = []
        let access = NativeStandardControlSurvey.AncestryAccess<Int>(originalWindow: 0, identical: ==,
            validate: { checks += 1; if checks == 3 { throw Refusal.extraValidation } },
            hidden: { _ in .unreported }, parent: { _ in 0 }, reportedChildren: { _ in [] })
        #expect(throws: Refusal.extraValidation) {
            try Batch.inspectControl(0, access: access, read: { reads += 1; return "Unreached" },
                boundaries: &boundaries, labels: &labels)
        }
        #expect(checks == 3 && reads == 0 && labels.isEmpty && boundaries.isEmpty)
    }

    @Test(arguments: ["visibility", "names", "pre", "post"], [false, true])
    func sourceOrStopAtEachTechnicalExitCannotPublishItsDataOrClassifyLabels(kind: String, stopped: Bool) throws {
        let groups = Groups(); groups.failGroup = kind; groups.failWith = stopped ? .stopped : .source
        var boundaries: Set<Policy.Dedicated> = [], labels: [String] = []
        #expect(throws: stopped ? Refusal.stopped : Refusal.source) {
            try groups.inspect(1, boundaries: &boundaries, labels: &labels)
        }
        try groups.retired()
        #expect(groups.transports == (kind == "post" ? 1 : 0))
        #expect(labels.isEmpty && boundaries.isEmpty)
    }

    @Test func successiveGroupsShareTheOriginalDeadlineInsteadOfRenewingIt() throws {
        let groups = Groups(); groups.advanceToDeadlineAtPre = true
        var boundaries: Set<Policy.Dedicated> = [], labels: [String] = []
        #expect(throws: Policy.Failure.incomplete) { try groups.inspect(1, boundaries: &boundaries, labels: &labels) }
        try groups.retired()
        #expect(groups.kinds == ["visibility", "names", "pre"])
        #expect(groups.now == groups.deadline && groups.transports == 0 && groups.privateFences == 1)
        #expect(labels.isEmpty && boundaries.isEmpty)
    }

    @Test func namesDataCannotReplaceTheFullSourceFenceBeforePrivateTransport() throws {
        let groups = Groups(); groups.afterNames = { [weak groups] in groups?.sourceCurrent = false }
        var boundaries: Set<Policy.Dedicated> = [], labels: [String] = []
        #expect(throws: Refusal.source) { try groups.inspect(1, boundaries: &boundaries, labels: &labels) }
        try groups.retired()
        #expect(groups.kinds == ["visibility", "names"] && groups.privateFences == 1 && groups.transports == 0)
        #expect(labels.isEmpty && boundaries.isEmpty)
    }
}
