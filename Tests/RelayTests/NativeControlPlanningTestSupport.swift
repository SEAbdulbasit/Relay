import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Relay

/// In-memory metadata, PNG and editor seams only. No native process or OS input.
@MainActor final class NextNativeControlRig {
    let application = DesktopApplicationIdentity(processID: 4_242, launchedAt: Date(timeIntervalSince1970: 100),
        bundleID: "test.owned.native.fixture", bundleURL: URL(fileURLWithPath: "/Applications/Owned Fixture.app", isDirectory: true))
    let window = TargetBoundNativeObservation.WindowInfo(title: "Owned fixture", role: "AXWindow", identifier: "owned.window",
        document: "fixture://owned", url: "", x: 0, y: 0, width: 32, height: 20,
        minimized: false, hidden: false, modal: false)
    let sourceID = UUID()
    var active = true, foreground = true, sourceVersion = 0, editorVersion = 0
    var includeImage = true
    var captureFailureAt: Int?
    var planningAuthorized = true, insertionAvailable = true, focusAvailable = true
    let fieldStorage = NSMutableAttributedString(string: "Original café 🌍")
    var field: String {
        get { fieldStorage.string }
        set { fieldStorage.replaceCharacters(in: NSRange(location: 0, length: fieldStorage.length), with: newValue) }
    }
    var selection = NSRange(location: 0, length: 8)
    var captureCount = 0, focusCaptures = 0, insertionCaptures = 0, textReads = 0, textWrites = 0, labelReads = 0
    var captureHook: (@MainActor (Int) -> Void)?
    var fieldReadHook: (@MainActor (Int) -> Void)?
    var beforeInsertionCapture: (@MainActor () -> Void)?
    var dispatchHook: (@MainActor () -> Void)?
    var focusRestorer: (@MainActor (NativeReviewedFocusAuthorization, NativeInputRevocation, ContinuousClock.Instant) async -> NativeReviewedFocusOutcome)?
    var beforeNativeAdmission: (@MainActor () -> Void)?
    var beforeAXExecute: (@MainActor () -> Void)?
    var afterAXWrite: (@MainActor () -> Void)?
    var afterAXOutcome: (@MainActor (NativeFocusedAXInsertion.Outcome) -> Void)?
    var commands: [OwnedNativeComputerUseClient.Command] = []
    var requestIDs: [String] = []
    var now = ContinuousClock.now
    var reservationDuration: Duration = .seconds(90)
    var session: NativeControlSession!
    lazy var authorizer = Authorizer(rig: self)
    private var snapshots = Set<UUID>()
    private lazy var image = try! Self.imageValue()
    private lazy var observer = TargetBoundNativeObservation(backend: .init(capture: { [self] _, _ in
        captureCount += 1; captureHook?(captureCount)
        if captureFailureAt == captureCount { throw OwnedNativeComputerUseClient.Failure.timeout }
        let text = """
        Computer Use state (CUA App Version: 1001824)
        <app_state>
        App=/Applications/Owned Fixture.app/ (bundleID test.owned.native.fixture, pid 4242)
        Window: "Owned fixture", App: Owned Fixture.
        0 standard window Owned fixture
        </app_state>
        """
        let content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])] + (includeImage ? [image] : [])
        return .init(raw: .object(["content": .array(content)]), content: content, isError: false)
    }, close: {}), sessionIsActive: { [self] in active })

    init() {
        session = NativeControlSession(backend: backend, sessionIsActive: { [weak self] in self?.active == true },
            authorizer: authorizer, clockNow: { [weak self] in self?.now ?? .now })
    }
    var backend: NativeControlSession.Backend {
        .init(dispatch: { [self] id, app, command, gate, preflight in
            do {
                guard gate.isActive else { throw NativeControlSession.Failure.stopped }
                let admission = try await preflight(reserved())
                beforeNativeAdmission?()
                try admission.begin(at: now)
            } catch { throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(error) }
            guard app == application.bundleURL.path else { throw NativeControlSession.Failure.wrongOwner }
            requestIDs.append(id); commands.append(command); dispatchHook?()
            return .init(raw: .object(["content": .array([])]), content: [], isError: false)
        }, stop: { [self] in observer.stop() }, drain: { [self] in await observer.drain() },
        reserveAX: { [self] id, app, _, gate, prepare in
            guard app == application.bundleURL.path else { throw NativeControlSession.Failure.wrongOwner }
            let read = reserved()
            let operation: OwnedNativeComputerUseClient.AXInsertionOperation
            do { operation = try await prepare(read) }
            catch { throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(error) }
            beforeAXExecute?()
            // The real owned client checks this same shared gate at its final AX hop.
            guard gate.isActive else { throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(NativeControlSession.Failure.stopped) }
            requestIDs.append(id)
            let outcome = operation.execute()
            afterAXOutcome?(outcome)
            await operation.readback(read, outcome)
            return outcome
        })
    }
    private func reserved() -> OwnedNativeComputerUseClient.ReservedState {
        .init(notAfter: now.advanced(by: reservationDuration), capture: { _, _ in throw NativeControlSession.Failure.invalidAction })
    }
    func target() -> NativeControlSession.Target {
        let version = sourceVersion
        let source: @MainActor () throws -> Void = { [self] in
            guard active else { throw NativeControlSession.Failure.inactiveSession }
            guard sourceVersion == version else { throw TargetBoundNativeObservation.Failure.changedTarget }
        }
        let input: @MainActor () throws -> Void = { [self] in
            try source(); guard foreground else { throw NativeControlSession.Failure.changedFocus }
        }
        let preparation = TargetBoundNativeObservation.Preparation(application: application, window: window,
            validate: source, sourceID: sourceID, validateSource: source, validateInput: input)
        return .init(sourceID: sourceID, application: application, window: window,
            validateOriginalSource: source, validateForInput: input, capture: { [self] _ in
                let snapshot = try await observer.observe(observer.prepare(preparation))
                snapshots.insert(snapshot.id); return snapshot
            }, isCurrent: { [self] in observer.isCurrent($0) }, captureFocusForReview: { [self] authorization in
                try authorization(); focusCaptures += 1
                guard focusAvailable else { throw NativeControlSession.Failure.unavailableFocus }
                let editor = editorVersion
                let identity: @MainActor () throws -> Void = { [self] in
                    try authorization(); try source()
                    guard editorVersion == editor else { throw NativeControlSession.Failure.changedFocus }
                }
                return try NativeControlFocus.capture(.init(validateIdentity: identity,
                    validateInputIdentity: { try identity(); try input() }, metadata: {
                        .init(role: "AXTextArea", subrole: "", protected: false, hidden: false, enabled: true,
                            valueWritable: true, selectionWritable: true)
                    }, qualifiedLabels: { [self] in labelReads += 1; return .init(label: "Actual editor", identifier: "editor") },
                    contents: { [self] in textReads += 1; fieldReadHook?(textReads); return .init(value: field, selection: selection) }))
            }, restoreReviewedOriginalFocus: { [self] authorization, gate, deadline in
                guard let focusRestorer else { return .refused("This synthetic target has no focus-restoration permit.") }
                return await focusRestorer(authorization, gate, deadline)
            },
            captureInsertionForReview: { [self] gate, authorization in
                try authorization(); insertionCaptures += 1; beforeInsertionCapture?()
                guard insertionAvailable else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
                let editor = editorVersion
                let identity: @MainActor () throws -> Void = { [self] in
                    try authorization(); try source()
                    guard editorVersion == editor else { throw NativeFocusedAXInsertion.Failure.changedSource }
                }
                return try NativeFocusedAXInsertion(access: .init(validateOriginalTarget: identity,
                    validateInputTarget: { try identity(); try input() }, metadata: {
                        .init(role: "AXTextArea", subrole: "", protected: false, hidden: false, enabled: true, selectionWritable: true)
                    }, qualifiedLabels: { .init(label: "Actual editor", identifier: "editor") }, contents: { [self] in
                        textReads += 1; fieldReadHook?(textReads)
                        let units = Array(field.utf16), range = selection
                        guard range.location >= 0, range.location <= units.count, range.length >= 0,
                              range.length <= units.count - range.location else { throw NativeFocusedAXInsertion.Failure.invalidSelection }
                        return .init(value: field, selection: range,
                            selectedText: String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self),
                            attributedValue: fieldStorage)
                    }, writeSelectedText: { [self] literal in
                        textWrites += 1
                        let location = selection.location
                        fieldStorage.replaceCharacters(in: selection, with: literal)
                        selection = .init(location: location + literal.utf16.count, length: 0)
                        afterAXWrite?()
                    }), sessionIsActive: { [self] in active }, admissionGate: gate, now: { [self] in now })
            })
    }
    func authorizePlanning() throws {
        guard planningAuthorized else { throw NativeControlSession.Failure.unqualifiedEffect }
    }
    func read() async throws -> NativeControlSession.Observation { try await session.observeForRead(target: target()) }
    func plan() async throws -> NativeControlSession.Observation {
        let source = try session.source(from: await read())
        return try await session.refreshOriginalForInputPlanning(source, authorizeInputPlanning: { [self] in try authorizePlanning() })
    }
    func frame(_ observation: NativeControlSession.Observation) async throws -> NativeVisionFrame {
        let image = try #require(observation.snapshot.images.first)
        return try await NativeVisionFrame.prepare(image: image, observationID: observation.snapshot.id)
    }
    private static func imageValue() throws -> JSONValue {
        let context = try #require(CGContext(data: nil, width: 32, height: 20, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
        let image = try #require(context.makeImage()), data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); try #require(CGImageDestinationFinalize(destination))
        return .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string((data as Data).base64EncodedString())])
    }
    @MainActor final class Request {
        let key: String, raw: Data
        var attempts = 0, valid = true
        init(_ key: String = UUID().uuidString, raw: String = "reused-provider-id") { self.key = key; self.raw = Data(raw.utf8) }
        var admission: NativeControlRequestAdmission {
            .init(requestID: key, originalProviderCallID: raw, exactCallDigest: Data(repeating: 7, count: 32),
                validateAcceptedProposal: { [self] in guard valid else { throw NativeControlSession.Failure.unqualifiedEffect } },
                admitOneAttempt: { [self] in guard valid, attempts == 0 else { throw NativeControlSession.Failure.consumed }; attempts += 1 })
        }
    }
    @MainActor final class Authorizer: NativeControlAuthorizing {
        weak var rig: NextNativeControlRig?
        var consumeCount = 0, authorizations = 0, valid = true
        var whileAuthorizing: (@MainActor () -> Void)?
        var beforeConsume: (@MainActor () -> Void)?
        private var consumed = Set<UUID>()
        init(rig: NextNativeControlRig) { self.rig = rig }
        func authorize(_ context: NativeControlSession.PolicyContext) throws -> NativeControlSession.PolicyPermit {
            guard let rig, valid, context.application == rig.application,
                  context.window.matchesExactly(rig.window), rig.snapshots.contains(context.observationID) else {
                throw NativeControlSession.Failure.unqualifiedEffect
            }
            authorizations += 1; whileAuthorizing?()
            return .init(revalidate: { [self] in
                guard valid, !consumed.contains(context.id) else { throw NativeControlSession.Failure.unqualifiedEffect }
                try context.validateTarget()
            }, consume: { [self] in
                beforeConsume?()
                guard valid, !consumed.contains(context.id) else { throw NativeControlSession.Failure.unqualifiedEffect }
                consumed.insert(context.id); consumeCount += 1
            }, validateTaskSource: { [self] in
                guard valid else { throw NativeControlSession.Failure.unqualifiedEffect }
                try context.validateTarget()
            })
        }
    }
}
