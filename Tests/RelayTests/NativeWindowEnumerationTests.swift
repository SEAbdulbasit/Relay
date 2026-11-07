import ApplicationServices
import Foundation
import Testing
@testable import Relay

@Suite @MainActor struct NativeWindowEnumerationTests {
    @MainActor private final class Harness {
        enum Fault: Error { case unexpectedRead, originalChanged, revoked, expired, unrelated }
        enum Reply { case text(String), failure(NativeWindowEnumeration.Attribute, AXError), unrelated }
        var lists: [[Int]]
        var replies: [Int: [Reply]] = [:]
        var titles = [1: "Original", 2: "Sibling", 3: "Third", 4: "Fourth"]
        var enumerationCount = 0
        var titleReads: [Int] = []
        var originalChecks = 0
        var revoked = false, expired = false
        var onEnumerate: (() -> Void)?
        var onTitle: ((Int) -> Void)?
        var onOriginal: ((Int) throws -> Void)?
        init(_ lists: [[Int]]) { self.lists = lists }
        func run(recovery: Bool = true, title: String = "Original") throws -> NativeWindowEnumeration.Resolution {
            let backend = NativeWindowEnumeration.Backend<Int>(enumerate: {
                self.enumerationCount += 1
                guard !self.lists.isEmpty else { throw Fault.unexpectedRead }
                self.onEnumerate?()
                return self.lists.removeFirst()
            }, title: { member in
                self.titleReads.append(member); self.onTitle?(member)
                if var values = self.replies[member], !values.isEmpty {
                    let reply = values.removeFirst(); self.replies[member] = values
                    switch reply {
                    case .text(let value): return value
                    case .failure(let attribute, let status): throw NativeWindowEnumeration.ReadFailure(attribute: attribute, status: status)
                    case .unrelated: throw Fault.unrelated
                    }
                }
                guard let value = self.titles[member] else { throw Fault.unexpectedRead }
                return value
            }, same: ==, validateOriginal: {
                self.originalChecks += 1; try self.onOriginal?(self.originalChecks)
            }, requireCurrent: {
                try Task.checkCancellation()
                if self.revoked { throw Fault.revoked }
                if self.expired { throw Fault.expired }
            })
            return try NativeWindowEnumeration.validate(original: 1, title: title,
                allowSiblingRecovery: recovery, backend: backend)
        }
        func invalidSibling() { replies[2] = [.failure(.title, .invalidUIElement)] }
    }

    @Test func completeInitialScanDoesNotRefresh() throws {
        let h = Harness([[1, 2]])
        #expect(try h.run() == .firstScan)
        #expect(h.enumerationCount == 1); #expect(h.originalChecks == 2); #expect(h.titleReads == [1, 2])
    }
    @Test func sameIdentitiesCanBeReadOnceMoreAfterTypedSiblingInvalidity() throws {
        let h = Harness([[2, 1], [1, 2]]); h.invalidSibling()
        #expect(try h.run() == .refreshedSameIdentities)
        #expect(h.enumerationCount == 2); #expect(h.originalChecks == 3); #expect(h.titleReads == [2, 1, 2])
    }
    @Test func onlyTheProvenInvalidNonOriginalSiblingMayDisappear() throws {
        let h = Harness([[2, 1, 3], [3, 1]]); h.invalidSibling()
        #expect(try h.run() == .retiredInvalidSibling)
        #expect(h.enumerationCount == 2); #expect(h.originalChecks == 3); #expect(h.titleReads == [2, 3, 1])
    }
    @Test func invalidOriginalNeverRefreshes() {
        let h = Harness([[1, 2], [1]]); h.replies[1] = [.failure(.title, .invalidUIElement)]
        #expect(throws: NativeWindowEnumeration.ReadFailure.self) { try h.run() }
        #expect(h.enumerationCount == 1)
    }
    @Test func initialUnqualifiedBindingDoesNotRecover() {
        let h = Harness([[2, 1], [1]]); h.invalidSibling()
        #expect(throws: NativeWindowEnumeration.ReadFailure.self) { try h.run(recovery: false) }
        #expect(h.enumerationCount == 1)
    }
    @Test(arguments: [AXError.cannotComplete, .noValue, .attributeUnsupported, .failure, .notImplemented])
    func otherTypedStatusesNeverRefresh(_ status: AXError) {
        let h = Harness([[2, 1], [1]]); h.replies[2] = [.failure(.title, status)]
        #expect(throws: NativeWindowEnumeration.ReadFailure.self) { try h.run() }
        #expect(h.enumerationCount == 1)
    }
    @Test func wrongAttributeStatusAndUnknownErrorsNeverRefresh() {
        let h = Harness([[2, 1], [1]]); h.replies[2] = [.failure(.windows, .invalidUIElement)]
        #expect(throws: NativeWindowEnumeration.ReadFailure.self) { try h.run() }
        #expect(h.enumerationCount == 1)
        let other = Harness([[2, 1], [1]]); other.replies[2] = [.unrelated]
        #expect(throws: Harness.Fault.self) { try other.run() }
        #expect(other.enumerationCount == 1)
    }
    @Test func unreadableFinalSiblingRefusesWithoutThirdEnumeration() {
        let h = Harness([[2, 1], [2, 1], [1]])
        h.replies[2] = [.failure(.title, .invalidUIElement), .failure(.title, .invalidUIElement)]
        #expect(throws: NativeWindowEnumeration.ReadFailure.self) { try h.run() }
        #expect(h.enumerationCount == 2)
    }
    @Test func differentUnreadableFinalSiblingAlsoRefuses() {
        let h = Harness([[2, 1, 3], [3, 1]])
        h.invalidSibling(); h.replies[3] = [.failure(.title, .noValue)]
        #expect(throws: NativeWindowEnumeration.ReadFailure.self) { try h.run() }
        #expect(h.enumerationCount == 2)
    }
    @Test func freshDuplicateTitleRefuses() {
        let h = Harness([[2, 1, 3], [3, 1]]); h.invalidSibling(); h.titles[3] = "Original"
        #expect(throws: NativeWindowEnumeration.Failure.wrongWindow) { try h.run() }
    }
    @Test func knownAmbiguityBeforeInvalidSiblingDoesNotTriggerRecovery() {
        let h = Harness([[1, 3, 2], [1]]); h.invalidSibling(); h.titles[3] = "Original"
        #expect(throws: NativeWindowEnumeration.Failure.wrongWindow) { try h.run() }
        #expect(h.enumerationCount == 1)
    }
    @Test func addedWindowIdentityRefusesEvenWithReadableUniqueTitle() {
        let h = Harness([[2, 1], [1, 4]]); h.invalidSibling()
        #expect(throws: NativeWindowEnumeration.Failure.changedEnumeration) { try h.run() }
        #expect(h.titleReads == [2])
    }
    @Test func extraRemovalBeyondTheFailedSiblingRefuses() {
        let h = Harness([[2, 1, 3], [1]]); h.invalidSibling()
        #expect(throws: NativeWindowEnumeration.Failure.changedEnumeration) { try h.run() }
    }
    @Test func lookalikeOriginalReplacementRefusesBeforeReadingItsTitle() {
        let h = Harness([[2, 1], [4]]); h.invalidSibling(); h.titles[4] = "Original"
        #expect(throws: NativeWindowEnumeration.Failure.wrongWindow) { try h.run() }
        #expect(h.titleReads == [2])
    }
    @Test func missingOriginalOrDuplicateHandlesCannotBeginScan() {
        for list in [[2, 3], [1, 1]] {
            let h = Harness([list])
            #expect(throws: NativeWindowEnumeration.Failure.wrongWindow) { try h.run() }
            #expect(h.titleReads.isEmpty)
        }
    }
    @Test func emptyOrOversizedEnumerationsRefuse() {
        for list in [[], Array(1...65)] {
            let h = Harness([list])
            #expect(throws: NativeWindowEnumeration.Failure.unavailableWindow) { try h.run() }
            #expect(h.titleReads.isEmpty)
        }
    }
    @Test func titleUniquenessUsesLiteralUTF16InsteadOfCanonicalEquality() throws {
        let h = Harness([[1, 2]])
        h.titles[1] = "caf\u{e9}"; h.titles[2] = "cafe\u{301}"
        #expect(try h.run(title: "caf\u{e9}") == .firstScan)
    }
    @Test func originalProcessWindowOrDocumentDriftBeforeRefreshRefuses() {
        let h = Harness([[2, 1], [1]]); h.invalidSibling()
        h.onOriginal = { count in if count == 2 { throw Harness.Fault.originalChanged } }
        #expect(throws: Harness.Fault.self) { try h.run() }
        #expect(h.enumerationCount == 1)
    }
    @Test func originalDriftAfterCompleteRefreshStillRefuses() {
        let h = Harness([[2, 1], [1]]); h.invalidSibling()
        h.onOriginal = { count in if count == 3 { throw Harness.Fault.originalChanged } }
        #expect(throws: Harness.Fault.self) { try h.run() }
        #expect(h.enumerationCount == 2); #expect(h.originalChecks == 3)
    }
    @Test func stoppedOwnerBeforeFirstReadHasNoEffects() {
        let h = Harness([[1]]); h.revoked = true
        #expect(throws: Harness.Fault.self) { try h.run() }
        #expect(h.enumerationCount == 0); #expect(h.originalChecks == 0)
    }
    @Test func sourceRevocationDuringEnumerationStopsBeforeAnyTitle() {
        let h = Harness([[1, 2]]); h.onEnumerate = { h.revoked = true }
        #expect(throws: Harness.Fault.self) { try h.run() }
        #expect(h.titleReads.isEmpty)
    }
    @Test func sourceRevocationAtFailedReadStopsBeforeRecovery() {
        let h = Harness([[2, 1], [1]]); h.invalidSibling(); h.onTitle = { _ in h.revoked = true }
        #expect(throws: Harness.Fault.self) { try h.run() }
        #expect(h.enumerationCount == 1)
    }
    @Test func deadlineExpiryDuringFreshScanCannotReturnSuccess() {
        let h = Harness([[2, 1], [1]]); h.invalidSibling(); h.onTitle = { member in if member == 1 { h.expired = true } }
        #expect(throws: Harness.Fault.self) { try h.run() }
        #expect(h.enumerationCount == 2)
    }
    @Test func cancellationBeforeEnumerationHasNoEffects() async {
        let task = Task { @MainActor in
            let h = Harness([[1]])
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try h.run() }
            #expect(h.enumerationCount == 0)
        }
        await task.value
    }
}
