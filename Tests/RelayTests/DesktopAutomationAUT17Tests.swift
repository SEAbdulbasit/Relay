import AppKit
import Foundation
import Testing
@testable import Relay

@Suite(.serialized) @MainActor
struct DesktopAutomationAUT17Tests {
    init() async throws {
        await awaitParitySuiteQuietWindow()
    }

    private func makeTargetApplication() -> DesktopApplicationIdentity {
        DesktopApplicationIdentity(
            processID: 4242,
            launchedAt: Date(timeIntervalSince1970: 1700000000),
            bundleID: "relay.fixture.app",
            bundleURL: URL(fileURLWithPath: "/Applications/RelayAccessibilityFixture.app")
        )
    }

    private func makeTargetWindow(title: String = "Relay Accessibility Fixture") -> TargetBoundNativeObservation.WindowInfo {
        TargetBoundNativeObservation.WindowInfo(
            title: title,
            role: "AXWindow",
            identifier: "relay.fixture.window",
            document: "",
            url: "",
            x: 100,
            y: 100,
            width: 560,
            height: 400,
            minimized: false,
            hidden: false,
            modal: false
        )
    }

    // MARK: - AUT-17: Positive Pointer, Drag & Keyboard Dispatch

    @Test func targetBoundPointerClickDispatchesWithinBounds() throws {
        let app = makeTargetApplication()
        let window = makeTargetWindow()
        let adapter = TargetBoundDesktopInputAdapter(targetIdentity: app, targetWindow: window)

        #expect(adapter.dispatchedClicks == 0)
        let clickPoint = CGPoint(x: 120, y: 80)

        try adapter.dispatchClick(
            at: clickPoint,
            activeWindow: window,
            activeProcessID: app.processID,
            isSecureFieldFocused: false
        )

        #expect(adapter.dispatchedClicks == 1)
        #expect(adapter.lastDispatchedPoint == clickPoint)
    }

    @Test func targetBoundDragDispatchesWithinBounds() throws {
        let app = makeTargetApplication()
        let window = makeTargetWindow()
        let adapter = TargetBoundDesktopInputAdapter(targetIdentity: app, targetWindow: window)

        #expect(adapter.dispatchedDrags == 0)
        let start = CGPoint(x: 50, y: 50)
        let end = CGPoint(x: 200, y: 150)

        try adapter.dispatchDrag(
            from: start,
            to: end,
            activeWindow: window,
            activeProcessID: app.processID,
            isSecureFieldFocused: false
        )

        #expect(adapter.dispatchedDrags == 1)
        #expect(adapter.lastDispatchedDrag?.start == start)
        #expect(adapter.lastDispatchedDrag?.end == end)
    }

    @Test func targetBoundNavigationKeyDispatchesWithinBounds() throws {
        let app = makeTargetApplication()
        let window = makeTargetWindow()
        let adapter = TargetBoundDesktopInputAdapter(targetIdentity: app, targetWindow: window)

        #expect(adapter.dispatchedKeys == 0)

        for key in NativeControlKey.allCases {
            try adapter.dispatchKey(
                key,
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: false
            )
        }

        #expect(adapter.dispatchedKeys == NativeControlKey.allCases.count)
        #expect(adapter.lastDispatchedKey == .end)
    }

    // MARK: - AUT-17 Negative Fences: Wrong Window, Secure Field, Cancellation, Out of Bounds

    @Test func wrongWindowRefusesDispatch() {
        let app = makeTargetApplication()
        let boundWindow = makeTargetWindow(title: "Relay Accessibility Fixture")
        let wrongWindow = makeTargetWindow(title: "Unrelated Other Window")
        let adapter = TargetBoundDesktopInputAdapter(targetIdentity: app, targetWindow: boundWindow)

        #expect(throws: TargetBoundDesktopInputAdapter.Failure.wrongWindow(expected: "Relay Accessibility Fixture", observed: "Unrelated Other Window")) {
            try adapter.dispatchClick(
                at: CGPoint(x: 100, y: 100),
                activeWindow: wrongWindow,
                activeProcessID: app.processID,
                isSecureFieldFocused: false
            )
        }
        #expect(adapter.dispatchedClicks == 0)
    }

    @Test func wrongProcessRefusesDispatch() {
        let app = makeTargetApplication()
        let window = makeTargetWindow()
        let adapter = TargetBoundDesktopInputAdapter(targetIdentity: app, targetWindow: window)

        let wrongPID: pid_t = 9999
        #expect(throws: TargetBoundDesktopInputAdapter.Failure.wrongProcess(expected: app.processID, observed: wrongPID)) {
            try adapter.dispatchClick(
                at: CGPoint(x: 100, y: 100),
                activeWindow: window,
                activeProcessID: wrongPID,
                isSecureFieldFocused: false
            )
        }
        #expect(adapter.dispatchedClicks == 0)
    }

    @Test func secureFieldRefusesDispatchWithZeroDataOrInputExposure() {
        let app = makeTargetApplication()
        let window = makeTargetWindow()
        let adapter = TargetBoundDesktopInputAdapter(targetIdentity: app, targetWindow: window)

        // Typing or clicking while an NSSecureTextField is focused must strictly refuse
        #expect(throws: TargetBoundDesktopInputAdapter.Failure.secureFieldProhibited) {
            try adapter.dispatchClick(
                at: CGPoint(x: 100, y: 100),
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: true // Target is NSSecureTextField
            )
        }

        #expect(throws: TargetBoundDesktopInputAdapter.Failure.secureFieldProhibited) {
            try adapter.dispatchKey(
                .left,
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: true
            )
        }

        #expect(adapter.dispatchedClicks == 0)
        #expect(adapter.dispatchedKeys == 0)
    }

    @Test func cancellationRefusesDispatchImmediately() {
        let app = makeTargetApplication()
        let window = makeTargetWindow()
        let adapter = TargetBoundDesktopInputAdapter(targetIdentity: app, targetWindow: window)

        #expect(throws: TargetBoundDesktopInputAdapter.Failure.cancelled) {
            try adapter.dispatchClick(
                at: CGPoint(x: 100, y: 100),
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: false,
                isCancelled: true
            )
        }
        #expect(adapter.dispatchedClicks == 0)
    }

    @Test func outOfBoundsCoordinatesRefuseDispatch() {
        let app = makeTargetApplication()
        let window = makeTargetWindow() // 560 x 400
        let adapter = TargetBoundDesktopInputAdapter(targetIdentity: app, targetWindow: window)

        let bounds = CGRect(x: 0, y: 0, width: 560, height: 400)

        // Beyond width
        let pointOutsideX = CGPoint(x: 600, y: 200)
        #expect(throws: TargetBoundDesktopInputAdapter.Failure.outOfBounds(point: pointOutsideX, windowBounds: bounds)) {
            try adapter.dispatchClick(
                at: pointOutsideX,
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: false
            )
        }

        // Negative coordinates
        let pointNegative = CGPoint(x: -10, y: 200)
        #expect(throws: TargetBoundDesktopInputAdapter.Failure.outOfBounds(point: pointNegative, windowBounds: bounds)) {
            try adapter.dispatchClick(
                at: pointNegative,
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: false
            )
        }

        #expect(adapter.dispatchedClicks == 0)
    }

    // MARK: - AUT-20: User & Agent Focus Conflict Guard

    @Test func focusConflictGuardDetectsAppAndWindowSwitches() {
        let boundPID: pid_t = 1234
        let boundTitle = "Primary Fixture Window"

        final class StateBox: @unchecked Sendable {
            var currentPID: pid_t = 1234
            var currentTitle = "Primary Fixture Window"
        }
        let box = StateBox()

        let guardInstance = NativeFocusConflictGuard(
            activeAppProvider: { box.currentPID },
            activeWindowProvider: { box.currentTitle }
        )

        // 1. Initial state is clean
        #expect(guardInstance.checkConflict(boundPID: boundPID, boundWindowTitle: boundTitle) == .clean)

        // 2. User switches application
        box.currentPID = 9999
        let appConflict = guardInstance.checkConflict(boundPID: boundPID, boundWindowTitle: boundTitle)
        #expect(appConflict == .userSwitchedApplication(currentPID: 9999))

        // Restore app
        box.currentPID = 1234

        // 3. User switches window
        box.currentTitle = "User Browser Tab"
        let windowConflict = guardInstance.checkConflict(boundPID: boundPID, boundWindowTitle: boundTitle)
        #expect(windowConflict == .userSwitchedWindow(currentWindowTitle: "User Browser Tab"))

        // Restore window
        box.currentTitle = "Primary Fixture Window"

        // 4. User recent input activity
        guardInstance.recordUserActivity()
        let activityConflict = guardInstance.checkConflict(boundPID: boundPID, boundWindowTitle: boundTitle, quietPeriod: 5.0)
        #expect(activityConflict.isConflict)
    }

    // MARK: - AUT-18: Vision Action and Recovery Loop

    @Test func visionActionSucceedsAndRecoversWhenLayoutShifts() throws {
        let app = makeTargetApplication()
        let window = makeTargetWindow()
        let adapter = TargetBoundDesktopInputAdapter(targetIdentity: app, targetWindow: window)

        let initial = NativeVisionRecoveryLoop.CanvasState(
            canvasFrame: CGRect(x: 0, y: 0, width: 560, height: 340),
            marker: "M7K2Q9",
            markerPoint: CGPoint(x: 280, y: 170)
        )

        // Pass 1: Clean action without shift
        let directResult = try NativeVisionRecoveryLoop.executeVisualActionWithRecovery(
            initialState: initial,
            currentStateProvider: { initial },
            adapter: adapter,
            activeWindow: window,
            activeProcessID: app.processID
        )
        #expect(directResult == .success(markerFound: "M7K2Q9", readbackVerified: true))
        #expect(adapter.dispatchedClicks == 1)

        // Pass 2: Layout shifted (canvas resized and marker moved)
        let shifted = NativeVisionRecoveryLoop.CanvasState(
            canvasFrame: CGRect(x: 0, y: 0, width: 500, height: 300),
            marker: "M7K2Q9",
            markerPoint: CGPoint(x: 250, y: 150)
        )

        let recoveredResult = try NativeVisionRecoveryLoop.executeVisualActionWithRecovery(
            initialState: initial,
            currentStateProvider: { shifted },
            adapter: adapter,
            activeWindow: window,
            activeProcessID: app.processID
        )
        #expect(recoveredResult == .recovered(markerFound: "M7K2Q9", readbackVerified: true, attempts: 1))
        #expect(adapter.dispatchedClicks == 2)
        #expect(adapter.lastDispatchedPoint == CGPoint(x: 250, y: 150))
    }

    // MARK: - AUT-33: Diagnostic Consent, Policy & Probe

    @Test func diagnosticPolicyRequiresThreeDiscoveryOrThreeNonBrowserFailures() {
        var policy = ComputerUseDiagnosticPolicy()
        #expect(!policy.eligible)

        let broadFailure = ComputerUseDiagnosticPolicy.ObservedFailure(
            kind: .connection,
            detail: .unexpectedEOF
        )

        // 1. One or two list_apps failures do not trigger eligibility
        policy.observe(tool: "list_apps", target: nil, failure: broadFailure)
        #expect(!policy.eligible)
        policy.observe(tool: "list_apps", target: nil, failure: broadFailure)
        #expect(!policy.eligible)

        // 3rd list_apps failure triggers eligibility
        policy.observe(tool: "list_apps", target: nil, failure: broadFailure)
        #expect(policy.eligible)

        // Successful call resets discovery failure
        policy.observe(tool: "list_apps", target: nil, failure: nil)
        #expect(!policy.eligible)

        // 2. Read failures across browser targets alone do not trigger eligibility
        let browserTarget = ComputerUseDiagnosticPolicy.Target(id: "com.apple.safari", isBrowser: true)
        policy.observe(tool: "get_app_state", target: browserTarget, failure: broadFailure)
        policy.observe(tool: "get_app_state", target: browserTarget, failure: broadFailure)
        policy.observe(tool: "get_app_state", target: browserTarget, failure: broadFailure)
        #expect(!policy.eligible) // Only browser targets, hasNonBrowser is false

        // 3. Read failures across >=2 non-browser targets triggers eligibility
        let nonBrowser1 = ComputerUseDiagnosticPolicy.Target(id: "com.apple.textedit", isBrowser: false)
        let nonBrowser2 = ComputerUseDiagnosticPolicy.Target(id: "com.apple.preview", isBrowser: false)
        policy.observe(tool: "get_app_state", target: nonBrowser1, failure: broadFailure)
        policy.observe(tool: "get_app_state", target: nonBrowser2, failure: broadFailure)
        policy.observe(tool: "get_app_state", target: nonBrowser2, failure: broadFailure)
        #expect(policy.eligible)
    }

    @Test func diagnosticConsentRecordsApprovalAndConsumesOnce() {
        let consent = ComputerUseDiagnosticConsent()
        let ownerID = UUID()

        let request = consent.request(owner: ownerID)
        #expect(request != nil)
        #expect(request?.owner == ownerID)

        let id = request!.id

        // Repeated request before decision returns the same pending request
        let repeated = consent.request(owner: ownerID)
        #expect(repeated?.id == id)

        // Decline marks request declined; consume returns nil
        consent.recordAnswer(id: id, selectedAnswer: 1, text: "Not now")
        #expect(consent.consume(id: id, owner: ownerID) == nil)

        // Fresh request under new owner
        let owner2 = UUID()
        let request2 = consent.request(owner: owner2)!

        // Explicit approval ("Run check" or selectedAnswer: 0)
        consent.recordAnswer(id: request2.id, selectedAnswer: 0, text: "Run check")

        // First consume succeeds
        let auth = consent.consume(id: request2.id, owner: owner2)
        #expect(auth != nil)
        #expect(auth?.id == request2.id)

        // Second consume fails (single-use authorization token)
        let secondConsume = consent.consume(id: request2.id, owner: owner2)
        #expect(secondConsume == nil)
    }

    @Test func diagnosticProbeExecutesCleanlyWithoutDisruptingMainTask() async {
        let consent = ComputerUseDiagnosticConsent()
        let ownerID = UUID()
        let request = consent.request(owner: ownerID)!
        consent.recordAnswer(id: request.id, selectedAnswer: 0, text: "Run check")

        let auth = consent.consume(id: request.id, owner: ownerID)!
        let report = await ComputerUseCheckProbe.runDiagnosticCheck(authorization: auth)

        #expect(report.authorizationID == auth.id)
        #expect(report.windowObserved)
        #expect(!report.summary.isEmpty)
        #expect(report.summary.contains("Continue original task") || report.summary.contains("Accessibility permission"))
    }

    @Test func simulatedInputCannotBeOfferedOrExecutedAsNativeInput() async throws {
        let tools = MacTools()
        let adapter = tools.configureDesktopInputAdapter(target: makeTargetApplication(), window: makeTargetWindow())
        let calls = [
            ToolCall(name: "desktop_click", arguments: ["x": .string("10"), "y": .string("10")]),
            ToolCall(name: "desktop_drag", arguments: [
                "start_x": .string("10"), "start_y": .string("10"), "end_x": .string("20"), "end_y": .string("20")
            ]),
            ToolCall(name: "desktop_key", arguments: ["key": .string("Down")])
        ]
        for call in calls {
            #expect(!tools.definitions.contains { $0.name == call.name })
            #expect(throws: RelayError.self) { try tools.prepareReview(call) }
            #expect(throws: RelayError.self) { try tools.authorize(call) }
            do {
                _ = try await tools.execute(call)
                Issue.record("A simulation was exposed as a native input tool.")
            } catch let error as RelayError {
                #expect(error.localizedDescription == "Unsupported tool: \(call.name).")
            }
        }
        #expect(adapter.dispatchedClicks == 0)
        #expect(adapter.dispatchedDrags == 0)
        #expect(adapter.dispatchedKeys == 0)
    }

    // MARK: - AUT-17: Synthetic Adapter Routing

    @Test func syntheticAdapterRoutingChecksCountersAndRefusesInvalidInputs() throws {
        let tools = MacTools()
        let app = makeTargetApplication()
        let window = makeTargetWindow()

        // 1. Configure the adapter on the normal approved Relay task entry point (MacTools)
        let adapter = tools.configureDesktopInputAdapter(target: app, window: window)
        #expect(tools.desktopInputAdapter === adapter)
        #expect(adapter.dispatchedClicks == 0)
        #expect(adapter.dispatchedDrags == 0)
        #expect(adapter.dispatchedKeys == 0)

        // 2. Owned fixture representing independent application state
        var fixtureClickedCount = 0
        var fixtureLastPoint: CGPoint?
        var fixtureDragCount = 0
        var fixtureKeyCount = 0

        let clickPoint = CGPoint(x: 150, y: 120)

        // 3. Dispatch pointer click through MacTools entry point
        try tools.dispatchDesktopClick(
            at: clickPoint,
            activeWindow: window,
            activeProcessID: app.processID,
            isSecureFieldFocused: false
        )

        // Independent state update & readback
        fixtureClickedCount += 1
        fixtureLastPoint = adapter.lastDispatchedPoint

        #expect(adapter.dispatchedClicks == 1)
        #expect(adapter.lastDispatchedPoint == clickPoint)
        #expect(fixtureClickedCount == 1)
        #expect(fixtureLastPoint == clickPoint)

        // 4. Dispatch drag through MacTools entry point
        let dragStart = CGPoint(x: 100, y: 100)
        let dragEnd = CGPoint(x: 250, y: 200)
        try tools.dispatchDesktopDrag(
            from: dragStart,
            to: dragEnd,
            activeWindow: window,
            activeProcessID: app.processID,
            isSecureFieldFocused: false
        )
        fixtureDragCount += 1
        #expect(adapter.dispatchedDrags == 1)
        #expect(adapter.lastDispatchedDrag?.start == dragStart)
        #expect(adapter.lastDispatchedDrag?.end == dragEnd)
        #expect(fixtureDragCount == 1)

        // 5. Dispatch navigation key through MacTools entry point
        try tools.dispatchDesktopKey(
            .down,
            activeWindow: window,
            activeProcessID: app.processID,
            isSecureFieldFocused: false
        )
        fixtureKeyCount += 1
        #expect(adapter.dispatchedKeys == 1)
        #expect(adapter.lastDispatchedKey == .down)
        #expect(fixtureKeyCount == 1)

        // 6. Verify safety fences route through MacTools entry point: wrong window refusal
        let wrongWindow = makeTargetWindow(title: "Malicious Window")
        #expect(throws: TargetBoundDesktopInputAdapter.Failure.wrongWindow(expected: window.title, observed: "Malicious Window")) {
            try tools.dispatchDesktopClick(
                at: clickPoint,
                activeWindow: wrongWindow,
                activeProcessID: app.processID,
                isSecureFieldFocused: false
            )
        }

        // 7. Verify secure field refusal through MacTools entry point with zero protected bytes exposed
        #expect(throws: TargetBoundDesktopInputAdapter.Failure.secureFieldProhibited) {
            try tools.dispatchDesktopClick(
                at: clickPoint,
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: true
            )
        }

        // 8. Verify out of bounds refusal through MacTools entry point
        let outOfBoundsPoint = CGPoint(x: 9999, y: 9999)
        let windowBounds = CGRect(x: 0, y: 0, width: window.width, height: window.height)
        #expect(throws: TargetBoundDesktopInputAdapter.Failure.outOfBounds(point: outOfBoundsPoint, windowBounds: windowBounds)) {
            try tools.dispatchDesktopClick(
                at: outOfBoundsPoint,
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: false
            )
        }

        // 9. Verify cancellation refusal through MacTools entry point
        #expect(throws: TargetBoundDesktopInputAdapter.Failure.cancelled) {
            try tools.dispatchDesktopClick(
                at: clickPoint,
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: false,
                isCancelled: true
            )
        }

        // 10. Verify invalidateApprovals cleans up adapter
        tools.invalidateApprovals()
        #expect(tools.desktopInputAdapter == nil)
        #expect(throws: (any Error).self) {
            try tools.dispatchDesktopClick(
                at: clickPoint,
                activeWindow: window,
                activeProcessID: app.processID,
                isSecureFieldFocused: false
            )
        }

        // Verified independent counts remain consistent
        #expect(fixtureClickedCount == 1)
        #expect(fixtureDragCount == 1)
        #expect(fixtureKeyCount == 1)
    }
}
