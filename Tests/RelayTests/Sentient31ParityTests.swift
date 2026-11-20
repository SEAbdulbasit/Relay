import Darwin
import Foundation
import SQLite3
import Testing
@testable import Relay

@MainActor @Suite(.serialized) struct Sentient31ParityTests {
    private let sampleTool = ToolDefinition(
        name: "launch_app",
        description: "Review opening an application",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["name": .object(["type": .string("string")])]),
            "required": .array([.string("name")])
        ])
    )

    // MARK: - Domain 1: Codex CLI Dynamic Signing, Multi-Turn, Images & Claude CLI + Fair Lease

    @Test func codexDynamicSigningRejectsUnsignedScriptsUnlessExplicitlyOptedIn() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RelayCodexParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeBinary = tempDir.appendingPathComponent("codex")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        // Unsigned binary does not pass dynamic Apple Developer ID 2DC432GLL2 + identifier "codex" validation
        #expect(CodexCLIClient.validateOpenAISignature(fakeBinary) == false)
        #expect(CodexCLIClient.signedCodeHash(fakeBinary) == nil)

        // Strict mode rejects unverified standalone binary as .unsupported
        let strict = CodexCLIClient.discoverExecutable(allowUnverifiedStandalone: false, candidates: [fakeBinary])
        switch strict {
        case .failure(.unsupported): break
        default: Issue.record("Expected .unsupported for unsigned codex binary when opt-in is false, got \(strict)")
        }

        // Explicit standalone opt-in discovers the runnable binary while marking isOfficialOpenAISigned = false
        let optedIn = try CodexCLIClient.discoverExecutable(allowUnverifiedStandalone: true, candidates: [fakeBinary]).get()
        #expect(optedIn.url.path == fakeBinary.resolvingSymlinksInPath().path)
        #expect(optedIn.isOfficialOpenAISigned == false)

        // If /Applications/ChatGPT.app's embedded codex exists on this Mac, dynamic signing validates it without hardcoded CDHashes
        let embeddedChatGPTCodex = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        if FileManager.default.isExecutableFile(atPath: embeddedChatGPTCodex.path) {
            #expect(CodexCLIClient.validateOpenAISignature(embeddedChatGPTCodex) == true)
            let discovered = try CodexCLIClient.discoverExecutable(allowUnverifiedStandalone: false, candidates: [embeddedChatGPTCodex]).get()
            #expect(discovered.isOfficialOpenAISigned == true)
        }
    }

    @Test func codexPlanningArgumentsSupportReasoningEffortImagesAndSessionResume() {
        let workspace = URL(fileURLWithPath: "/private/tmp/relay-codex-args", isDirectory: true)
        let schema = workspace.appendingPathComponent("schema.json")

        let freshArgs = CodexCLIClient.planningArguments(
            workspace: workspace,
            schema: schema,
            reasoningEffort: .high,
            model: "gpt-6.1-terra",
            imagePaths: ["/private/tmp/frame-0.png", "/private/tmp/frame-1.jpg"],
            resumeThreadID: nil
        )
        #expect(freshArgs.contains("--ephemeral"))
        #expect(freshArgs.contains("model_reasoning_effort=\"high\""))
        #expect(freshArgs.contains("--image"))
        #expect(freshArgs.contains("/private/tmp/frame-0.png"))
        #expect(freshArgs.contains("/private/tmp/frame-1.jpg"))
        #expect(freshArgs.last == "-")

        let resumedArgs = CodexCLIClient.planningArguments(
            workspace: workspace,
            schema: schema,
            reasoningEffort: .medium,
            model: "gpt-6.1-sol",
            imagePaths: [],
            resumeThreadID: "thread_abc123"
        )
        #expect(resumedArgs.contains("resume"))
        #expect(resumedArgs.contains("thread_abc123"))
        #expect(!resumedArgs.contains("--ephemeral"))
        #expect(resumedArgs.contains("history.persistence=\"save-all\""))
        #expect(resumedArgs.contains("model_reasoning_effort=\"medium\""))
    }

    @Test func claudeCLIClientEnforcesHermeticEnvironmentAndParsesStreamJSONProposals() throws {
        let cliURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        let workspace = URL(fileURLWithPath: "/private/tmp/relay-claude-env", isDirectory: true)
        let env = ClaudeCLIClient.sanitizedEnvironment(cli: cliURL, workspace: workspace)

        // Sentient 3.1 parity: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC must be "" (never "1" or "0")
        #expect(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "")
        #expect(env["DISABLE_AUTOUPDATER"] == "1")
        #expect(env["DISABLE_TELEMETRY"] == "1")
        #expect(env["DISABLE_ERROR_REPORTING"] == "1")
        #expect(env["TMPDIR"] == workspace.path)

        let args = ClaudeCLIClient.planningArguments(
            modelID: "sonnet",
            effort: .high,
            schema: #"{"type":"object"}"#,
            inputFormat: .streamJSON,
            resumeSessionID: "sess_42"
        )
        #expect(args.contains("-p"))
        #expect(args.contains("stream-json"))
        #expect(args.contains("--verbose"))
        #expect(args.contains("--disable-slash-commands"))
        #expect(args.contains("--resume"))
        #expect(args.contains("sess_42"))

        // Auth status JSON parsing
        let authJSON = Data(#"{"loggedIn":true,"subscriptionType":"max","email":"user@example.com","orgId":"org_1"}"#.utf8)
        let status = try #require(ClaudeCLIClient.parseAuthStatus(authJSON))
        #expect(status.loggedIn == true)
        #expect(status.plan == "max")
        #expect(status.accountFingerprint != nil)
        #expect(ClaudeCLIReadiness.ready(plan: "max").isReady == true)
        #expect(ClaudeCLIReadiness.missing.message.contains("Claude"))

        // Stream-JSON direct answer parsing
        let answerStream = Data("""
        {"type":"system","session_id":"sess_direct_1"}
        {"type":"result","is_error":false,"session_id":"sess_direct_1","structured_output":{"content":"All set.","tool_name":"","arguments_json":"{}"}}
        """.utf8)
        let parsedAnswer = try ClaudeCLIClient.parseStreamJSON(answerStream, tools: [sampleTool])
        #expect(parsedAnswer.reply.content == "All set.")
        #expect(parsedAnswer.reply.toolCalls.isEmpty)
        #expect(parsedAnswer.sessionID == "sess_direct_1")

        // Stream-JSON validated tool proposal parsing
        let toolStream = Data("""
        {"type":"result","is_error":false,"session_id":"sess_tool_2","structured_output":{"content":"","tool_name":"launch_app","arguments_json":"{\\"name\\":\\"Safari\\"}"}}
        """.utf8)
        let parsedTool = try ClaudeCLIClient.parseStreamJSON(toolStream, tools: [sampleTool])
        #expect(parsedTool.reply.toolCalls.count == 1)
        #expect(parsedTool.reply.toolCalls.first?.name == "launch_app")
        #expect(parsedTool.reply.toolCalls.first?.arguments == ["name": .string("Safari")])

        // Reject unpermitted tool proposals
        let badToolStream = Data("""
        {"type":"result","is_error":false,"structured_output":{"content":"","tool_name":"unknown_tool","arguments_json":"{}"}}
        """.utf8)
        #expect(throws: ModelProtocolError.self) {
            _ = try ClaudeCLIClient.parseStreamJSON(badToolStream, tools: [sampleTool])
        }

        // Map rate-limit and auth rejections cleanly
        let rateLimitedStream = Data("""
        {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour"}}
        {"type":"result","is_error":true,"result":"You hit your limit."}
        """.utf8)
        #expect(throws: ClaudeCLIError.self) {
            _ = try ClaudeCLIClient.parseStreamJSON(rateLimitedStream, exitStatus: 1, tools: [])
        }
        ClaudeCLIClient.resetPreferences()
    }

    @Test func localInferenceLeaseQueuesOverlappingCallersInFIFOAndRemovesCancelledWaiters() async throws {
        let lease = LocalInferenceLease()
        var executionOrder: [String] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        var firstEntered: CheckedContinuation<Void, Never>?

        let firstTask = Task { @MainActor in
            try await lease.withLease {
                executionOrder.append("first-start")
                firstEntered?.resume()
                firstEntered = nil
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    releaseFirst = cont
                }
                executionOrder.append("first-end")
                return "one"
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            firstEntered = cont
            if lease.isBusy {
                firstEntered = nil
                cont.resume()
            }
        }
        #expect(lease.isBusy == true)

        let cancelledWaiter = Task { @MainActor in
            try await lease.withLease {
                executionOrder.append("cancelled-should-not-run")
                return "cancelled"
            }
        }
        let secondWaiter = Task { @MainActor in
            try await lease.withLease {
                executionOrder.append("second")
                return "two"
            }
        }
        let thirdWaiter = Task { @MainActor in
            try await lease.withLease {
                executionOrder.append("third")
                return "three"
            }
        }

        // Let the three waiters enqueue in FIFO order
        while lease.queuedWaiterCount < 3 {
            await Task.yield()
        }
        #expect(lease.queuedWaiterCount == 3)

        // Cancel the first waiter while queued — it must be removed immediately without blocking FIFO peers
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledWaiter.value
        }
        #expect(lease.queuedWaiterCount == 2)

        // Release the active holder and verify fair FIFO completion with zero spurious .busy errors
        releaseFirst?.resume()
        releaseFirst = nil

        #expect(try await firstTask.value == "one")
        #expect(try await secondWaiter.value == "two")
        #expect(try await thirdWaiter.value == "three")
        #expect(executionOrder == ["first-start", "first-end", "second", "third"])
        #expect(lease.isBusy == false)
        #expect(lease.queuedWaiterCount == 0)
    }

    // MARK: - Domain 3: Checkpointed Live Sources, Plugged-In Scheduler & OAuth PKCE/State/Generation Fencing

    @Test func checkpointedLiveLocalSourcesPersistWatermarksAndResumeIncrementally() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RelayLiveSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Build a synthetic WhatsApp SQLite database (ChatStorage.sqlite) so incremental SQLite checkpointing runs hermetically
        let waURL = tempDir.appendingPathComponent("ChatStorage.sqlite")
        let baseApple = Date().timeIntervalSinceReferenceDate - 20_000
        var db: OpaquePointer?
        #expect(sqlite3_open(waURL.path, &db) == SQLITE_OK)
        let schemaSQL = """
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZSESSIONTYPE INTEGER, ZMESSAGECOUNTER INTEGER, ZLASTMESSAGEDATE REAL);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGEDATE REAL, ZTEXT TEXT, ZSTANZAID TEXT, ZFROMJID TEXT, ZGROUPMEMBER INTEGER, ZMESSAGETYPE INTEGER DEFAULT 0);
        INSERT INTO ZWACHATSESSION VALUES (1, '15551234567@s.whatsapp.net', 'Alex Rivera', 0, 2, \(baseApple + 100));
        INSERT INTO ZWAMESSAGE VALUES (10, 1, 0, \(baseApple + 50), 'Can you review the Q4 launch deck before Friday?', 'stanza-10', '15551234567@s.whatsapp.net', NULL, 0);
        """
        #expect(sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let paths = LiveLocalSourcePaths(
            notesDatabaseURL: tempDir.appendingPathComponent("missing-notes.sqlite"),
            messagesDatabaseURL: tempDir.appendingPathComponent("missing-chat.db"),
            whatsappDatabaseURL: waURL,
            mailRootURL: tempDir.appendingPathComponent("Mail", isDirectory: true),
            addressBookRootURL: tempDir.appendingPathComponent("AddressBook", isDirectory: true),
            fdaProbePaths: [("whatsapp", waURL.path)]
        )
        let stateDir = tempDir.appendingPathComponent("State", isDirectory: true)
        let coordinator = LiveLocalSourcesCoordinator(
            paths: paths,
            directoryURL: stateDir,
            fullDiskAccessProbe: { FullDiskAccessStatus(granted: true, matchedProbe: "test", errnoCode: 0) }
        )
        coordinator.setEnabled(.whatsapp, true)

        let firstBatch = try await coordinator.runIncrementalIngestion(sources: [.whatsapp], maxItemsPerSource: 10)
        #expect(firstBatch.count == 1)
        #expect(firstBatch.first?.body.contains("Q4 launch deck") == true)

        // Second pass with no new rows must ingest 0 duplicates thanks to durable bucket cursor
        let secondBatch = try await coordinator.runIncrementalIngestion(sources: [.whatsapp], maxItemsPerSource: 10)
        #expect(secondBatch.isEmpty)

        // Append a newer message in a fresh 3-hour window (> 3h later) and reload from persisted checkpoints on disk
        #expect(sqlite3_open(waURL.path, &db) == SQLITE_OK)
        let newerApple = baseApple + 12_000
        let appendSQL = """
        INSERT INTO ZWAMESSAGE VALUES (11, 1, 1, \(newerApple), 'Sounds good, I will send feedback tonight.', 'stanza-11', NULL, NULL, 0);
        UPDATE ZWACHATSESSION SET ZLASTMESSAGEDATE = \(newerApple), ZMESSAGECOUNTER = 3 WHERE Z_PK = 1;
        """
        #expect(sqlite3_exec(db, appendSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let reloadedCoordinator = LiveLocalSourcesCoordinator(
            paths: paths,
            directoryURL: stateDir,
            fullDiskAccessProbe: { FullDiskAccessStatus(granted: true, matchedProbe: "test", errnoCode: 0) }
        )
        #expect(reloadedCoordinator.isEnabled(.whatsapp) == true)
        let thirdBatch = try await reloadedCoordinator.runIncrementalIngestion(sources: [.whatsapp], maxItemsPerSource: 10)
        #expect(thirdBatch.count == 1)
        #expect(thirdBatch.first?.body.contains("feedback tonight") == true)

        // Outgoing 1:1 message is also available as a writing-style sample
        let samples = await reloadedCoordinator.collectWritingSamples()
        #expect(samples.contains { $0.text.contains("feedback tonight") })
    }

    @Test func pluggedInAnalysisSchedulerSuspendsOnActivityOrBatteryAndResumesFromCheckpoint() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RelayPluggedIn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var simulatedNow = Date(timeIntervalSince1970: 1_763_000_000)
        var simulatedPower = AnalysisPowerState.Snapshot(
            onACPower: true,
            batteryPercent: 85,
            lowPowerMode: false,
            thermalState: .nominal
        )
        var simulatedIdle: TimeInterval = 10 // Not yet idle (< 270s)
        var sleepAssertionsHeld = 0

        let scheduler = PluggedInAnalysisScheduler(
            persistenceURL: tempDir.appendingPathComponent("plugged-in.json"),
            automaticPolling: false,
            now: { simulatedNow },
            powerProvider: { simulatedPower },
            idleSecondsProvider: { simulatedIdle },
            acquireSleepActivity: { _ in
                sleepAssertionsHeld += 1
                return { sleepAssertionsHeld -= 1 }
            }
        )
        scheduler.setEnabled(true)

        var cycleEntered: CheckedContinuation<Void, Never>?
        var runInvocations = 0

        scheduler.runCycle = {
            runInvocations += 1
            cycleEntered?.resume()
            cycleEntered = nil
            try await Task.sleep(for: .seconds(30))
            return .init(itemsIngested: 4, vaultNotesUpdated: 2, proactiveCardsPrepared: 1)
        }

        // Below 270s idle: does NOT start and holds zero sleep assertions
        scheduler.evaluateTick()
        #expect(scheduler.isRunningCycle == false)
        #expect(sleepAssertionsHeld == 0)

        // Idle >= 270s on AC power: starts cycle
        simulatedIdle = 300
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cycleEntered = cont
            scheduler.evaluateTick()
        }
        #expect(scheduler.isRunningCycle == true)
        #expect(sleepAssertionsHeld == 1)

        // User moves mouse/types (idle drops to 0s): suspends immediately and marks awaitingIdleContinuation = true
        simulatedIdle = 0
        scheduler.evaluateTick()
        while scheduler.isRunningCycle {
            await Task.yield()
        }
        #expect(scheduler.awaitingIdleContinuation == true)
        #expect(scheduler.recentRuns.first?.outcome == .pausedForActivity)
        #expect(sleepAssertionsHeld == 0)

        // Unplugged on battery even when idle >= 270s: stays paused
        simulatedIdle = 320
        simulatedPower = .init(onACPower: false, batteryPercent: 80, lowPowerMode: false, thermalState: .nominal)
        scheduler.evaluateTick()
        #expect(scheduler.isRunningCycle == false)

        // Plugged back in + idle >= 270s: resumes immediately without waiting 4 hours!
        simulatedPower = .init(onACPower: true, batteryPercent: 82, lowPowerMode: false, thermalState: .nominal)
        scheduler.runCycle = {
            runInvocations += 1
            return .init(itemsIngested: 3, vaultNotesUpdated: 1, proactiveCardsPrepared: 1)
        }
        scheduler.evaluateTick()
        while scheduler.isRunningCycle {
            await Task.yield()
        }
        #expect(runInvocations == 2)
        #expect(scheduler.awaitingIdleContinuation == false)
        #expect(scheduler.recentRuns.first?.outcome == .completed)
        #expect(scheduler.recentRuns.first?.summary.itemsIngested == 3)

        // Within 4-hour interval after completion: does not re-run prematurely
        simulatedNow = simulatedNow.addingTimeInterval(600)
        scheduler.evaluateTick()
        #expect(runInvocations == 2)
    }

    @Test func oauthPKCECallbackValidationAndAccountGenerationFencing() async throws {
        // 1. S256 PKCE RFC 7636 test vector verification
        let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(OAuthPKCE.s256Challenge(for: rfcVerifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

        // 2. Callback state, duplicate-param pollution, and RFC 9207 issuer mix-up validation
        let goodURL = URL(string: "http://127.0.0.1:51234/oauth/notion?code=auth_code_99&state=state_xyz&iss=https%3A%2F%2Fauth.notion.so")!
        let callbackResult = try OAuthLoopbackCallback.validateCallbackURL(
            goodURL,
            expectedPath: "/oauth/notion",
            expectedState: "state_xyz",
            expectedIssuer: "https://auth.notion.so",
            requireIssuer: true
        )
        #expect(callbackResult.code == "auth_code_99")
        #expect(callbackResult.issuer == "https://auth.notion.so")

        let wrongStateURL = URL(string: "http://127.0.0.1:51234/oauth/notion?code=auth_code_99&state=tampered")!
        #expect(throws: OAuthMCPError.stateMismatch) {
            _ = try OAuthLoopbackCallback.validateCallbackURL(
                wrongStateURL,
                expectedPath: "/oauth/notion",
                expectedState: "state_xyz",
                expectedIssuer: nil,
                requireIssuer: false
            )
        }

        let wrongIssuerURL = URL(string: "http://127.0.0.1:51234/oauth/notion?code=auth_code_99&state=state_xyz&iss=https%3A%2F%2Fevil.example")!
        #expect(throws: OAuthMCPError.issuerMismatch) {
            _ = try OAuthLoopbackCallback.validateCallbackURL(
                wrongIssuerURL,
                expectedPath: "/oauth/notion",
                expectedState: "state_xyz",
                expectedIssuer: "https://auth.notion.so",
                requireIssuer: true
            )
        }

        let pollutedURL = URL(string: "http://127.0.0.1:51234/oauth/notion?code=one&code=two&state=state_xyz")!
        #expect(throws: OAuthMCPError.self) {
            _ = try OAuthLoopbackCallback.validateCallbackURL(
                pollutedURL,
                expectedPath: "/oauth/notion",
                expectedState: "state_xyz",
                expectedIssuer: nil,
                requireIssuer: false
            )
        }

        // 3. Account generation fencing + token refresh rotation
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RelayOAuthGen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let grantStore = InMemoryOAuthGrantStore()
        let now = Date(timeIntervalSince1970: 1_763_000_000)
        let manager = OAuthMCPConnectorManager(
            directoryURL: tempDir,
            grantStore: grantStore,
            httpTransport: { request in
                #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
                let payload = Data(#"{"access_token":"rotated_token_2","refresh_token":"refresh_2","expires_in":3600}"#.utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (payload, response)
            },
            openBrowserURL: { _ in false }
        )

        var invalidatedGenerations: [(String, UUID)] = []
        manager.onGenerationInvalidated = { id, gen in invalidatedGenerations.append((id, gen)) }

        let initialGrant = OAuthGrant(
            accessToken: "expired_token_1",
            refreshToken: "refresh_1",
            tokenType: "Bearer",
            expiresAt: now.addingTimeInterval(10), // Expiring within 60s leeway -> triggers refresh
            clientID: "client_123",
            isDynamicallyRegisteredClient: false,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            revocationEndpoint: nil,
            issuer: "https://accounts.google.com",
            resource: nil,
            scope: "openid email"
        )
        let conn1 = try manager.finalizeGrant(
            grant: initialGrant,
            connectionID: "gmail-work",
            provider: .gmail,
            endpoint: OAuthMCPProvider.gmail.defaultEndpoint!,
            accountLabel: "work@example.com",
            now: now
        )

        // Refresh rotates token while preserving active generation
        let refreshed = try await manager.validBearerToken(connectionID: "gmail-work", expectedGeneration: conn1.generation, now: now)
        #expect(refreshed.accessToken == "rotated_token_2")
        #expect(refreshed.generation == conn1.generation)

        // Relinking the same connectionID mints a new generation and fences out stale generation reads
        let conn2 = try manager.finalizeGrant(
            grant: initialGrant,
            connectionID: "gmail-work",
            provider: .gmail,
            endpoint: OAuthMCPProvider.gmail.defaultEndpoint!,
            accountLabel: "personal@example.com",
            now: now
        )
        #expect(conn2.generation != conn1.generation)
        #expect(invalidatedGenerations.contains { $0.0 == "gmail-work" && $0.1 == conn1.generation })
        #expect(throws: OAuthMCPError.connectionChanged) {
            try manager.verifyGeneration(id: "gmail-work", expected: conn1.generation)
        }
    }

    // MARK: - Domain 2: Release Multi-Provider Computer Use, NativeCGComputerUseDriver & Browser/Control Parity

    @Test func nativeTaskControlDependenciesSupportAllProvidersAndDefaultEnabledUnlessOptedOut() throws {
        let suiteName = "com.relay.tests.control.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let allIdentities: [LocalInferenceIdentity] = [
            .embedded(path: "/inert/model.litertlm", compute: "gpu"),
            .lmStudio(host: .ipv4, port: 1234, model: "qwen2.5-vl"),
            .openRouter(model: "anthropic/claude-sonnet-4", credentialRevision: UUID()),
            .customResponses(canonicalOrigin: "https://api.example.com", model: "gpt-4.1", reasoningEffort: "medium", requiresAPIKey: true, credentialRevision: UUID()),
            .claudeCLI(model: "sonnet", effort: "medium", allowUnverified: false),
            .codexCLI(model: "gpt-6.1-terra", effort: "low", allowUnverified: false)
        ]

        // Default unset preference -> enabled = true across all 6 backends when Accessibility is trusted
        #expect(NativeTaskControlDependencies.isPreferenceEnabled(defaults: defaults) == true)
        for identity in allIdentities {
            let taskID = UUID()
            let run = try AssistantConversationHistory.Run(logicalTaskID: taskID, cause: .newRequest)
            let readAuthority = NativeLocalTaskReadAuthority.localUserInvocation(taskID: taskID, taskIsCurrent: { true })
            let scope = try NativeVisualTaskScope(
                logicalTaskID: taskID,
                runRevision: 1,
                run: run,
                originalObjective: "Inspect window state safely.",
                inferenceIdentity: identity,
                readAuthority: readAuthority,
                validateAcknowledgedStoreRun: {}
            )
            let inputAuthority = try NativeLocalTaskInputAuthority.localUserInvocation(
                scope: scope,
                windowRequirement: .appScoped,
                validateAcknowledgedInputGrant: {}
            )

            let liveDeps = try NativeTaskControlDependencies.appControl(
                scope: scope,
                inputAuthority: inputAuthority,
                defaults: defaults,
                isAccessibilityTrusted: { true }
            )
            #expect(liveDeps.factory.missingDependencies.isEmpty, "Expected live computer-use factory for \(identity)")

            let untrustedDeps = try NativeTaskControlDependencies.appControl(
                scope: scope,
                inputAuthority: inputAuthority,
                defaults: defaults,
                isAccessibilityTrusted: { false }
            )
            #expect(!untrustedDeps.factory.missingDependencies.isEmpty)
        }

        // Explicit user opt-out (false) disables computer use even when Accessibility is trusted
        defaults.set(false, forKey: NativeTaskControlDependencies.enabledPreference)
        #expect(NativeTaskControlDependencies.isPreferenceEnabled(defaults: defaults) == false)
        let optOutTaskID = UUID()
        let optOutRun = try AssistantConversationHistory.Run(logicalTaskID: optOutTaskID, cause: .newRequest)
        let optOutScope = try NativeVisualTaskScope(
            logicalTaskID: optOutTaskID,
            runRevision: 1,
            run: optOutRun,
            originalObjective: "Check opt-out.",
            inferenceIdentity: .claudeCLI(model: "sonnet", effort: "medium", allowUnverified: false),
            readAuthority: .localUserInvocation(taskID: optOutTaskID, taskIsCurrent: { true }),
            validateAcknowledgedStoreRun: {}
        )
        let optOutInput = try NativeLocalTaskInputAuthority.localUserInvocation(
            scope: optOutScope,
            windowRequirement: .appScoped,
            validateAcknowledgedInputGrant: {}
        )
        let optOutDeps = try NativeTaskControlDependencies.appControl(
            scope: optOutScope,
            inputAuthority: optOutInput,
            defaults: defaults,
            isAccessibilityTrusted: { true }
        )
        #expect(!optOutDeps.factory.missingDependencies.isEmpty)
    }

    @Test func nativeCGComputerUseDriverSynthesizesPointerKeyboardUnicodeAndRefusesSecureOrProtectedTargets() async throws {
        // Surrogate-pair-safe UTF-16 chunking test (emoji + Arabic + CJK never split across 20-code-unit boundaries)
        let sampleUnicode = String(repeating: "A", count: 19) + "🚀مرحبا日本語🎉"
        let chunks = NativeCGComputerUseDriver.chunkUTF16PreservingSurrogatePairs(sampleUnicode, maxCodeUnitsPerChunk: 20)
        #expect(chunks.count >= 2)
        for chunk in chunks {
            #expect(chunk.count <= 20)
            if let last = chunk.last {
                #expect(!UTF16.isLeadSurrogate(last), "Chunk must never end on an unpaired high surrogate")
            }
            if let first = chunk.first {
                #expect(!UTF16.isTrailSurrogate(first), "Chunk must never start on an unpaired low surrogate")
            }
        }
        let reconstructed = String(decoding: chunks.flatMap { $0 }, as: UTF16.self)
        #expect(reconstructed == sampleUnicode)

        // End-to-end built-in driver client test with deterministic Backend seam
        final class RecordedDriverBox: @unchecked Sendable {
            let lock = NSLock()
            var bundleID = "com.apple.TextEdit"
            var secureFocused = false
            var events: [NativeCGComputerUseDriver.SynthesizedEvent] = []

            func snapshot() -> NativeCGComputerUseDriver.ObservedWindowState {
                lock.lock()
                defer { lock.unlock() }
                return NativeCGComputerUseDriver.ObservedWindowState(
                    pid: 4242,
                    bundleID: bundleID,
                    bundlePath: "/System/Applications/TextEdit.app",
                    appName: "TextEdit",
                    windowTitle: "Untitled.txt",
                    windowBounds: CGRect(x: 100, y: 200, width: 800, height: 600),
                    isSecureFieldFocused: secureFocused,
                    elements: [
                        .init(index: 1, depth: 1, role: "AXTextArea", subrole: "", title: "Document", valuePreview: "", enabled: true, focused: true, frame: CGRect(x: 120, y: 240, width: 760, height: 520))
                    ],
                    pngData: nil,
                    imageWidth: 800,
                    imageHeight: 600
                )
            }

            func append(_ event: NativeCGComputerUseDriver.SynthesizedEvent) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }
        }

        let box = RecordedDriverBox()
        let backend = NativeCGComputerUseDriver.Backend(
            inspectAppState: { _ in box.snapshot() },
            prepareInputTarget: { _ in box.snapshot() },
            postEvent: { event in box.append(event) }
        )

        let client = try await OwnedNativeComputerUseClient.openBuiltIn(backend: backend)
        defer { Task { await client.close() } }

        let state = try await client.state(requestID: "req-state-1", app: "com.apple.TextEdit")
        #expect(state.isError == false)
        #expect(state.content.count >= 2)

        func admitMutation(_ id: String, _ command: OwnedNativeComputerUseClient.Command) async throws -> OwnedNativeComputerUseClient.NativeResult {
            let revocation = NativeInputRevocation()
            return try await client.mutate(
                requestID: id,
                app: "com.apple.TextEdit",
                command: command,
                revocation: revocation,
                preflight: { reserved in
                    .init(notAfter: reserved.notAfter, revocation: revocation)
                }
            )
        }

        _ = try await admitMutation("req-click", .clickOption(.init(x: 50, y: 60), button: .right, count: 2))
        _ = try await admitMutation("req-drag", .drag(from: .init(x: 20, y: 30), to: .init(x: 120, y: 130)))
        _ = try await admitMutation("req-scroll", .scroll(.init(x: 100, y: 100), deltaX: 0, deltaY: -24))
        _ = try await admitMutation("req-shortcut", .shortcut("cmd+k"))
        _ = try await admitMutation("req-unicode", .typeUnsentText("Hello 🚀 مرحبا 日本語"))

        #expect(box.events.count == 5)
        if case .click(_, let button, let count) = box.events[0].kind {
            #expect(button == .right && count == 2)
        } else {
            Issue.record("Expected right double-click event")
        }
        if case .drag = box.events[1].kind {} else { Issue.record("Expected drag event") }
        if case .scroll = box.events[2].kind {} else { Issue.record("Expected scroll event") }
        if case .key = box.events[3].kind {} else { Issue.record("Expected shortcut key event") }
        if case .unicodeChunks(let sentChunks) = box.events[4].kind {
            #expect(String(decoding: sentChunks.flatMap { $0 }, as: UTF16.self) == "Hello 🚀 مرحبا 日本語")
        } else {
            Issue.record("Expected unicodeChunks event")
        }

        // Secure password field focus MUST refuse input before posting any CGEvent
        box.secureFocused = true
        let countBeforeSecure = box.events.count
        await #expect(throws: (any Error).self) {
            _ = try await admitMutation("req-secure-refuse", .typeUnsentText("hunter2"))
        }
        #expect(box.events.count == countBeforeSecure)

        // Protected security bundle ID MUST refuse input before posting any CGEvent
        box.secureFocused = false
        box.bundleID = "com.apple.systemsettings"
        await #expect(throws: (any Error).self) {
            _ = try await admitMutation("req-protected-refuse", .click(.init(x: 40, y: 40)))
        }
        #expect(box.events.count == countBeforeSecure)
    }

    @Test func browserAutomationAndMacToolsSupportModernBrowsersWhileBlockingSecurityTargets() throws {
        #expect(try BrowserAutomation.validatedBrowser("Google Chrome") == .chrome)
        #expect(try BrowserAutomation.validatedBrowser("Safari") == .safari)
        #expect(try BrowserAutomation.validatedBrowser("Arc") == .arc)
        #expect(try BrowserAutomation.validatedBrowser("Brave Browser") == .brave)
        #expect(try BrowserAutomation.validatedBrowser("Microsoft Edge") == .edge)
        #expect(try BrowserAutomation.validatedBrowser("Dia") == .dia)
        #expect(BrowserAutomation.isSupportedBrowserBundleID("company.thebrowser.Browser") == true)
        #expect(BrowserAutomation.isSupportedBrowserBundleID("com.brave.Browser") == true)
        #expect(BrowserAutomation.isSupportedBrowserBundleID("com.microsoft.edgemac") == true)
        #expect(BrowserAutomation.isSupportedBrowserBundleID("company.thebrowser.dia") == true)
        #expect(throws: RelayError.self) {
            _ = try BrowserAutomation.validatedBrowser("Netscape Navigator")
        }

        // Security/password/TCC controls remain hard-prohibited while ordinary reviewed form/tab/menu controls are allowed
        #expect(MacTools.isHardProhibitedControl(bundleID: "com.apple.systempreferences", label: "General") == true)
        #expect(MacTools.isHardProhibitedControl(bundleID: "com.apple.Safari", label: "Change Password") == true)
        #expect(MacTools.isHardProhibitedControl(bundleID: "com.apple.Safari", label: "Full Disk Access") == true)
        #expect(MacTools.isHardProhibitedControl(bundleID: "com.apple.Safari", label: "Save Draft") == false)
        #expect(MacTools.isHardProhibitedControl(bundleID: "com.apple.Notes", label: "Format") == false)
    }
}
