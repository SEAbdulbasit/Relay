import Darwin
import Foundation
import SQLite3
import Testing
@testable import Relay

@MainActor @Suite(.serialized) struct Wave2FunctionalityTests {

    // MARK: - 1. Codex CLI & Claude CLI Runtime Hardening

    @Test func codexArgumentsOmitDeprecatedDaemonAutoStartAndOmitColorOnResume() {
        let workspace = URL(fileURLWithPath: "/private/tmp/relay-wave2-codex", isDirectory: true)
        let schema = workspace.appendingPathComponent("schema.json")

        let freshArgs = CodexCLIClient.planningArguments(
            workspace: workspace,
            schema: schema,
            reasoningEffort: .low,
            model: CodexCLIClient.defaultPlanningModel,
            imagePaths: [],
            resumeThreadID: nil
        )
        #expect(!freshArgs.contains("daemon_auto_start"))
        #expect(freshArgs.contains("--color"))
        #expect(freshArgs.contains("never"))
        #expect(freshArgs.contains("--ephemeral"))

        let persistentTurn1Args = CodexCLIClient.planningArguments(
            workspace: workspace,
            schema: schema,
            reasoningEffort: .low,
            model: CodexCLIClient.defaultPlanningModel,
            imagePaths: [],
            resumeThreadID: nil,
            persistSession: true
        )
        #expect(!persistentTurn1Args.contains("--ephemeral"))
        #expect(persistentTurn1Args.contains("history.persistence=\"save-all\""))

        let resumeArgs = CodexCLIClient.planningArguments(
            workspace: workspace,
            schema: schema,
            reasoningEffort: .medium,
            model: CodexCLIClient.defaultPlanningModel,
            imagePaths: [],
            resumeThreadID: "thread_wave2_resume_01"
        )
        #expect(!resumeArgs.contains("daemon_auto_start"))
        #expect(!resumeArgs.contains("--color"))
        #expect(resumeArgs.contains("resume"))
        #expect(resumeArgs.contains("thread_wave2_resume_01"))
    }

    @Test func codexEventParserAllowsBenignErrorItemsRejectsToolItemsAndCatalogFallsBack() throws {
        // 1. Benign deprecation/warning item with kind == "error" followed by valid agent_message succeeds
        let warningThenMessage = Data("""
        {"type":"thread.started","thread_id":"thr_warn_ok"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"error","message":"`daemon_auto_start` is deprecated"}}
        {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{\\"content\\":\\"Ready on turn 1.\\",\\"tool_name\\":\\"\\",\\"arguments_json\\":\\"{}\\"}"}}
        {"type":"turn.completed"}
        """.utf8)
        let parsed = try CodexCLIClient.parseEventsWithMetadata(warningThenMessage, tools: [])
        #expect(parsed.threadID == "thr_warn_ok")
        #expect(parsed.reply.content == "Ready on turn 1.")
        #expect(parsed.reply.toolCalls.isEmpty)

        // 2. Error item with NO agent_message before turn.completed fails cleanly (never .unexpectedTool)
        let errorWithoutAnswer = Data("""
        {"type":"thread.started","thread_id":"thr_err_only"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Authentication expired"}}
        {"type":"turn.completed"}
        """.utf8)
        #expect(throws: CodexCLIError.self) {
            _ = try CodexCLIClient.parseEventsWithMetadata(errorWithoutAnswer, tools: [])
        }
        do {
            _ = try CodexCLIClient.parseEventsWithMetadata(errorWithoutAnswer, tools: [])
            Issue.record("Expected error when turn finishes with error item and no agent_message")
        } catch let err as CodexCLIError {
            #expect(err != .unexpectedTool)
        }

        // 3. Unauthorized native Codex tool item still throws .unexpectedTool
        let unexpectedToolStream = Data("""
        {"type":"thread.started","thread_id":"thr_bad_tool"}
        {"type":"item.started","item":{"id":"item_9","type":"command_execution"}}
        """.utf8)
        #expect(throws: CodexCLIError.unexpectedTool) {
            _ = try CodexCLIClient.parseEventsWithMetadata(unexpectedToolStream, tools: [])
        }

        // 4. Bundled model catalog falls back to objects.first when future Codex releases rename slugs
        let futureBundledCatalog = Data("""
        {
          "models": [
            {
              "slug": "gpt-7.0-future-default",
              "display_name": "GPT Future",
              "shell_type": "shell_command",
              "tool_mode": "direct",
              "supported_in_api": true
            }
          ]
        }
        """.utf8)
        let adaptedData = try CodexCLIClient.planningCatalog(futureBundledCatalog, modelSlug: "gpt-6.1-terra")
        let adaptedJSON = try #require(try JSONSerialization.jsonObject(with: adaptedData) as? [String: Any])
        let models = try #require(adaptedJSON["models"] as? [[String: Any]])
        #expect(models.count == 1)
        #expect(models.first?["slug"] as? String == "gpt-6.1-terra")
        #expect(models.first?["shell_type"] as? String == "disabled")
        #expect(models.first?["tool_mode"] as? String == "direct")
    }

    @Test func claudeCLIClientTracksAuthTokenRejectionStateCleanly() {
        ClaudeCLIClient.resetPreferences()
        let client = ClaudeCLIClient()
        #expect(client.authTokenRejected == false)
        ClaudeCLIClient.resetPreferences()
    }

    // MARK: - 2. YouTube iOS 20.10.4 Innertube + Track Retry & Watch HTML Fallback

    @Test func youTubeTranscriptFetcherUsesIOSInnertubeWithXMLRetryAndWatchHTMLFallback() async throws {
        // Case A: iOS 20.10.4 Innertube succeeds; fmt=json3 returns 0 bytes (PoToken/format empty) -> retries raw XML track URL
        final class InnertubeProbeBox: @unchecked Sendable {
            var sawIOSPlayerPost = false
            var sawIOSUserAgent = false
            var trackRequests: [URL] = []
        }
        let box = InnertubeProbeBox()

        let innertubeResponse = """
        {
          "videoDetails": {
            "videoId": "jNQXAC9IVRw",
            "title": "Me at the zoo"
          },
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=jNQXAC9IVRw&lang=en&caps=asr",
                  "languageCode": "en",
                  "kind": "asr"
                }
              ]
            }
          }
        }
        """
        let xmlTrack = """
        <?xml version="1.0" encoding="utf-8" ?><transcript>
          <text start="1.2" dur="3.1">All right, so here we are in front of the elephants.</text>
          <text start="4.8" dur="4.0">The cool thing about these guys is that they have really long trunks.</text>
        </transcript>
        """

        let transcriptA = try await YouTubeTranscriptFetcher.fetchTranscript(
            for: "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        ) { request in
            let url = try #require(request.url)
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            if url.path.contains("/youtubei/v1/player") {
                box.sawIOSPlayerPost = (request.httpMethod == "POST")
                let ua = request.value(forHTTPHeaderField: "User-Agent") ?? ""
                box.sawIOSUserAgent = ua.contains("com.google.ios.youtube/20.10.4")
                return (Data(innertubeResponse.utf8), ok)
            }
            if url.path.contains("/api/timedtext") {
                box.trackRequests.append(url)
                if url.query?.contains("fmt=json3") == true {
                    // Simulate empty 0-byte response on fmt=json3 so fetcher retries raw XML URL
                    return (Data(), ok)
                }
                return (Data(xmlTrack.utf8), ok)
            }
            let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(), notFound)
        }

        let resolvedA = try #require(transcriptA)
        #expect(box.sawIOSPlayerPost == true)
        #expect(box.sawIOSUserAgent == true)
        #expect(box.trackRequests.count >= 2)
        #expect(resolvedA.videoID == "jNQXAC9IVRw")
        #expect(resolvedA.title == "Me at the zoo")
        #expect(resolvedA.isAutoGenerated == true)
        #expect(resolvedA.segmentCount == 2)
        #expect(resolvedA.text.contains("in front of the elephants"))

        // Case B: Innertube fails with HTTP 503 -> falls back cleanly to watch-page HTML extraction
        let watchHTML = """
        <!doctype html><html><body><script>
        var ytInitialPlayerResponse = {
          "videoDetails": { "videoId": "dQw4w9WgXcQ", "title": "Fallback Watch HTML Video" },
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en",
                  "languageCode": "en",
                  "kind": "standard"
                }
              ]
            }
          }
        };
        </script></body></html>
        """
        let json3Body = #"{"events":[{"tStartMs":2000,"segs":[{"utf8":"Fallback watch HTML caption succeeded."}]}]}"#

        let transcriptB = try await YouTubeTranscriptFetcher.fetchTranscript(
            for: "https://youtu.be/dQw4w9WgXcQ"
        ) { request in
            let url = try #require(request.url)
            if url.path.contains("/youtubei/v1/player") {
                let unavailable = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(), unavailable)
            }
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            if url.path == "/watch" {
                return (Data(watchHTML.utf8), ok)
            }
            return (Data(json3Body.utf8), ok)
        }

        let resolvedB = try #require(transcriptB)
        #expect(resolvedB.title == "Fallback Watch HTML Video")
        #expect(resolvedB.text.contains("Fallback watch HTML caption succeeded."))
    }

    // MARK: - 3. OAuth Provider Capabilities, Read-Only Scope Filtering, Client Secret & Remote MCP Cloud Window

    @Test func oauthProviderCapabilitiesReadOnlyScopesClientSecretAndCloudIngestion() async throws {
        // 1. Provider registration & client secret metadata
        #expect(OAuthMCPProvider.notion.supportsDynamicRegistration == true)
        #expect(OAuthMCPProvider.granola.supportsDynamicRegistration == true)
        #expect(OAuthMCPProvider.custom.supportsDynamicRegistration == true)
        #expect(OAuthMCPProvider.slack.supportsDynamicRegistration == false)
        #expect(OAuthMCPProvider.gmail.supportsDynamicRegistration == false)
        #expect(OAuthMCPProvider.googleCalendar.supportsDynamicRegistration == false)
        #expect(OAuthMCPProvider.outlook.supportsDynamicRegistration == false)

        #expect(OAuthMCPProvider.slack.requiresClientSecret == true)
        #expect(OAuthMCPProvider.slack.supportsClientSecret == true)
        #expect(OAuthMCPProvider.gmail.supportsClientSecret == true)
        #expect(OAuthMCPProvider.googleCalendar.supportsClientSecret == true)
        #expect(OAuthMCPProvider.notion.requiresClientSecret == false)
        #expect(OAuthMCPProvider.outlook.requiresClientSecret == false)

        // 2. Slack PRM scope intersection strips write scopes (e.g. chat:write) and preserves read-only defaults
        let slackEndpoint = URL(string: "https://mcp.slack.com/mcp")!
        let discoveredSlack = try await OAuthMetadataDiscovery.discover(
            endpoint: slackEndpoint,
            provider: .slack
        ) { req in
            let url = req.url!
            if url.path == "/mcp" {
                let resp = HTTPURLResponse(
                    url: url,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.slack.com/.well-known/oauth-protected-resource""#]
                )!
                return (Data(), resp)
            }
            if url.path.contains("oauth-protected-resource") {
                let prm = Data("""
                {
                  "resource": "https://mcp.slack.com/mcp",
                  "authorization_servers": ["https://slack.com"],
                  "scopes_supported": ["channels:history", "users:read", "chat:write", "channels:write", "files:write"]
                }
                """.utf8)
                return (prm, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let asMeta = Data("""
            {
              "issuer": "https://slack.com",
              "authorization_endpoint": "https://slack.com/oauth/v2_user/authorize",
              "token_endpoint": "https://slack.com/api/oauth.v2.user.access",
              "code_challenge_methods_supported": ["S256"]
            }
            """.utf8)
            return (asMeta, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(discoveredSlack.scopes.contains("channels:history"))
        #expect(discoveredSlack.scopes.contains("users:read"))
        #expect(!discoveredSlack.scopes.contains("chat:write"))
        #expect(!discoveredSlack.scopes.contains("channels:write"))
        #expect(!discoveredSlack.scopes.contains("files:write"))

        // 3. Client secret preserved across refreshGrant and sent via client_secret_post, never saved to disk JSON
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayWave2OAuth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        final class CapturedBodies: @unchecked Sendable {
            var refreshFormBody = ""
            var calledMCPTools: [String] = []
            var outlookPaths: [String] = []
        }
        let captured = CapturedBodies()
        let now = Date(timeIntervalSince1970: 1_765_000_000)

        let grantStore = InMemoryOAuthGrantStore()
        let manager = OAuthMCPConnectorManager(
            directoryURL: tempDir,
            grantStore: grantStore,
            httpTransport: { request in
                let url = request.url!
                if url.host == "slack.com", url.path.contains("oauth") {
                    captured.refreshFormBody = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                    let tokenJSON = Data(#"{"access_token":"xoxp_refreshed","refresh_token":"xoxe_rot","expires_in":3600}"#.utf8)
                    return (tokenJSON, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                if url.host == "mcp.notion.com" {
                    let bodyObj = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                    let method = bodyObj?["method"] as? String ?? ""
                    if method == "tools/list" {
                        let listReply = Data("""
                        {
                          "jsonrpc": "2.0",
                          "id": 1,
                          "result": {
                            "tools": [
                              {
                                "name": "notion-search",
                                "description": "Search workspace pages",
                                "inputSchema": { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] }
                              },
                              {
                                "name": "notion-create-page",
                                "description": "Mutating write tool that must never be called",
                                "inputSchema": { "type": "object", "properties": {} }
                              }
                            ]
                          }
                        }
                        """.utf8)
                        return (listReply, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    }
                    if method == "tools/call" {
                        let params = bodyObj?["params"] as? [String: Any]
                        let toolName = params?["name"] as? String ?? ""
                        captured.calledMCPTools.append(toolName)
                        let callReply = Data("""
                        {
                          "jsonrpc": "2.0",
                          "id": 2,
                          "result": {
                            "content": [
                              { "type": "text", "text": "Q4 Architecture Roadmap — Notion page updated with rollout milestones." }
                            ]
                          }
                        }
                        """.utf8)
                        return (callReply, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    }
                }
                if url.host == "graph.microsoft.com" {
                    captured.outlookPaths.append(url.path)
                    if url.path.contains("calendarView") {
                        let calJSON = Data("""
                        {
                          "value": [
                            {
                              "id": "cal-ev-1",
                              "subject": "Quarterly Planning Sync",
                              "bodyPreview": "Review OKRs with engineering leads.",
                              "start": { "dateTime": "2025-12-06T17:00:00Z" },
                              "location": { "displayName": "Boardroom A" },
                              "isCancelled": false
                            }
                          ]
                        }
                        """.utf8)
                        return (calJSON, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    }
                    let mailJSON = Data("""
                    {
                      "value": [
                        {
                          "id": "mail-msg-1",
                          "subject": "Design Signoff",
                          "bodyPreview": "Approved the updated notch interaction spec.",
                          "receivedDateTime": "2025-12-06T12:00:00Z",
                          "from": { "emailAddress": { "address": "lead@example.com" } },
                          "isDraft": false,
                          "inferenceClassification": "focused"
                        }
                      ]
                    }
                    """.utf8)
                    return (mailJSON, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            openBrowserURL: { _ in false }
        )

        var slackGrant = OAuthGrant(
            accessToken: "xoxp_expiring",
            refreshToken: "xoxe_initial",
            tokenType: "Bearer",
            expiresAt: now.addingTimeInterval(15), // Expiring within leeway -> triggers refresh
            clientID: "slack_cid_1",
            isDynamicallyRegisteredClient: false,
            tokenEndpoint: URL(string: "https://slack.com/api/oauth.v2.user.access")!,
            revocationEndpoint: nil,
            issuer: "https://slack.com",
            resource: "https://mcp.slack.com/mcp",
            scope: "channels:history users:read"
        )
        slackGrant.clientSecret = "super_secret_slack_999"

        let slackConn = try manager.finalizeGrant(
            grant: slackGrant,
            connectionID: "slack-team",
            provider: .slack,
            endpoint: slackEndpoint,
            accountLabel: "Relay Team",
            now: now
        )
        let refreshedSlack = try await manager.validBearerToken(
            connectionID: "slack-team",
            expectedGeneration: slackConn.generation,
            now: now
        )
        #expect(refreshedSlack.accessToken == "xoxp_refreshed")
        #expect(captured.refreshFormBody.contains("client_secret=super_secret_slack_999"))
        #expect(try grantStore.load(connectionID: "slack-team")?.clientSecret == "super_secret_slack_999")

        let persistedDiskJSON = try String(
            contentsOf: tempDir.appendingPathComponent("oauth-mcp-connections.json"),
            encoding: .utf8
        )
        #expect(!persistedDiskJSON.contains("super_secret_slack_999"))

        // 4. Remote MCP JSON-RPC cloud window ingestion (Notion) invokes read-only tool and skips write tools
        let notionGrant = OAuthGrant(
            accessToken: "ntn_live_token",
            refreshToken: nil,
            tokenType: "Bearer",
            expiresAt: now.addingTimeInterval(7_200),
            clientID: "notion_dcr_client",
            isDynamicallyRegisteredClient: true,
            tokenEndpoint: URL(string: "https://mcp.notion.com/token")!,
            revocationEndpoint: nil,
            issuer: "https://mcp.notion.com",
            resource: "https://mcp.notion.com/mcp",
            scope: nil
        )
        _ = try manager.finalizeGrant(
            grant: notionGrant,
            connectionID: "notion-ws",
            provider: .notion,
            endpoint: OAuthMCPProvider.notion.defaultEndpoint!,
            accountLabel: "Personal Workspace",
            now: now
        )
        let notionItems = try await manager.fetchCuratedCloudWindow(connectionID: "notion-ws", maxItems: 10, now: now)
        #expect(!notionItems.isEmpty)
        #expect(notionItems.contains { $0.body.contains("Q4 Architecture Roadmap") || $0.title.contains("Q4 Architecture Roadmap") })
        #expect(captured.calledMCPTools == ["notion-search"])
        #expect(!captured.calledMCPTools.contains("notion-create-page"))

        // 5. Outlook fetches BOTH Focused Inbox messages AND Calendar agenda items
        let outlookGrant = OAuthGrant(
            accessToken: "ms_graph_token",
            refreshToken: nil,
            tokenType: "Bearer",
            expiresAt: now.addingTimeInterval(7_200),
            clientID: "ms_public_client",
            isDynamicallyRegisteredClient: false,
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            revocationEndpoint: nil,
            issuer: "https://login.microsoftonline.com/common/v2.0",
            resource: nil,
            scope: "Mail.Read Calendars.Read"
        )
        _ = try manager.finalizeGrant(
            grant: outlookGrant,
            connectionID: "outlook-work",
            provider: .outlook,
            endpoint: OAuthMCPProvider.outlook.defaultEndpoint!,
            accountLabel: "work@contoso.com",
            now: now
        )
        let outlookItems = try await manager.fetchCuratedCloudWindow(connectionID: "outlook-work", maxItems: 10, now: now)
        #expect(captured.outlookPaths.contains { $0.contains("messages") })
        #expect(captured.outlookPaths.contains { $0.contains("calendarView") })
        #expect(outlookItems.contains { $0.title.contains("Design Signoff") })
        #expect(outlookItems.contains { $0.title.contains("Quarterly Planning Sync") })
    }

    // MARK: - 4. Plugged-In Scheduler Manual Run & Checkpointed Live Sources WAL / Coalescing

    @Test func pluggedInSchedulerRunsManualCycleWhenToggleOffOrOnBatteryAndSurvivesReset() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayWave2Scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let simulatedNow = Date(timeIntervalSince1970: 1_765_100_000)
        var simulatedPower = AnalysisPowerState.Snapshot(
            onACPower: false, // On battery!
            batteryPercent: 72,
            lowPowerMode: false,
            thermalState: .nominal
        )

        let scheduler = PluggedInAnalysisScheduler(
            persistenceURL: tempDir.appendingPathComponent("scheduler.json"),
            automaticPolling: false,
            now: { simulatedNow },
            powerProvider: { simulatedPower },
            idleSecondsProvider: { 0 } // Active user (0s idle)
        )
        // Background toggle defaults to false!
        #expect(scheduler.enabled == false)

        var cycleStarted: CheckedContinuation<Void, Never>?
        var allowFinish: CheckedContinuation<Void, Never>?

        scheduler.runCycle = {
            cycleStarted?.resume()
            cycleStarted = nil
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                allowFinish = cont
            }
            return .init(itemsIngested: 5, vaultNotesUpdated: 2, proactiveCardsPrepared: 1)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cycleStarted = cont
            scheduler.runManualCycleNow()
        }
        #expect(scheduler.isRunningCycle == true)

        // Simulate 1s poll evaluateTick while enabled == false AND on battery AND idle == 0:
        // Manual cycle MUST NOT be killed!
        scheduler.evaluateTick()
        #expect(scheduler.isRunningCycle == true)

        allowFinish?.resume()
        allowFinish = nil
        while scheduler.isRunningCycle {
            await Task.yield()
        }
        #expect(scheduler.recentRuns.first?.outcome == .completed)
        #expect(scheduler.recentRuns.first?.summary.itemsIngested == 5)

        // Serious/critical thermal pressure STILL pauses a manual run started while cool.
        simulatedPower = .init(onACPower: true, batteryPercent: 90, lowPowerMode: false, thermalState: .nominal)
        var thermalStarted: CheckedContinuation<Void, Never>?
        scheduler.runCycle = {
            thermalStarted?.resume()
            thermalStarted = nil
            try await Task.sleep(for: .seconds(30))
            return .init()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            thermalStarted = cont
            scheduler.runManualCycleNow()
        }
        simulatedPower = .init(onACPower: true, batteryPercent: 90, lowPowerMode: false, thermalState: .critical)
        scheduler.evaluateTick()
        while scheduler.isRunningCycle {
            await Task.yield()
        }
        #expect(scheduler.recentRuns.first?.outcome == .pausedForThermal)

        await scheduler.drainAndReset()
        #expect(scheduler.recentRuns.isEmpty)
    }

    @Test func liveLocalSourcesCopiesWALSidecarsPersistsMidSyncBatchesAndCoalescesConcurrentCalls() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayWave2LiveSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let waURL = tempDir.appendingPathComponent("ChatStorage.sqlite")
        let baseApple = Date().timeIntervalSinceReferenceDate - 400_000

        // Keep an active SQLite WAL connection open with uncheckpointed WAL frames so only copying -wal/-shm sees the rows!
        var writerDB: OpaquePointer?
        #expect(sqlite3_open(waURL.path, &writerDB) == SQLITE_OK)
        defer { if writerDB != nil { sqlite3_close(writerDB) } }

        let bootstrapSQL = """
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZSESSIONTYPE INTEGER, ZMESSAGECOUNTER INTEGER, ZLASTMESSAGEDATE REAL);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGEDATE REAL, ZTEXT TEXT, ZSTANZAID TEXT, ZFROMJID TEXT, ZGROUPMEMBER INTEGER, ZMESSAGETYPE INTEGER DEFAULT 0);
        """
        #expect(sqlite3_exec(writerDB, bootstrapSQL, nil, nil, nil) == SQLITE_OK)

        // Insert 30 distinct chat sessions/messages sitting in the uncheckpointed .sqlite-wal sidecar
        var insertSQL = "BEGIN TRANSACTION;\n"
        for idx in 1...30 {
            let ts = baseApple + Double(idx * 60)
            insertSQL += "INSERT INTO ZWACHATSESSION VALUES (\(idx), '155500000\(idx)@s.whatsapp.net', 'Contact \(idx)', 0, 1, \(ts));\n"
            insertSQL += "INSERT INTO ZWAMESSAGE VALUES (\(100 + idx), \(idx), 0, \(ts), 'WAL uncheckpointed message #\(idx)', 'stanza-\(idx)', '155500000\(idx)@s.whatsapp.net', NULL, 0);\n"
        }
        insertSQL += "COMMIT;"
        #expect(sqlite3_exec(writerDB, insertSQL, nil, nil, nil) == SQLITE_OK)
        #expect(FileManager.default.fileExists(atPath: waURL.path + "-wal") == true)

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

        // Coalesce check: two concurrent runIncrementalIngestion calls must both succeed without throwing .busy!
        async let firstCall = coordinator.runIncrementalIngestion(sources: [.whatsapp], maxItemsPerSource: 50)
        async let concurrentCall = coordinator.runIncrementalIngestion(sources: [.whatsapp], maxItemsPerSource: 50)
        let (batch1, batch2) = try await (firstCall, concurrentCall)
        #expect(batch1.count == 30)
        #expect(batch2.count == 30 || batch2.isEmpty)
        #expect(batch1.contains { $0.body.contains("WAL uncheckpointed message #30") })

        // Verify reload from disk retains all 30 items
        let reloaded = LiveLocalSourcesCoordinator(
            paths: paths,
            directoryURL: stateDir,
            fullDiskAccessProbe: { FullDiskAccessStatus(granted: true, matchedProbe: "test", errnoCode: 0) }
        )
        #expect(reloaded.items(for: .whatsapp).count == 30)
    }

    // MARK: - 5. Semantic Vault Provenance/Parse Strictness, Keepsake Eligibility & WritingStyle Editable Helpers

    @Test func semanticVaultBuilderDeduplicatesIDsDropsHallucinatedProvenanceAndRejectsNonJSON() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayWave2Vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vaultDir = tempRoot.appendingPathComponent("KnowledgeVault", isDirectory: true)
        let resumeURL = tempRoot.appendingPathComponent("vault-resume.json", isDirectory: false)
        let builder = SemanticVaultBuilder(vaultRoot: vaultDir, resumeStateURL: resumeURL)

        // Duplicate CorpusItem IDs (simulating overlapping local + cloud corpus slices) must NEVER crash
        let duplicateItems: [CorpusItem] = [
            CorpusItem(
                id: "dup-id-1",
                title: "Architecture Spec",
                text: "Relay 3.1 uses strict provenance validation.",
                itemDate: Date(timeIntervalSince1970: 1_765_000_000),
                sourceID: "apple-notes",
                kind: SourceAttributionRole.userAuthored.rawValue
            ),
            CorpusItem(
                id: "dup-id-1",
                title: "Architecture Spec Mirror",
                text: "Relay 3.1 uses strict provenance validation.",
                itemDate: Date(timeIntervalSince1970: 1_765_000_000),
                sourceID: "notion",
                kind: SourceAttributionRole.userAuthored.rawValue
            )
        ]

        let report = try await builder.buildOrUpdate(items: duplicateItems, allowResume: false) { _ in
            let json = """
            {
              "overview_summary": "Focused on Relay 3.1 architecture.",
              "active_priorities": ["Enforce grounded note provenance"],
              "notes": [
                {
                  "domain": "Projects",
                  "title": "Grounded Architecture",
                  "summary": "Backed by a real corpus source ID.",
                  "facts": ["Uses strict provenance."],
                  "source_ids": ["dup-id-1"],
                  "attribution": "user"
                },
                {
                  "domain": "Projects",
                  "title": "Hallucinated Ghost Note",
                  "summary": "Claims a nonexistent source ID and must be dropped.",
                  "facts": ["Should never be attributed to allowedItems.first."],
                  "source_ids": ["nonexistent-source-999"],
                  "attribution": "user"
                }
              ]
            }
            """
            return ModelReply(content: json, toolCalls: [])
        }
        #expect(report.completedSlices == 1)
        #expect(FileManager.default.fileExists(atPath: vaultDir.appendingPathComponent("Projects/Grounded Architecture.md").path) == true)
        #expect(FileManager.default.fileExists(atPath: vaultDir.appendingPathComponent("Projects/Hallucinated Ghost Note.md").path) == false)

        // Non-JSON prose must retry once and throw a typed error instead of writing "Grounded note from source…" fallback junk
        var badJSONAttempts = 0
        await #expect(throws: (any Error).self) {
            _ = try await builder.buildOrUpdate(items: [duplicateItems[0]], allowResume: false) { _ in
                badJSONAttempts += 1
                return ModelReply(content: "Sorry, here is some unstructured conversational prose instead of JSON.", toolCalls: [])
            }
        }
        #expect(badJSONAttempts >= 2)
    }

    @Test func welcomeKeepsakeRejectsRefusalOrInvalidOutputWithoutBurningOneTimeEligibility() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayWave2Keepsake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vaultDir = tempRoot.appendingPathComponent("KnowledgeVault", isDirectory: true)
        let projectsDir = vaultDir.appendingPathComponent("Projects", isDirectory: true)
        let peopleDir = vaultDir.appendingPathComponent("People", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: peopleDir, withIntermediateDirectories: true)

        try Data("# Relay 3.1\nBuilding a privacy-first native macOS assistant with a local Semantic Knowledge Vault, checkpointed source sync, and Morning Brief cards that stay strictly under user review.\n".utf8)
            .write(to: projectsDir.appendingPathComponent("Relay 3.1.md"))
        try Data("# Alex Rivera\nDesign partner collaborating weekly on Notch Quick Actions, Magic Reply voice matching, and hardware-calibrated SPU tap interactions on MacBook Pro.\n".utf8)
            .write(to: peopleDir.appendingPathComponent("Alex Rivera.md"))

        let persistenceURL = tempRoot.appendingPathComponent("keepsake-state.json")
        let generator = WelcomeKeepsakeGenerator(vaultRoot: vaultDir, persistenceURL: persistenceURL)

        // 1. Model returns plain refusal prose -> must NOT save canned letter and must NOT burn eligibility!
        let refusalOutcome = try await generator.generateOnceIfEligible(recipientName: "Sam") { _ in
            ModelReply(content: "I'm sorry, I cannot assist with generating that letter right now.", toolCalls: [])
        }
        #expect(refusalOutcome == .insufficientEvidence)
        #expect(generator.keepsake == nil)

        // 2. Subsequent valid grounded JSON call still succeeds because eligibility was preserved!
        let validOutcome = try await generator.generateOnceIfEligible(recipientName: "Sam") { _ in
            let validJSON = """
            {
              "insufficient_evidence": false,
              "kicker": "From your Knowledge Vault",
              "title": "Craft & Collaboration",
              "body_markdown": "Across your notes on Relay 3.1 and your weekly design work with Alex Rivera, a clear focus on local-first macOS craft stands out."
            }
            """
            return ModelReply(content: validJSON, toolCalls: [])
        }
        if case .created(let keepsake) = validOutcome {
            #expect(keepsake.title == "Craft & Collaboration")
            #expect(keepsake.bodyMarkdown.contains("Alex Rivera"))
        } else {
            Issue.record("Expected .created keepsake after prior non-consuming refusal, got \(validOutcome)")
        }
    }

    @Test func writingStyleCollectorEditableSnapshotInstanceHelpersRoundTrip() throws {
        let tempVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayWave2Style-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempVault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempVault) }

        let collector = WritingStyleCollector(vaultRoot: tempVault)
        #expect(try collector.loadEditableSnapshot() == "")
        #expect(collector.hasSnapshot == false)

        let sample = "Hey Priya — sounds great, let's lock in 2pm tomorrow!"
        try collector.saveEditableSnapshot(sample)
        #expect(collector.hasSnapshot == true)
        #expect(try collector.loadEditableSnapshot() == sample)
    }

    // MARK: - 6. MorningBriefCorpusBridge Full 4-Tool Read-Only Gate

    @Test func morningBriefCorpusBridgeWiresAllFourReadOnlyResearchTools() async throws {
        let tempVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayWave2Bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempVault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempVault) }

        try Data("# Tokyo Trip\nConfirm Shinkansen tickets with Kenji.\n".utf8)
            .write(to: tempVault.appendingPathComponent("Plans_Tokyo.md"))
        try Data("Private style sample that searchVault must skip.\n".utf8)
            .write(to: tempVault.appendingPathComponent(WritingStyleCollector.fileName))

        let now = Date(timeIntervalSince1970: 1_765_200_000)
        let corpus = [
            CorpusItem(
                id: "imessage:msg-77",
                title: "Message from Kenji",
                text: "Did you book the morning Shinkansen to Kyoto yet?",
                itemDate: now.addingTimeInterval(-1_800),
                sourceID: "imessage",
                kind: SourceAttributionRole.directCorrespondence.rawValue
            )
        ]
        let calendar = [
            CalendarOccurrence(
                calendarID: "work",
                calendarName: "Work",
                itemID: "ev-tokyo-sync",
                title: "Kyoto Itinerary Check-in",
                start: now.addingTimeInterval(3_600),
                end: now.addingTimeInterval(5_400),
                allDay: false,
                timeZone: "America/Los_Angeles",
                location: "Zoom",
                notes: "Review hotel & rail bookings",
                scheduleStatus: "confirmed",
                availability: "busy",
                participantResponse: "accepted"
            )
        ]
        let cloudItems = [
            CloudIngestedItem(
                id: "ntn-page-1",
                connectionID: "notion-personal",
                provider: .notion,
                title: "Japan Rail Pass Notes",
                subtitle: "Notion · Personal",
                body: "Pick up JR pass voucher at Tokyo Station North Exit.",
                timestamp: now.addingTimeInterval(-7_200)
            )
        ]

        let gate = MorningBriefCorpusBridge.makeReadOnlyVaultGate(
            vaultRoot: tempVault,
            corpus: corpus,
            calendar: calendar,
            connectorItems: cloudItems
        )

        let sourceHit = try await gate.execute(toolName: "lookup_source", query: "imessage:msg-77")
        #expect(sourceHit.contains("morning Shinkansen to Kyoto"))

        let calendarHit = try await gate.execute(toolName: "check_calendar", query: "today")
        #expect(calendarHit.contains("Kyoto Itinerary Check-in"))

        let connectorHit = try await gate.execute(toolName: "read_connector_readonly", query: "notion")
        #expect(connectorHit.contains("Japan Rail Pass Notes"))

        let vaultHit = try await gate.execute(toolName: "search_vault", query: "Shinkansen")
        #expect(vaultHit.contains("Confirm Shinkansen tickets"))
        #expect(!vaultHit.contains("Private style sample"))
    }

    // MARK: - 6b. Computer-Use Overflow Guards & Factory Reset Keychain Wipe (#87)

    @Test func computerUseCoordinateAndScrollOverflowSafetyAndFactoryResetWipesKeychain() async throws {
        // 1. Out-of-Int-range / non-finite coordinates in DriverError.pointOutOfBounds must NEVER trap
        let hugeCoordError = NativeCGComputerUseDriver.DriverError.pointOutOfBounds(
            x: 1e35,
            y: -1e35,
            width: 1_440,
            height: 900
        )
        #expect(!hugeCoordError.localizedDescription.isEmpty)

        let nanCoordError = NativeCGComputerUseDriver.DriverError.pointOutOfBounds(
            x: .nan,
            y: .infinity,
            width: 800,
            height: 600
        )
        #expect(!nanCoordError.localizedDescription.isEmpty)

        // 2. Extreme finite scroll deltas (1e30) must either clamp safely or fail gracefully — NEVER trap Int32(...)!
        final class ScrollBox: @unchecked Sendable {
            let lock = NSLock()
            var recordedScroll: (Int32, Int32)?
            func record(_ dx: Int32, _ dy: Int32) {
                lock.lock()
                recordedScroll = (dx, dy)
                lock.unlock()
            }
        }
        let scrollBox = ScrollBox()
        let snapshot = NativeCGComputerUseDriver.ObservedWindowState(
            pid: 7777,
            bundleID: "com.apple.TextEdit",
            bundlePath: "/System/Applications/TextEdit.app",
            appName: "TextEdit",
            windowTitle: "OverflowGuard.txt",
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isSecureFieldFocused: false,
            elements: [],
            pngData: nil,
            imageWidth: 800,
            imageHeight: 600
        )
        let backend = NativeCGComputerUseDriver.Backend(
            inspectAppState: { _ in snapshot },
            prepareInputTarget: { _ in snapshot },
            postEvent: { event in
                if case .scroll(_, let dx, let dy) = event.kind {
                    scrollBox.record(dx, dy)
                }
            }
        )
        let client = try await OwnedNativeComputerUseClient.openBuiltIn(backend: backend)
        defer { Task { await client.close() } }

        let revocation = NativeInputRevocation()
        do {
            _ = try await client.mutate(
                requestID: "req-scroll-overflow",
                app: "com.apple.TextEdit",
                command: .scroll(.init(x: 120, y: 120), deltaX: 1e30, deltaY: -1e30),
                revocation: revocation,
                preflight: { reserved in .init(notAfter: reserved.notAfter, revocation: revocation) }
            )
            // If clamped rather than rejected, recorded Int32 values must be finite/clamped
            #expect(scrollBox.recordedScroll != nil)
        } catch {
            // Clean validation rejection without runtime trap is also acceptable
            #expect(!error.localizedDescription.isEmpty)
        }

        // 3. Factory Reset wipes Relay Keychain credentials while preserving ~/.codex and ~/.claude
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayWave2Reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let homeDir = sandbox.appendingPathComponent("Home", isDirectory: true)
        let libraryDir = homeDir.appendingPathComponent("Library", isDirectory: true)
        let supportDir = libraryDir.appendingPathComponent("Application Support/Relay", isDirectory: true)
        let codexAuth = homeDir.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: codexAuth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try Data("{\"ok\":true}".utf8).write(to: codexAuth)

        let suiteName = "dev.relay.wave2.reset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var keychainWipeCalls = 0
        let env = UninstallAndResetCoordinator.Environment(
            supportDirectory: supportDir,
            libraryDirectory: libraryDir,
            homeDirectory: homeDir,
            bundleIdentifier: "dev.relay.wave2.reset",
            appBundleURL: URL(fileURLWithPath: "/Applications/Relay.app"),
            defaults: defaults,
            defaultsDomainName: suiteName,
            stopRuntime: {},
            resetStoreForFactoryReset: { _ in },
            disableLoginItem: {},
            removeWakeHelper: {},
            deleteRemoteMirror: { nil },
            wipeKeychain: {
                keychainWipeCalls += 1
                return ["com.relay.oauth-mcp.grants", "com.relay.openrouter"]
            },
            spawnPostExitSweep: { _ in },
            terminateApp: {}
        )
        let resetCoordinator = UninstallAndResetCoordinator(environment: env)
        _ = await resetCoordinator.performFactoryReset(onboarding: nil, deleteDownloadedModels: false)
        #expect(keychainWipeCalls == 1)
        #expect(FileManager.default.fileExists(atPath: codexAuth.path) == true)

        // 4. Chromium AX Enhanced UI coverage across Chrome, Arc, Brave, Edge, and Dia (#87 #5)
        for chromiumID in [
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.dia"
        ] {
            #expect(BrowserAccessibility.supportsEnhancedAccessibility(bundleIdentifier: chromiumID) == true)
        }
        #expect(BrowserAccessibility.supportsEnhancedAccessibility(bundleIdentifier: "com.apple.Safari") == false)

        // 5. WorkspaceModelOptions switch-back button shown for both Codex CLI and Claude CLI (#87 #12)
        #expect(WorkspaceModelOptions.showsSwitchBackButton(workspaceUsesCodex: false, workspaceUsesClaude: true) == true)
        #expect(WorkspaceModelOptions.showsSwitchBackButton(workspaceUsesCodex: true, workspaceUsesClaude: false) == true)
        #expect(WorkspaceModelOptions.showsSwitchBackButton(workspaceUsesCodex: false, workspaceUsesClaude: false) == false)

        // 6. Live computer-use backend enforces AXIsProcessTrusted() before inspection (#87 #2)
        let untrustedLiveBackend = NativeCGComputerUseDriver.Backend.live(isAccessibilityTrusted: { false })
        await #expect(throws: NativeCGComputerUseDriver.DriverError.accessibilityPermissionRequired) {
            _ = try await untrustedLiveBackend.inspectAppState("com.apple.Finder")
        }
    }

    // MARK: - 7. Opt-In Non-Destructive Live Host Probes (`RELAY_LIVE_PROBES=1`)

    @Test func liveHostRuntimeProbesWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["RELAY_LIVE_PROBES"] == "1" else { return }

        // Probe 1: Live YouTube iOS 20.10.4 Innertube + caption track download
        let ytPrimary = try await YouTubeTranscriptFetcher.fetchTranscript(
            for: "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        )
        let ytResolved: YouTubeTranscriptFetcher.Transcript?
        if let ytPrimary {
            ytResolved = ytPrimary
        } else {
            ytResolved = try await YouTubeTranscriptFetcher.fetchTranscript(
                for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
            )
        }
        let transcript = try #require(ytResolved, "Expected live YouTube transcript from jNQXAC9IVRw or dQw4w9WgXcQ")
        #expect(transcript.segmentCount > 0)
        #expect(!transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // Probe 2: Live 2-turn Codex CLI (`exec` + `exec resume`) against ChatGPT.app embedded codex
        let embeddedCodex = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        if FileManager.default.isExecutableFile(atPath: embeddedCodex.path) {
            let codex = CodexCLIClient()
            defer { codex.resetSession() }
            let readiness = await codex.readiness()
            if readiness == .ready {
                let turn1 = try await codex.complete(
                    messages: [
                        .init(role: "system", content: "Answer concisely in plain text."),
                        .init(role: "user", content: "Remember the codeword COBALT-42 and reply with ACK1.")
                    ],
                    tools: [],
                    continueSession: true
                )
                #expect(!turn1.content.isEmpty)
                let turn1ThreadID = try #require(codex.lastThreadID)

                let turn2 = try await codex.complete(
                    messages: [
                        .init(role: "system", content: "Answer concisely in plain text."),
                        .init(role: "user", content: "What codeword did I just ask you to remember?")
                    ],
                    tools: [],
                    continueSession: true
                )
                #expect(turn2.content.uppercased().contains("COBALT"))
                #expect(codex.lastThreadID == turn1ThreadID, "Expected Turn 2 exec resume to succeed on the same thread without falling back to a fresh session")
            }
        }

        // Probe 3: Live IOHID SPU PhysicalTapSensor open/close on Apple Silicon MacBook Pro
        final class SensorStatusRecorder: @unchecked Sendable {
            let lock = NSLock()
            var statuses: [PhysicalTapSensor.Status] = []
            func record(_ s: PhysicalTapSensor.Status) {
                lock.lock()
                statuses.append(s)
                lock.unlock()
            }
            func snapshot() -> [PhysicalTapSensor.Status] {
                lock.lock()
                defer { lock.unlock() }
                return statuses
            }
        }
        let recorder = SensorStatusRecorder()
        let sensor = PhysicalTapSensor(
            onTap: { _, _ in },
            onStatus: { status, _ in recorder.record(status) }
        )
        sensor.configure(enabled: true, sensitivity: 1.1, generation: 1)
        try await Task.sleep(for: .milliseconds(650))
        sensor.drainForTermination()
        let observedStatuses = recorder.snapshot()
        #expect(!observedStatuses.isEmpty)
        #expect(!observedStatuses.contains(.unavailable), "Expected SPU HID sensors to open cleanly on MacBookPro18,3, got \(observedStatuses)")

        // Probe 4: Live OAuth .well-known metadata discovery against Notion, Granola, Slack, Google OIDC & Microsoft OIDC
        let notionLive = try await OAuthMetadataDiscovery.discover(
            endpoint: OAuthMCPProvider.notion.defaultEndpoint!,
            provider: .notion
        )
        #expect(notionLive.server.registrationEndpoint != nil)

        let granolaLive = try await OAuthMetadataDiscovery.discover(
            endpoint: OAuthMCPProvider.granola.defaultEndpoint!,
            provider: .granola
        )
        #expect(granolaLive.server.registrationEndpoint != nil)

        let slackLive = try await OAuthMetadataDiscovery.discover(
            endpoint: OAuthMCPProvider.slack.defaultEndpoint!,
            provider: .slack
        )
        #expect(!slackLive.scopes.contains("chat:write"))

        let (_, googleOIDCResp) = try await OAuthMetadataDiscovery.defaultTransport(
            URLRequest(url: URL(string: "https://accounts.google.com/.well-known/openid-configuration")!)
        )
        #expect(googleOIDCResp.statusCode == 200)

        let (_, msOIDCResp) = try await OAuthMetadataDiscovery.defaultTransport(
            URLRequest(url: URL(string: "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration")!)
        )
        #expect(msOIDCResp.statusCode == 200)
    }
}
