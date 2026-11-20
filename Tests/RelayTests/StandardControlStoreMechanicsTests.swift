import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import PolicyMetadataProcess
import Testing
@preconcurrency import LiteRTLM
@testable import Relay
@testable import RelayJournal

/// HELD mechanics only. The model is scripted; the acknowledged Store, actual
/// production factory, policy reader, client, original AX editor and journal are
/// real. No fixture-specific production policy or replacement input is used.
private final class StandardMechanicsHostMarker: NSObject {}

@MainActor @Suite(.serialized) struct StandardControlStoreMechanicsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_OWNED_GESTURES"] == "1"),
          .timeLimit(.minutes(5)))
    func ordinaryClickDragAndNavigationReachTheOwnedWindow() async throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(AXIsProcessTrusted(), "Existing host trust is required. This check never requests it.")
        try #require(environment["RELAY_RUN_STANDARD_CONTROL_MECHANICS"] != "1"
            && environment["RELAY_RUN_EXACT_UNSENT_STORE_MECHANICS"] != "1")
        let evidence = try root(environment["RELAY_POLICY_METADATA_EVIDENCE_DIR"])
        let runtimePath = try #require(environment["RELAY_STANDARD_CONTROL_RUNTIME_MANIFEST"]).ownedURL
        let runtimeBytes = try Relay.LocalStateFile.read(runtimePath, maximumBytes: 65_536)
        try #require(sha(runtimeBytes) == environment["RELAY_STANDARD_CONTROL_RUNTIME_MANIFEST_SHA256"])
        let runtimeManifest = try #require(try JSONSerialization.jsonObject(with: runtimeBytes) as? [String: Any])
        let appURL = try #require(environment["RELAY_STANDARD_POLICY_FIXTURE_APP"]).ownedURL
        let manifest = try object(try #require(environment["RELAY_STANDARD_POLICY_FIXTURE_MANIFEST"]).ownedURL,
                                  maximum: 512 * 1_024)
        let executable = appURL.appendingPathComponent("Contents/MacOS/RelayStandardPolicyFixture")
        let bundleID = try #require(manifest["bundleID"] as? String)
        let fixtureBundleID = "dev.relay.standard-policy-fixture"
        let freshPrefix = fixtureBundleID + "."
        try #require(bundleID == fixtureBundleID
            || (bundleID.hasPrefix(freshPrefix) && UUID(uuidString: String(bundleID.dropFirst(freshPrefix.count))) != nil))
        try #require(Bundle(url: appURL)?.bundleIdentifier == bundleID && manifest["bundlePath"] as? String == appURL.path)
        try #require(manifest["executableSHA256"] as? String
            == sha(try Relay.LocalStateFile.read(executable, maximumBytes: 64 * 1_024 * 1_024)))
        let gestures: [Gesture]
        if let selected = environment["RELAY_OWNED_GESTURE_CASE"] {
            gestures = [try #require(Gesture(rawValue: selected))]
        } else {
            gestures = Gesture.allCases
        }
        for gesture in gestures {
            // LaunchServices can briefly retain the previous fixture after its
            // kernel lifetime ends. Wait until exclusive app lookup is clear.
            try await wait {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .allSatisfy(\.isTerminated)
            }
            do {
                try await ownedFixture(scene: gesture == .navigation ? "control-navigation" : "control-pointer",
                                       appURL: appURL, executable: executable, evidence: evidence, bundleID: bundleID) { fixture in
                    try await exerciseGesture(gesture, fixture: fixture, runtimeManifest: runtimeManifest)
                }
            } catch is ExpectationFailedError {
                // Swift Testing already recorded the failed requirement.
                try Task.checkCancellation()
            } catch {
                try Task.checkCancellation()
                Issue.record(error, "Owned \(gesture.rawValue) case failed.")
            }
        }
    }

    enum Gesture: String, CaseIterable, Sendable {
        case click, drag, navigation

        @MainActor var tool: String { self == .navigation ? NativeWindowControlTools.keyName : NativeWindowControlTools.pointerName }
        var instruction: String {
            switch self {
            case .click: "Click once in the blank lower half of the original window."
            case .drag: "Drag once horizontally across the blank lower half of the original window."
            case .navigation: "Press Left once in the original focused editor."
            }
        }
    }

    private func exerciseGesture(_ gesture: Gesture, fixture: Fixture, runtimeManifest: [String: Any]) async throws {
        try #require(fixture.application.activate(options: []))
        var exclusiveSince: ContinuousClock.Instant?
        try await wait {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: fixture.identity.bundleID)
                .filter { !$0.isTerminated }
            let available = running.count == 1 && running.first.map {
                DesktopApplicationTarget.matches(fixture.identity, application: $0)
            } == true
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.identity.processID
                && (try? fixture.oracle()["windowKey"] as? Bool) == true
            // LaunchServices can briefly publish a new process and then omit
            // it as the application finishes registering its bundle.
            guard available else { exclusiveSince = nil; return false }
            let now = ContinuousClock.now
            let stableFrom = exclusiveSince ?? now
            exclusiveSince = stableFrom
            return now >= stableFrom.advanced(by: .seconds(1))
        }
        let baseline = try fixture.oracle()
        try zeroEvents(baseline)
        let witness = try StandardControlRuntimeWitness(sceneDirectory: fixture.directory,
            nonce: fixture.nonce, scene: fixture.scene, runtimeManifest: runtimeManifest)
        let samples = Samples()
        let audit = NativeReadAudit { samples.record($0) }
        let runtime = GestureRuntime(gesture)
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime }, visionRuntimeFactory: { _, _, _ in runtime })
        let modelURL = fixture.directory.appendingPathComponent("script-only.litertlm")
        try Data([1]).write(to: modelURL)
        let history = AssistantConversationHistory(stateURL: fixture.directory.appendingPathComponent("owned-history.json"))
        var turns = 0, factories = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, catalog, _ in
            try fixture.validate()
            turns += 1
            try #require(turns <= 6)
            if turns == 1 {
                try #require(catalog.contains { $0.name == NativeWindowControlTools.outerName })
                return .init(content: "", toolCalls: [.init(id: "owned-gesture", name: NativeWindowControlTools.outerName,
                    arguments: ["bundle_id": .string(fixture.identity.bundleID), "instruction": .string(gesture.instruction),
                                "input_kind": .string(gesture == .navigation ? "navigation" : "pointer")])])
            }
            return .init(content: "The independent fixture will check the effect.", toolCalls: [])
        }, conversationHistory: history, modelClient: client, nativeTaskControl: { scope, input in
            try fixture.validate()
            factories += 1
            return try .productionCandidate(scope: scope, inputAuthority: input, readAudit: audit,
                processStarted: { try witness.record($0) })
        })
        store.configuration = .init(modelPath: modelURL.path, computeBackend: "cpu", model: "Gemma 4 E4B")
        store.draft = "Only in the already running owned synthetic application. " + gesture.instruction
            + " Do not submit, repeat input, or switch apps."
        var failure: (any Error)?
        do {
            await store.waitForConversationTaskToSettle()
            let admission = NativeWindowTaskAdapter.ApplicationAdmission(application: fixture.identity, validate: { try fixture.validate() })
            let submission = try #require(store.send(nativeReadRestrictions: [admission]))
            try #require(await submission.waitForAcknowledgment() == .saved)
            if gesture != .navigation {
                try await wait(for: .seconds(90)) { store.pendingReview != nil || !store.isRunning }
                let pendingReview = store.pendingReview
                let review = try #require(pendingReview, "The original pointer action must reach exact visual review.")
                let presentation = try #require(review.visualPresentation)
                try #require(review.canApprove && presentation.imageIsDecodable)
                try zeroEvents(fixture.oracle())
                try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.identity.processID)
                store.approveReview()
            }
            try await wait(for: gesture == .navigation ? .seconds(240) : .seconds(90)) { !store.isRunning }
            await store.waitForConversationTaskToSettle()
            let receiptDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while (try? fixture.oracle()["inputEventCounts"] as? [String: Int])?.isEmpty != false,
                  ContinuousClock.now < receiptDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let actual = try fixture.oracle()
            try save(actual, fixture.directory.appendingPathComponent("post-task-raw-oracle.json"))
            try #require(actual["applicationActivations"] as? Int == baseline["applicationActivations"] as? Int
                && actual["applicationResignations"] as? Int == baseline["applicationResignations"] as? Int)
            try #require(actual["ownedEditorValuesUnchanged"] as? Bool == true
                && actual["buttonActions"] as? Int == 0 && actual["textChanges"] as? Int == 0)
            try verifyGesture(gesture, oracle: actual)
            try #require(factories == 1 && (try witness.registeredCount()) == 1 && runtime.sends == 1)
            try #require(try await journalIntents(history).filter { $0.toolName == gesture.tool }.count == 1)
            try save(["gesture": gesture.rawValue, "ownedReceiptVerified": true, "scriptedModel": true],
                     fixture.directory.appendingPathComponent("gesture-result.json"))
        } catch { failure = error }
        store.stop()
        await store.waitForConversationTaskToSettle()
        client.unload()
        do {
            try await history.close()
            try save(fixture.oracle(), fixture.directory.appendingPathComponent("final-raw-oracle.json"))
            try save(["gesture": gesture.rawValue, "readAudit": samples.json(), "metadata": try samples.metadataJSON(),
                "activity": store.activity.map { ["name": $0.name, "status": $0.status, "detail": String($0.detail.prefix(256))] }],
                fixture.directory.appendingPathComponent("gesture-diagnostics.json"))
        } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    private func verifyGesture(_ gesture: Gesture, oracle: [String: Any]) throws {
        let counts = try #require(oracle["inputEventCounts"] as? [String: Int])
        let down = String(NSEvent.EventType.leftMouseDown.rawValue)
        let dragged = String(NSEvent.EventType.leftMouseDragged.rawValue)
        let up = String(NSEvent.EventType.leftMouseUp.rawValue)
        switch gesture {
        case .click, .drag:
            try #require(counts[down] == 1 && counts[up] == 1)
            let locations = try #require(oracle["lastPointerLocationsInWindow"] as? [String: [Double]])
            let start = try #require(locations[down]), end = try #require(locations[up])
            try #require(start.count == 2 && end.count == 2)
            if gesture == .drag {
                try #require((counts[dragged] ?? 0) > 0 && Set(counts.keys) == [down, up, dragged])
                try #require(end[0] - start[0] > 20 && abs(end[1] - start[1]) <= 3)
            } else {
                try #require(Set(counts.keys) == [down, up])
                try #require(abs(end[0] - start[0]) <= 3 && abs(end[1] - start[1]) <= 3)
            }
        case .navigation:
            let keyDown = String(NSEvent.EventType.keyDown.rawValue), keyUp = String(NSEvent.EventType.keyUp.rawValue)
            try #require(counts == [keyDown: 1, keyUp: 1] && oracle["lastNavigationKeyCode"] as? Int == 123)
        }
    }

    @MainActor private final class GestureRuntime: LocalModelRuntime {
        let gesture: Gesture
        var sends = 0
        init(_ gesture: Gesture) { self.gesture = gesture }

        func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
            let toolFree = config.tools.isEmpty
            if !toolFree { try #require(config.tools.contains { type(of: $0).name == gesture.tool }) }
            return Conversation(self, toolFree: toolFree)
        }

        @MainActor private final class Conversation: LocalConversationSession {
            unowned let runtime: GestureRuntime
            let toolFree: Bool
            init(_ runtime: GestureRuntime, toolFree: Bool) {
                self.runtime = runtime
                self.toolFree = toolFree
            }

            func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
                if toolFree {
                    return .init("No independent semantic confirmation was scripted.", role: .model)
                }
                runtime.sends += 1
                try #require(runtime.sends == 1, "The owned gesture must never repeat.")
                let body = message.toString
                let regex = try NSRegularExpression(pattern:
                    "observation ([0-9A-F-]{36}), image ([0-9A-F-]{36})\\.\\s+Original native screenshot: [0-9]+ by [0-9]+ pixels\\.\\s+Attached local image: ([0-9]+) by ([0-9]+) pixels")
                let match = try #require(regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)))
                func capture(_ index: Int) throws -> String {
                    String(body[try #require(Range(match.range(at: index), in: body))])
                }
                var arguments: [String: Any] = ["observation_id": try capture(1), "intended_effect": runtime.gesture.instruction]
                if runtime.gesture == .navigation {
                    arguments["key"] = NativeControlKey.left.rawValue
                } else {
                    let width = try #require(Int(capture(3))), height = try #require(Int(capture(4)))
                    try #require(width >= 100 && height >= 100)
                    arguments["image_id"] = try capture(2)
                    arguments["kind"] = runtime.gesture.rawValue
                    arguments["x"] = width / 3
                    arguments["y"] = height * 4 / 5
                    if runtime.gesture == .drag {
                        arguments["end_x"] = width * 2 / 3
                        arguments["end_y"] = arguments["y"]
                    }
                }
                return .init(contents: [], role: .model, toolCalls: [
                    .init(name: runtime.gesture.tool, id: "owned-inner-gesture", arguments: arguments)
                ])
            }

            nonisolated func cancel() {}
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_STANDARD_CONTROL_MECHANICS"] == "1"), .timeLimit(.minutes(4)))
    func secureAncestorRefusesBeforePrivateReadsAndOneOrdinaryUnsentUnicodeActionUsesProductionFactory() async throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(AXIsProcessTrusted(), "Existing host trust is required; this gate never requests permission.")
        let evidence = try root(environment["RELAY_POLICY_METADATA_EVIDENCE_DIR"])
        let runtimePath = try #require(environment["RELAY_STANDARD_CONTROL_RUNTIME_MANIFEST"]).ownedURL
        let runtimeBytes = try Relay.LocalStateFile.read(runtimePath, maximumBytes: 65_536)
        let runtimeHash = try #require(environment["RELAY_STANDARD_CONTROL_RUNTIME_MANIFEST_SHA256"])
        try #require(runtimeHash.utf8.count == 64 && sha(runtimeBytes) == runtimeHash)
        let runtimeManifest = try #require(try JSONSerialization.jsonObject(with: runtimeBytes) as? [String: Any])
        let appURL = try #require(environment["RELAY_STANDARD_POLICY_FIXTURE_APP"]).ownedURL
        let manifestURL = try #require(environment["RELAY_STANDARD_POLICY_FIXTURE_MANIFEST"]).ownedURL
        let manifest = try object(manifestURL, maximum: 512 * 1_024)
        let executable = appURL.appendingPathComponent("Contents/MacOS/RelayStandardPolicyFixture")
        try #require(manifest["bundleID"] as? String == "dev.relay.standard-policy-fixture")
        try #require(manifest["bundlePath"] as? String == appURL.path)
        try #require(manifest["executableSHA256"] as? String == sha(try Relay.LocalStateFile.read(executable, maximumBytes: 64 * 1_024 * 1_024)))
        let host = try #require(Kernel.read(ProcessInfo.processInfo.processIdentifier))
        try save(["pid": host.pid, "kernelStart": host.start, "executable": host.executable,
                  "bundle": Bundle(for: StandardMechanicsHostMarker.self).bundleURL.path,
                  "scope": "Scripted model; actual standard AppKit Store/factory/controller mechanics only."], evidence.appendingPathComponent("host-started.json"))
        // Stop after the first failed scene. No mutation or source fallback.
        for scene in ["control-secure", "control"] {
            try await ownedFixture(scene: scene, appURL: appURL, executable: executable, evidence: evidence) { lease in
                try await exercise(lease, secure: scene == "control-secure", runtimeManifest: runtimeManifest)
            }
        }
        try save(["completed": true, "allScenesCompleted": true, "actualModel": false, "scope": "One literal unsent field action only; no generic gesture, browser, background input, pinned Resume or goal-completion qualification."], evidence.appendingPathComponent("host-completed.json"))
    }

    /// DISTINCT opt-in/filter. This uses real panels/AX and programmatic
    /// production menu/composer handlers, not a physical UI click qualification.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_EXACT_UNSENT_STORE_MECHANICS"] == "1"), .timeLimit(.minutes(4)))
    func exactUnsentSidekickSavedHandoffRestoresOriginalAndIndependentlyVerifies() async throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(environment["RELAY_RUN_STANDARD_CONTROL_MECHANICS"] != "1", "Old/new native UI scenarios must never run together.")
        try #require(AXIsProcessTrusted(), "Existing host trust only; never request or change grants.")
        let evidence = try root(environment["RELAY_POLICY_METADATA_EVIDENCE_DIR"])
        let runtimePath = try #require(environment["RELAY_STANDARD_CONTROL_RUNTIME_MANIFEST"]).ownedURL
        let runtimeBytes = try Relay.LocalStateFile.read(runtimePath, maximumBytes: 65_536)
        try #require(sha(runtimeBytes) == environment["RELAY_STANDARD_CONTROL_RUNTIME_MANIFEST_SHA256"])
        let runtimeManifest = try #require(try JSONSerialization.jsonObject(with: runtimeBytes) as? [String: Any])
        let appURL = try #require(environment["RELAY_STANDARD_POLICY_FIXTURE_APP"]).ownedURL
        let manifest = try object(try #require(environment["RELAY_STANDARD_POLICY_FIXTURE_MANIFEST"]).ownedURL, maximum: 512 * 1_024)
        let executable = appURL.appendingPathComponent("Contents/MacOS/RelayStandardPolicyFixture")
        try #require(manifest["bundleID"] as? String == "dev.relay.standard-policy-fixture" && manifest["bundlePath"] as? String == appURL.path)
        try #require(manifest["executableSHA256"] as? String == sha(try Relay.LocalStateFile.read(executable, maximumBytes: 64 * 1_024 * 1_024)))
        let selectedFault = environment["RELAY_EXACT_UNSENT_RESULT_SAVE_FAULT"] ?? "none"
        try #require(["none", "focus", "insertion"].contains(selectedFault))
        let acknowledgmentIntervention = environment["RELAY_EXACT_UNSENT_ACK_INTERVENTION"] ?? "none"
        try #require(["none", "pendingNFD", "savedNFD", "savedStop", "savedKindSwitch"].contains(acknowledgmentIntervention))
        try #require(selectedFault == "none" || acknowledgmentIntervention == "none")
        let host = try #require(Kernel.read(ProcessInfo.processInfo.processIdentifier))
        // The SwiftPM loader's own policy is not inferred from its path. Make
        // only this owned test process activatable when it was prohibited,
        // retain the checked outcome, and restore before the host exits.
        let hostApplication = NSApplication.shared
        let originalPolicy = hostApplication.activationPolicy()
        let requiredPolicyChange = originalPolicy == .prohibited
        var setupSucceeded = false
        var effectivePolicy = originalPolicy.rawValue
        defer {
            let policyBeforeRestoration = hostApplication.activationPolicy().rawValue
            let restorationRequested = policyBeforeRestoration != originalPolicy.rawValue
            let restored = !restorationRequested || hostApplication.setActivationPolicy(originalPolicy)
            let actualRestoredPolicy = hostApplication.activationPolicy().rawValue
            let restoreSucceeded = restored && actualRestoredPolicy == originalPolicy.rawValue
            if !restoreSucceeded { Issue.record("Owned test host activation policy was not restored.") }
            do {
                try save(["pid": host.pid, "kernelStart": host.start,
                    "originalPolicy": originalPolicy.rawValue, "effectivePolicy": effectivePolicy,
                    "requiredChange": requiredPolicyChange, "setupSucceeded": setupSucceeded,
                    "policyBeforeRestoration": policyBeforeRestoration, "restorationRequested": restorationRequested,
                    "restoreSucceeded": restoreSucceeded, "restoredPolicy": actualRestoredPolicy],
                    evidence.appendingPathComponent("host-activation-policy-cleanup.json"))
            } catch { Issue.record("Owned test host activation policy cleanup receipt could not be saved.") }
        }
        setupSucceeded = !requiredPolicyChange || hostApplication.setActivationPolicy(.accessory)
        effectivePolicy = hostApplication.activationPolicy().rawValue
        try #require(setupSucceeded && effectivePolicy == (requiredPolicyChange ? NSApplication.ActivationPolicy.accessory.rawValue : originalPolicy.rawValue),
            "Owned test host could not establish the required activatable policy.")
        try save(["pid": host.pid, "kernelStart": host.start, "executable": host.executable,
                  "bundle": Bundle(for: StandardMechanicsHostMarker.self).bundleURL.path,
                  "scope": "Direct exact-unsent; real Sidekick handler/Store/SQLite/AX; no model or physical-UI-click claim."], evidence.appendingPathComponent("host-started.json"))
        var firstSceneFailure: (any Error)?
        var sceneResults: [[String: Any]] = []
        for scene in ["control-secure", "control"] {
            var fixtureCleaned = false, taskCleaned = true
            do {
            try Task.checkCancellation()
            try await ownedFixture(scene: scene, appURL: appURL, executable: executable, evidence: evidence,
                exactCleanup: { fixtureCleaned = $0 }) { fixture in
                let secure = scene == "control-secure"
                try #require(fixture.application.activate(options: []))
                try await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.identity.processID }
                let baseline = try fixture.oracle(); try zeroEvents(baseline)
                let samples = Samples(), audit = NativeReadAudit { samples.record($0) }
                let witness = try StandardControlRuntimeWitness(sceneDirectory: fixture.directory,
                    nonce: fixture.nonce, scene: fixture.scene, runtimeManifest: runtimeManifest)
                let history = AssistantConversationHistory(stateURL: fixture.directory.appendingPathComponent("direct-state.json"))
                taskCleaned = false
                var modelCalls = 0, toolCalls = 0
                let store = AssistantStore(persistenceURL: fixture.directory.appendingPathComponent("store.json"), complete: { _, _, _ in
                    modelCalls += 1; throw RelayError.message("Direct flow unexpectedly invoked a model.")
                }, conversationHistory: history, execute: { _ in
                    toolCalls += 1; throw RelayError.message("Direct flow unexpectedly invoked the generic executor.")
                }, exactUnsentReadAudit: audit, exactUnsentProcessStarted: { try witness.record($0) })
                let preferencesName = "relay-owned-exact-sidekick-" + UUID().uuidString
                let preferences = try #require(UserDefaults(suiteName: preferencesName))
                preferences.set(false, forKey: "relay.sidekick.showInNotch")
                var captureFailure: NativeExactUnsentCaptureDiagnostic?
                let controller = NotchOverlayController(preferences: preferences, presentsPanels: true,
                    exactPreparationDiagnostic: { captureFailure = $0 })
                let literal = acknowledgmentIntervention == "pendingNFD" || acknowledgmentIntervention == "savedNFD"
                    ? "  Direct caf\u{e9} 🌍 — unsent  " : "  Direct cafe\u{301} 🌍 — unsent  "
                let editedLiteral = "  Direct cafe\u{301} 🌍 — unsent  "
                var primary: (any Error)?
                var mechanicsReport: [String: Any]?
                var failureStage = "restoreStore"
                var readiness: [String: Bool] = [:]
                var captureAttempted = false
                do {
                    await store.waitForConversationTaskToSettle()
                    controller.connect(store: store, available: true, openWorkspace: {})
                    failureStage = "captureReadiness"
                    // Frontmost PID alone can arrive before AppKit's window
                    // is key. Wait for this exact existing fixture to be ready
                    // at capture, using the original activation only.
                    try await wait {
                        let oracle = try? fixture.oracle()
                        readiness = [
                            "applicationActive": fixture.application.isActive,
                            "frontmostMatches": NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.identity.processID,
                            "fixtureActive": oracle?["applicationActive"] as? Bool == true,
                            "fixtureWindowKey": oracle?["windowKey"] as? Bool == true,
                        ]
                        return readiness.values.allSatisfy { $0 }
                    }
                    failureStage = "captureOriginal"
                    captureAttempted = true
                    controller.open() // actual original captured before makeKey
                    var capture: [String: Any] = ["scene": fixture.scene, "nonce": fixture.nonce.uuidString,
                        "pid": fixture.identity.processID, "kernelStart": fixture.stamp.start,
                        "readiness": readiness, "available": controller.exactTextActionAvailable,
                        "failure": controller.exactTextPreparationFailure.map { String(describing: $0) } ?? "none"]
                    if let captureFailure {
                        capture["diagnostic"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(captureFailure))
                    }
                    try save(capture, fixture.directory.appendingPathComponent("exact-capture-diagnostic.json"))
                    if secure, !controller.exactTextActionAvailable {
                        failureStage = "secureCaptureOracle"
                        try #require(controller.exactTextPreparationFailure == .protectedContext,
                            "A timeout/unavailable capture is not a protected-source pass.")
                        let refused = try fixture.oracle(); try zeroEvents(refused)
                        try #require(refused["ownedEditorValuesUnchanged"] as? Bool == true && refused["textChanges"] as? Int == 0)
                        try #require((try witness.registeredCount()) == 0 && modelCalls == 0 && toolCalls == 0)
                        mechanicsReport = ["secure": true, "captureProtected": true, "cliStartReceipts": 0,
                            "modelCalls": modelCalls, "genericToolCalls": toolCalls, "physicalUIClickQualified": false]
                    } else {
                    try #require(controller.exactTextActionAvailable)
                    failureStage = "composerFocus"
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    try await wait {
                        controller.hasKeyboardFocus && NSWorkspace.shared.frontmostApplication?.processIdentifier == host.pid
                            && (try? fixture.oracle()["applicationActive"] as? Bool) == false
                    }
                    let composerFocused = try fixture.oracle(); try zeroEvents(composerFocused)
                    try #require(composerFocused["textChanges"] as? Int == 0)
                    try save(composerFocused, fixture.directory.appendingPathComponent("composer-focused-raw-oracle.json"))
                    failureStage = "submit"
                    controller.chooseExactTextAction(); try #require(controller.isExactTextMode)
                    controller.exactLiteral = literal
                    let core = try await history.journalForTesting()
                    if !secure, selectedFault != "none" {
                        await core.injectResultFault(.afterCommit, forToolName: selectedFault == "focus" ? "native_exact_unsent_focus" : "native_exact_unsent_insert")
                    }
                    controller.submit(store: store)
                    let ticket = try #require(controller.pendingSubmission)
                    var savedObserverRuns = 0
                    if !secure, acknowledgmentIntervention != "none" {
                        ticket.onAcknowledgment { status in
                            guard status == .saved else { return }
                            savedObserverRuns += 1
                            // This callback is inside real resolve(.saved),
                            // after actual saved-owner/preclaim app validation
                            // and before Store's acknowledged flag is set.
                            switch acknowledgmentIntervention {
                            case "savedNFD": controller.exactLiteral = editedLiteral
                            case "savedStop": store.stop()
                            case "savedKindSwitch": controller.chooseOrdinaryPrompt()
                            default: break
                            }
                        }
                        if acknowledgmentIntervention == "pendingNFD" { controller.exactLiteral = editedLiteral }
                    }
                    failureStage = "savedHandoff"
                    let status = await ticket.waitForAcknowledgment()
                    try #require(status == (!secure && acknowledgmentIntervention == "pendingNFD" ? .stopped : .saved))
                    await store.waitForConversationTaskToSettle()
                    if !secure, selectedFault != "none" {
                        failureStage = "storageRepair"
                        try #require(store.phase == .needsInput && store.canResumeCurrentTask)
                        let beforeRepair = try fixture.oracle()
                        try save(beforeRepair, fixture.directory.appendingPathComponent("before-storage-repair-raw-oracle.json"))
                        // Storage repair alone performs no native phase; Continue
                        // advances this SAME operation only after its real token.
                        try await store.retryConversationStorage()
                        let repaired = try fixture.oracle()
                        try #require(repaired["textChanges"] as? Int == beforeRepair["textChanges"] as? Int)
                        try #require(repaired["applicationActivations"] as? Int == beforeRepair["applicationActivations"] as? Int)
                        store.resume(); await store.waitForConversationTaskToSettle()
                    }
                    failureStage = "taskOracle"
                    let actual = try fixture.oracle(); try zeroEvents(actual)
                    try save(actual, fixture.directory.appendingPathComponent("post-task-raw-oracle.json"))
                    let intents = try await journalIntents(history)
                    let deniedAtAcknowledgment = !secure && acknowledgmentIntervention != "none"
                    try #require(modelCalls == 0 && toolCalls == 0 && !store.actionsReady)
                    try #require((try witness.registeredCount()) == (deniedAtAcknowledgment ? 0 : 1))
                    try #require(samples.count(.nativeStateWriteAttempt) == 0)
                    if deniedAtAcknowledgment {
                        try #require(store.phase != .completed && !store.canResumeCurrentTask && intents.isEmpty)
                        try #require(actual["ownedEditorValuesUnchanged"] as? Bool == true && actual["textChanges"] as? Int == 0)
                        try #require(samples.privateQueryCount == 0)
                        try #require(savedObserverRuns == (acknowledgmentIntervention == "pendingNFD" ? 0 : 1))
                        if acknowledgmentIntervention == "pendingNFD" || acknowledgmentIntervention == "savedNFD" {
                            try #require(Data(literal.utf8) != Data(editedLiteral.utf8))
                            try #require(Data(controller.exactLiteral.utf8) == Data(editedLiteral.utf8))
                        }
                        let rows = try await exactJournalRecords(history)
                        if acknowledgmentIntervention != "pendingNFD" {
                            let saved = try #require(rows.first { $0.event.id.bytes == Data(ticket.messageID.uuidString.utf8) })
                            guard case .user(let user) = saved.event.payload else { throw RelayError.message("Expected actual saved user row.") }
                            try #require(Data(user.text.utf8) == Data(AssistantStore.exactUnsentRequestText(literal).utf8))
                        }
                    } else if secure {
                        try #require(store.phase != .completed && samples.count(.policyProtectedRefusal) > 0)
                        try #require(samples.privateQueryCount == 0 && actual["ownedEditorValuesUnchanged"] as? Bool == true)
                        try #require(actual["textChanges"] as? Int == 0 && intents.isEmpty)
                    } else {
                        try #require(store.phase == .completed && store.errorMessage == nil)
                        try #require(actual["applicationActive"] as? Bool == true && actual["windowKey"] as? Bool == true)
                        try #require((actual["applicationActivations"] as? Int ?? 0) > (composerFocused["applicationActivations"] as? Int ?? 0))
                        let fields = try #require(actual["ownedFieldValues"] as? [String])
                        try #require(fields.count == 2 && Data(fields[0].utf8) == Data(literal.utf8))
                        try #require(Data(fields[1].utf8) == Data("Keep unrelated 🧭 exactly".utf8))
                        try #require(actual["ownedTextViewValues"] as? [String] == [""] && actual["textChanges"] as? Int == 1)
                        try #require(actual["buttonActions"] as? Int == 0)
                        let editor = try #require(actual["actualFieldEditor"] as? [String: Any])
                        try #require(editor["selectionLocation"] as? Int == literal.utf16.count && editor["selectionLength"] as? Int == 0)
                        try #require(intents.filter { $0.toolName == "native_exact_unsent_focus" }.count == 1)
                        try #require(intents.filter { $0.toolName == "native_exact_unsent_insert" }.count == 1 && intents.count == 2)
                        let rows = try await exactJournalRecords(history)
                        let results = rows.compactMap { row -> JournalToolOutcome? in
                            if case .result(let outcome) = row.event.payload { return outcome }; return nil
                        }
                        try #require(results.count == 2 && results.allSatisfy { $0.kind == .returnedVerified })
                        for intent in intents {
                            try #require(results.filter { $0.invocationID == intent.invocationID && $0.callDigest == intent.callDigest }.count == 1)
                        }
                        try save(["intentInvocationIDs": intents.map { $0.invocationID.uuidString },
                            "savedResultInvocationIDs": results.map { $0.invocationID.uuidString },
                            "savedResultCount": results.count], fixture.directory.appendingPathComponent("durable-phase-oracle.json"))
                    }
                    mechanicsReport = ["secure": secure, "phase": store.phase.rawValue, "modelCalls": modelCalls, "genericToolCalls": toolCalls,
                        "selectedStorageFault": selectedFault, "programmaticProductionHandlers": true, "physicalUIClickQualified": false,
                        "acknowledgmentIntervention": acknowledgmentIntervention, "savedObserverRuns": savedObserverRuns,
                        "readAudit": samples.json(), "metadataDiagnostics": try samples.metadataJSON()]
                    }
                } catch { primary = error }
                controller.hideFloatingNotchPanel(); store.stop(); await store.waitForConversationTaskToSettle()
                var historyClosed = false
                do { try await history.close(); historyClosed = true }
                catch { if primary == nil { primary = error; failureStage = "historyCleanup" } }
                taskCleaned = !store.isRunning && historyClosed
                preferences.removePersistentDomain(forName: preferencesName)
                do {
                    let passed = mechanicsReport != nil && primary == nil && taskCleaned
                    var report = mechanicsReport ?? ["secure": secure, "phase": store.phase.rawValue,
                        "modelCalls": modelCalls, "genericToolCalls": toolCalls, "physicalUIClickQualified": false]
                    report["scene"] = fixture.scene; report["nonce"] = fixture.nonce.uuidString
                    report["pid"] = fixture.identity.processID; report["kernelStart"] = fixture.stamp.start
                    report["passed"] = passed
                    report["firstFailureStage"] = primary == nil ? "none" : failureStage
                    report["firstFailureType"] = primary.map { String(reflecting: type(of: $0)) } ?? "none"
                    report["taskSettled"] = !store.isRunning; report["historyClosed"] = historyClosed
                    try save(report, fixture.directory.appendingPathComponent("mechanics-result.json"))
                    try save(["scene": fixture.scene, "nonce": fixture.nonce.uuidString,
                        "pid": fixture.identity.processID, "kernelStart": fixture.stamp.start, "historyClosed": historyClosed, "taskSettled": !store.isRunning, "cliStartReceipts": (try? witness.registeredCount()) ?? -1,
                        "modelCalls": modelCalls, "genericToolCalls": toolCalls, "readAudit": samples.json(), "metadataDiagnostics": try samples.metadataJSON(),
                        "captureAttempted": captureAttempted, "captureReadiness": readiness,
                        "firstFailureStage": primary == nil ? "none" : failureStage,
                        "firstFailureType": primary.map { String(reflecting: type(of: $0)) } ?? "none"], fixture.directory.appendingPathComponent("task-cleanup.json"))
                    try save(fixture.oracle(), fixture.directory.appendingPathComponent("final-raw-oracle.json"))
                } catch { if primary == nil { primary = error } }
                if let primary { throw primary }
            }
                try #require(fixtureCleaned && taskCleaned)
                sceneResults.append(["scene": scene, "passed": true, "fixtureCleaned": fixtureCleaned, "taskCleaned": taskCleaned])
            } catch {
                if firstSceneFailure == nil { firstSceneFailure = error }
                sceneResults.append(["scene": scene, "passed": false, "fixtureCleaned": fixtureCleaned, "taskCleaned": taskCleaned,
                    "failureType": String(reflecting: type(of: error))])
                // Preserve the failed secure oracle while permitting a fresh
                // ordinary scene only after all original ownership settles.
                if Task.isCancelled || !fixtureCleaned || !taskCleaned { break }
            }
        }
        do { try save(["scenes": sceneResults], evidence.appendingPathComponent("host-exact-scene-results.json")) }
        catch { if firstSceneFailure == nil { firstSceneFailure = error } }
        if let firstSceneFailure { throw firstSceneFailure }
        try #require(sceneResults.count == 2 && sceneResults.allSatisfy {
            $0["passed"] as? Bool == true && $0["fixtureCleaned"] as? Bool == true && $0["taskCleaned"] as? Bool == true
        })
        try save(["completed": true, "allScenesCompleted": true, "actualModel": false,
            "scope": "Direct exact-unsent synthetic owned AppKit fields; physical UI clicks and general autonomous control unqualified."], evidence.appendingPathComponent("host-completed.json"))
    }

    private func exactJournalRecords(_ history: AssistantConversationHistory) async throws -> [JournalRecord] {
        let core = try await history.journalForTesting(), scope = try await core.scope()
        let page = try await core.page(expectedScope: scope)
        return page.records
    }

    private func exercise(_ fixture: Fixture, secure: Bool, runtimeManifest: [String: Any]) async throws {
        try fixture.validate()
        let baseline = try fixture.oracle()
        try zeroEvents(baseline)
        try #require(baseline["textChanges"] as? Int == 0 && baseline["buttonActions"] as? Int == 0)
        // Setup precondition only. Never reactivate during planning or execution.
        try #require(fixture.application.activate(options: []))
        try await wait {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.identity.processID
                && (try? fixture.oracle()["windowKey"] as? Bool) == true
                && (try? fixture.oracle()["applicationActive"] as? Bool) == true
        }
        try fixture.validate()
        let focusedBaseline = try fixture.oracle(); try zeroEvents(focusedBaseline)
        try save(focusedBaseline, fixture.directory.appendingPathComponent("focused-baseline-raw-oracle.json"))
        let literal = "Native unsent cafe\u{301} 🌍 — owned field"
        let samples = Samples()
        let audit = NativeReadAudit { samples.record($0) }
        let witness = try StandardControlRuntimeWitness(sceneDirectory: fixture.directory,
            nonce: fixture.nonce, scene: fixture.scene, runtimeManifest: runtimeManifest)
        let runtime = Runtime(literal: literal)
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime }, visionRuntimeFactory: { _, _, _ in runtime })
        let modelURL = fixture.directory.appendingPathComponent("script-only.litertlm")
        try Data([1]).write(to: modelURL)
        let history = AssistantConversationHistory(stateURL: fixture.directory.appendingPathComponent("owned-history.json"))
        var ordinaryTurns = 0, factories = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, catalog, _ in
            try fixture.validate()
            ordinaryTurns += 1
            try #require(ordinaryTurns <= 6, "Scripted mechanics exceeded its held qualification turn bound.")
            try #require(catalog.contains { $0.name == NativeWindowControlTools.outerName })
            if ordinaryTurns == 1 {
                return .init(content: "", toolCalls: [.init(id: "owned-outer", name: NativeWindowControlTools.outerName,
                    arguments: ["bundle_id": .string(fixture.identity.bundleID),
                        "instruction": .string("Enter only the exact user-requested unsent literal into the original focused editor; do not submit, click, press keys or change other fields.")])])
            }
            return .init(content: "The retained original field operation has a factual result; this mechanics probe makes no broader goal claim.", toolCalls: [])
        }, conversationHistory: history, modelClient: client, nativeTaskControl: { scope, input in
            try fixture.validate(); factories += 1
            // The exact real production composition; no policy/AX/input stand-in.
            return try .productionCandidate(scope: scope, inputAuthority: input, readAudit: audit,
                processStarted: { started in try witness.record(started) })
        })
        store.configuration = .init(modelPath: modelURL.path, computeBackend: "cpu", model: "Gemma 4 E4B")
        store.draft = "Only in this already running owned synthetic application, enter the exact unsent literal \"" + literal + "\" in its original focused empty field. Leave all other fields unchanged. Do not submit, click, press keys or repeat input."
        var primary: (any Error)?
        do {
            await store.waitForConversationTaskToSettle()
            let restriction = NativeWindowTaskAdapter.ApplicationAdmission(application: fixture.identity, validate: { try fixture.validate() })
            let submission = try #require(store.send(nativeReadRestrictions: [restriction]))
            try #require(await submission.waitForAcknowledgment() == .saved)
            try await wait { !store.isRunning }
            await store.waitForConversationTaskToSettle()
            try fixture.validate()
            let actual = try fixture.oracle()
            try save(actual, fixture.directory.appendingPathComponent("post-task-raw-oracle.json"))
            try zeroEvents(actual)
            try #require(actual["applicationActivations"] as? Int == focusedBaseline["applicationActivations"] as? Int
                && actual["applicationResignations"] as? Int == focusedBaseline["applicationResignations"] as? Int,
                "The owned app's focus drifted after setup; do not normalize or retry this run.")
            try #require(actual["buttonActions"] as? Int == 0)
            try #require(factories == 1 && (try witness.registeredCount()) == 1)
            let intents = try await journalIntents(history)
            let privateQueries = samples.privateQueryCount
            if secure {
                try #require(runtime.sends == 0 && runtime.images == 0)
                try #require(privateQueries == 0 && samples.count(.nativeStateWriteAttempt) == 0)
                try #require(samples.count(.policySurvey) > 0, "Secure refusal must reach the real reader, not just fail setup.")
                try #require(samples.count(.policyProtectedRefusal) > 0,
                    "The actual production policy must report protectedContext; a timeout or unavailable source is not a protected-source pass.")
                for other in [NativeReadAudit.Stage.policyDeadlineRefusal, .policyIncompleteRefusal,
                              .policyUnavailableRefusal, .policyChangedContextRefusal, .policyDedicatedRefusal, .policyOtherRefusal] {
                    try #require(samples.count(other) == 0, "Secure source classification was replaced by another refusal; retain the first evidence.")
                }
                try #require(actual["ownedEditorValuesUnchanged"] as? Bool == true && actual["textChanges"] as? Int == 0)
                try #require(!intents.contains { $0.toolName == NativeWindowControlTools.textName })
            } else {
                try #require(store.pendingReview == nil, "A plain ordinary bound editor must not need a fabricated review approval.")
                try #require(store.errorMessage == nil, "Actual standard-control mechanics failed; retain first stage diagnostics.")
                try #require(runtime.sends == 1 && runtime.images == 1)
                try #require(samples.count(.editorValue) > 0 && samples.count(.editorStyle) > 0)
                try #require(samples.count(.nativeStateWriteAttempt) > 0)
                let fields = try #require(actual["ownedFieldValues"] as? [String])
                try #require(fields.count == 2)
                try #require(Array(fields[0].utf16) == Array(literal.utf16))
                try #require(Array(fields[1].utf16) == Array("Keep unrelated 🧭 exactly".utf16))
                try #require(actual["ownedTextViewValues"] as? [String] == [""])
                let editor = try #require(actual["actualFieldEditor"] as? [String: Any])
                try #require(editor["selectionLocation"] as? Int == literal.utf16.count && editor["selectionLength"] as? Int == 0)
                try #require(actual["textChanges"] as? Int == 1)
                try #require(intents.filter { $0.toolName == NativeWindowControlTools.textName }.count == 1)
                try #require(!intents.contains { $0.toolName == NativeWindowControlTools.outerName })
            }
            try save(["scene": fixture.scene, "nonce": fixture.nonce.uuidString, "pid": fixture.identity.processID,
                "kernelStart": fixture.stamp.start, "secure": secure, "factories": factories, "scriptedVisionSends": runtime.sends, "images": runtime.images,
                "ordinaryTurns": ordinaryTurns, "phase": String(describing: store.phase), "errorNil": store.errorMessage == nil,
                "readAudit": samples.json(), "metadataDiagnostics": try samples.metadataJSON(), "scope": "OS/private-query attempts and stage durations only; no model, semantic-goal or global input claim."], fixture.directory.appendingPathComponent("mechanics-result.json"))
        } catch { primary = error }
        // All outcomes drain this exact task/client before fixture termination.
        store.stop(); await store.waitForConversationTaskToSettle(); client.unload()
        var historyClosed = false
        do { try await history.close(); historyClosed = true } catch { if primary == nil { primary = error } }
        do {
            try save(["historyClosed": historyClosed, "cliStartReceipts": (try? witness.registeredCount()) ?? -1,
                "taskSettled": !store.isRunning, "modelUnloaded": !client.isLoaded, "readAudit": samples.json(), "metadataDiagnostics": try samples.metadataJSON(),
                "scriptedVisionSends": runtime.sends, "images": runtime.images,
                "firstFailureType": primary.map { String(reflecting: type(of: $0)) } ?? "none"], fixture.directory.appendingPathComponent("task-cleanup.json"))
        } catch { if primary == nil { primary = error } }
        // Save first-failure raw owned state without replacing its original error.
        if let raw = try? fixture.oracle() {
            do { try save(raw, fixture.directory.appendingPathComponent("final-raw-oracle.json")) }
            catch { if primary == nil { primary = error } }
        }
        if let primary { throw primary }
    }

    @MainActor private final class Runtime: LocalModelRuntime {
        let literal: String
        var sends = 0, images = 0
        init(literal: String) { self.literal = literal }
        func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
            try #require(config.tools.contains { type(of: $0).name == NativeWindowControlTools.textName }, "No qualified original editor text wrapper was offered.")
            return Conversation(self)
        }
        @MainActor private final class Conversation: LocalConversationSession {
            unowned let runtime: Runtime
            init(_ runtime: Runtime) { self.runtime = runtime }
            func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
                runtime.sends += 1
                try #require(runtime.sends == 1, "Never retry the physical text action.")
                for part in message.contents { if case .imageData = part { runtime.images += 1 } }
                let body = message.toString
                let re = try NSRegularExpression(pattern: "observation ([0-9A-F-]{36}), image ([0-9A-F-]{36})")
                let match = try #require(re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)))
                let observation = String(body[try #require(Range(match.range(at: 1), in: body))])
                return .init(contents: [], role: .model, toolCalls: [.init(name: NativeWindowControlTools.textName, id: "owned-inner",
                    arguments: ["observation_id": observation, "text": runtime.literal, "intended_effect": "Enter the exact requested unsent literal; preserve unrelated fields and do not submit."])])
            }
            nonisolated func cancel() {}
        }
    }

    private struct Kernel: Equatable {
        let pid: pid_t, start: UInt64, executable: String
        static func read(_ pid: pid_t) -> Self? {
            var start: UInt64 = 0, bytes = [CChar](repeating: 0, count: 4_096)
            let result = bytes.withUnsafeMutableBufferPointer { relay_policy_process_identity(pid, &start, $0.baseAddress, $0.count) }
            guard result == 0, start > 0 else { return nil }
            return .init(pid: pid, start: start, executable: String(cString: bytes))
        }
    }
    @MainActor private struct Fixture {
        let application: NSRunningApplication
        let identity: DesktopApplicationIdentity
        let stamp: Kernel
        let directory: URL, report: URL
        let nonce: UUID
        let scene: String
        func validate() throws {
            try Task.checkCancellation()
            try #require(Kernel.read(identity.processID) == stamp && DesktopApplicationTarget.matches(identity, application: application))
        }
        func oracle() throws -> [String: Any] {
            try validate()
            let value = try StandardControlStoreMechanicsTests.object(report, maximum: 65_536)
            try #require(value["nonce"] as? String == nonce.uuidString && (value["pid"] as? NSNumber)?.int32Value == identity.processID)
            try #require(value["oracleOverflow"] as? Bool != true)
            return value
        }
    }
    private func ownedFixture(scene: String, appURL: URL, executable: URL, evidence: URL,
                              bundleID: String = "dev.relay.standard-policy-fixture",
                              exactCleanup: (@MainActor (Bool) -> Void)? = nil,
                              body: (Fixture) async throws -> Void) async throws {
        let nonce = UUID(), directory = evidence.appendingPathComponent(nonce.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let report = directory.appendingPathComponent("fixture-state.json")
        let executableHash = sha(try Relay.LocalStateFile.read(executable, maximumBytes: 64 * 1_024 * 1_024))
        let config = NSWorkspace.OpenConfiguration(); config.activates = false; config.createsNewApplicationInstance = true; config.addsToRecentItems = false
        config.arguments = ["--scene", scene, "--nonce", nonce.uuidString, "--report", report.path, "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        try save(["nonce": nonce.uuidString, "scene": scene, "bundleURL": appURL.path, "executable": executable.path,
            "executableSHA256": executableHash, "reportPath": report.path], directory.appendingPathComponent("launch-intent.json"))
        let application = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        // Every post-open step is inside this cleanup boundary. The returned
        // object alone never authorizes name/group or replacement-PID cleanup.
        let returnedPID = application.processIdentifier
        var observed: Kernel?, owned: Kernel?, primary: (any Error)?
        do {
            let stamp = try #require(Kernel.read(returnedPID)); observed = stamp
            let kernelExecutable = URL(fileURLWithPath: stamp.executable)
            try #require(kernelExecutable.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath())
            let arguments = try StandardControlRuntimeWitness.arguments(of: returnedPID, expectedExecutable: kernelExecutable)
            func exact(_ key: String, _ value: String) -> Bool {
                let positions = arguments.indices.dropLast().filter { arguments[$0] == Data(key.utf8) }
                return positions.count == 1 && arguments[positions[0] + 1] == Data(value.utf8)
            }
            try #require(exact("--scene", scene) && exact("--nonce", nonce.uuidString) && exact("--report", report.path))
            try #require(sha(try Relay.LocalStateFile.read(executable, maximumBytes: 64 * 1_024 * 1_024)) == executableHash)
            try #require(Kernel.read(returnedPID) == stamp)
            owned = stamp
            let identity = try #require(DesktopApplicationTarget.identity(of: application))
            try #require(identity.bundleID == bundleID && identity.bundleURL == appURL)
            try save(["nonce": nonce.uuidString, "scene": scene, "pid": stamp.pid, "kernelStart": stamp.start,
                "executable": stamp.executable, "executableSHA256": executableHash, "bundleURL": appURL.path,
                "launchDate": identity.launchedAt.timeIntervalSince1970, "reportPath": report.path], directory.appendingPathComponent("owned-process.json"))
            let lease = Fixture(application: application, identity: identity, stamp: stamp, directory: directory, report: report, nonce: nonce, scene: scene)
            try await wait { (try? lease.oracle()["state"] as? String) == "ready" }
            let initial = try lease.oracle(); try #require(initial["localMonitorInstalledBeforeWindow"] as? Bool == true)
            try save(initial, directory.appendingPathComponent("initial-raw-oracle.json"))
            try await body(lease)
        } catch { primary = error }
        var terminationRequested = false, cleanupRefused = false
        if let owned, Kernel.read(returnedPID) == owned, application.processIdentifier == owned.pid {
            // Exact kernel lifetime + signed reviewed executable + private
            // nonce argv was established before any source-capability check.
            terminationRequested = application.terminate()
            do {
                try await wait { Kernel.read(returnedPID) != owned && (exactCleanup == nil || application.isTerminated) }
            } catch { if primary == nil { primary = error } }
        } else if Kernel.read(returnedPID) != nil {
            // No inferred identity. The independent supervisor may reconcile
            // the saved launch intent/startup report; this host cannot guess.
            cleanupRefused = true
        }
        let absent: Bool
        if let owned { absent = Kernel.read(returnedPID) != owned }
        else { absent = Kernel.read(returnedPID) == nil }
        do {
            try save(["ownedProcessAbsent": absent, "returnedPID": returnedPID,
                "observedKernelStart": observed?.start ?? 0, "provedOriginalKernelStart": owned?.start ?? 0,
                "executable": executable.path, "scene": scene, "nonce": nonce.uuidString,
                "terminationRequested": terminationRequested, "cleanupRefusedWithoutExactProof": cleanupRefused,
                "firstFailureType": primary.map { String(reflecting: type(of: $0)) } ?? "none"], directory.appendingPathComponent("fixture-cleanup.json"))
            exactCleanup?(owned != nil && absent && !cleanupRefused && application.isTerminated)
        } catch { if primary == nil { primary = error } }
        if let primary { throw primary }
        try #require(absent && !cleanupRefused)
    }
    private func journalIntents(_ history: AssistantConversationHistory) async throws -> [JournalIntent] {
        let journal = try await history.journalForTesting(), scope = try await journal.scope()
        let page = try await journal.page(expectedScope: scope)
        try #require(!page.hasLater)
        return page.records.compactMap { if case .intent(let intent) = $0.event.payload { intent } else { nil } }
    }
    private func zeroEvents(_ value: [String: Any]) throws {
        let counts = try #require(value["inputEventCounts"] as? [String: Int])
        try #require(counts.values.allSatisfy { $0 == 0 }, "Unexpected owned input event; preserve first evidence and stop.")
    }
    private func root(_ value: String?) throws -> URL {
        let url = try #require(value).ownedURL, temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        try #require(url.deletingLastPathComponent() == temporary && url.lastPathComponent.hasPrefix("relay-standard-policy-"))
        try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        return url
    }
    private static func object(_ url: URL, maximum: Int) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Relay.LocalStateFile.read(url, maximumBytes: maximum)) as? [String: Any])
    }
    private func object(_ url: URL, maximum: Int) throws -> [String: Any] { try Self.object(url, maximum: maximum) }
    private func save(_ value: [String: Any], _ url: URL) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        try #require(bytes.count <= 128 * 1_024); try bytes.write(to: url, options: .atomic)
    }
    private func sha(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private func wait(for duration: Duration = .seconds(35), _ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: duration)
        while !predicate() { try Task.checkCancellation(); try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(20)) }
    }
    nonisolated private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [NativeReadAudit.Stage: Int] = [:]
        private var durations: [NativeReadAudit.Stage: Duration] = [:]
        private var metadataDiagnostics = NativeReadAudit.MetadataBuffer()
        func record(_ value: NativeReadAudit.Sample) {
            lock.lock(); defer { lock.unlock() }
            counts[value.stage, default: 0] += 1
            durations[value.stage, default: .zero] += value.elapsed
            if let diagnostic = value.metadata {
                metadataDiagnostics.append(diagnostic)
            }
        }
        func metadataJSON() throws -> [String: Any] {
            lock.lock()
            let snapshot = metadataDiagnostics
            lock.unlock()
            let data = try JSONEncoder().encode(snapshot.samples)
            return ["samples": try JSONSerialization.jsonObject(with: data),
                "maximumSamples": NativeReadAudit.MetadataBuffer.maximumSamples, "omitted": snapshot.omitted]
        }
        func count(_ stage: NativeReadAudit.Stage) -> Int { lock.lock(); defer { lock.unlock() }; return counts[stage] ?? 0 }
        var privateQueryCount: Int { [NativeReadAudit.Stage.policyLabel, .editorLabel, .editorValue, .editorSelection, .editorSelectedText, .editorStyle].reduce(0) { $0 + count($1) } }
        func json() -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            return Dictionary(uniqueKeysWithValues: NativeReadAudit.Stage.allCases.map { stage in
                let parts = (durations[stage] ?? .zero).components
                let row: [String: Any] = ["count": counts[stage] ?? 0,
                    "totalSeconds": Double(parts.seconds) + Double(parts.attoseconds) / 1e18]
                return (stage.rawValue, row as Any)
            })
        }
    }
}

private extension String {
    var ownedURL: URL { URL(fileURLWithPath: self).resolvingSymlinksInPath() }
}
