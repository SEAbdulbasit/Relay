import Foundation
import Testing
@testable import Relay

/// Opt-in runtime probes against real binaries/services on this Mac.
/// Run with: `RELAY_LIVE_PROBES=1 swift test --filter LiveProbes`
nonisolated enum LiveProbeGate {
    static let enabled = ProcessInfo.processInfo.environment["RELAY_LIVE_PROBES"] == "1"
    static func log(_ probe: String, _ message: String) {
        print("[LiveProbe:\(probe)] \(message)")
    }
}

@MainActor @Suite(.serialized, .enabled(if: LiveProbeGate.enabled))
struct LiveProbesProviders {
    private let echoTool = ToolDefinition(
        name: "launch_app",
        description: "Propose opening a macOS application by name",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["name": .object(["type": .string("string")])]),
            "required": .array([.string("name")])
        ])
    )

    // MARK: 1. Codex

    @Test func codexDiscoverySignatureReadinessAndPrompt() async throws {
        let discovered = CodexCLIClient.discoverExecutable(allowUnverifiedStandalone: false)
        LiveProbeGate.log("codex", "discover=\(discovered)")
        let cli = try discovered.get()
        #expect(cli.isOfficialOpenAISigned)
        let hash = CodexCLIClient.signedCodeHash(cli.url)
        LiveProbeGate.log("codex", "signedCodeHash=\(hash ?? "nil") path=\(cli.url.path)")
        #expect(hash != nil)

        let client = CodexCLIClient()
        let configuration = try CodexCLIConfiguration(persistSessionContinuity: false)
        let readiness = await client.readiness(configuration: configuration)
        LiveProbeGate.log("codex", "readiness=\(readiness)")
        #expect(readiness == .ready)
        guard readiness == .ready else { return }

        let started = Date()
        do {
            let reply = try await client.complete(
                messages: [.init(role: "user", content: "Reply with exactly the word RELAYOK and nothing else.")],
                tools: [],
                configuration: configuration
            )
            LiveProbeGate.log("codex", "reply=\(reply.content.prefix(200)) toolCalls=\(reply.toolCalls.count) elapsed=\(Int(Date().timeIntervalSince(started)))s")
            #expect(reply.content.uppercased().contains("RELAYOK"))
        } catch {
            LiveProbeGate.log("codex", "complete FAILED: \(error) / \(error.localizedDescription)")
            Issue.record(error)
        }
    }

    // MARK: 2. Claude

    @Test func claudeDiscoverySignatureReadinessAndStructuredPrompt() async throws {
        let discovered = ClaudeCLIClient.discoverExecutable(allowUnverifiedBinary: false)
        LiveProbeGate.log("claude", "discover=\(discovered)")
        let cli = try discovered.get()
        #expect(cli.isOfficialAnthropicSigned)

        let client = ClaudeCLIClient()
        let configuration = try ClaudeCLIConfiguration(model: .haiku, reasoningEffort: .low)
        let readiness = await client.readiness(configuration: configuration)
        LiveProbeGate.log("claude", "readiness=\(readiness) version=\(await client.installedVersion() ?? "nil")")
        #expect(readiness.isReady)
        guard readiness.isReady else { return }

        do {
            let answer = try await client.complete(
                messages: [.init(role: "user", content: "Reply with exactly the word RELAYOK and nothing else. Do not call any tool.")],
                tools: [echoTool],
                configuration: configuration
            )
            LiveProbeGate.log("claude", "answer=\(answer.content.prefix(200)) toolCalls=\(answer.toolCalls.count)")
            #expect(answer.content.uppercased().contains("RELAYOK"))
            #expect(answer.toolCalls.isEmpty)

            let proposal = try await client.complete(
                messages: [.init(role: "user", content: "Use the launch_app tool to propose opening the Calculator app.")],
                tools: [echoTool],
                configuration: configuration
            )
            LiveProbeGate.log("claude", "proposal content=\(proposal.content.prefix(120)) toolCalls=\(proposal.toolCalls.map { "\($0.name)(\($0.arguments))" })")
            #expect(proposal.toolCalls.first?.name == "launch_app")
        } catch {
            LiveProbeGate.log("claude", "complete FAILED: \(error) / \(error.localizedDescription)")
            Issue.record(error)
        }
    }

    // MARK: 3. Local inference

    @Test func localServerDiscoveryReportsHonestly() async throws {
        let client = LMStudioClient()
        let endpoint = try LMStudioEndpoint()
        do {
            let models = try await client.listModels(endpoint: endpoint)
            LiveProbeGate.log("local", "LM Studio models=\(models)")
        } catch {
            LiveProbeGate.log("local", "LM Studio unavailable: \(error) / \(error.localizedDescription)")
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!, timeoutInterval: 3)
        request.httpMethod = "GET"
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            LiveProbeGate.log("local", "Ollama tags=\(String(decoding: data.prefix(300), as: UTF8.self))")
        } catch {
            LiveProbeGate.log("local", "Ollama unavailable: \(error.localizedDescription)")
        }
    }

    @Test func localInferenceLeaseIsFIFOUnderConcurrency() async throws {
        let lease = LocalInferenceLease()
        var order: [Int] = []
        var active = 0
        var maxActive = 0
        var tasks: [Task<Void, any Error>] = []
        for index in 0..<8 {
            tasks.append(Task { @MainActor in
                try await lease.withLease {
                    active += 1
                    maxActive = max(maxActive, active)
                    order.append(index)
                    try await Task.sleep(for: .milliseconds(20))
                    active -= 1
                }
            })
            // Give each task a chance to enqueue before the next one is created.
            await Task.yield()
            await Task.yield()
        }
        // Cancel one queued waiter; it must be removed without blocking the rest.
        let cancelled = Task { @MainActor in
            try await lease.withLease { order.append(99) }
        }
        await Task.yield()
        cancelled.cancel()
        for task in tasks { try await task.value }
        _ = try? await cancelled.value
        await lease.drain()
        LiveProbeGate.log("local", "lease order=\(order) maxActive=\(maxActive) busy=\(lease.isBusy) queued=\(lease.queuedWaiterCount)")
        #expect(order.filter { $0 != 99 } == Array(0..<8))
        #expect(!order.contains(99))
        #expect(maxActive == 1)
        #expect(!lease.isBusy)
    }

    // MARK: 6. YouTube

    @Test func youtubeTranscriptFetchesRealCaptions() async throws {
        for url in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://www.youtube.com/watch?v=jNQXAC9IVRw"] {
            do {
                let transcript = try await YouTubeTranscriptFetcher.fetchTranscript(for: url)
                LiveProbeGate.log("youtube", "\(url) -> \(transcript.map { "lang=\($0.languageCode) auto=\($0.isAutoGenerated) segments=\($0.segmentCount) title=\($0.title ?? "nil") text=\($0.text.prefix(160))" } ?? "nil")")
                #expect(transcript != nil)
                #expect((transcript?.text.count ?? 0) > 50)
            } catch {
                LiveProbeGate.log("youtube", "\(url) threw \(error)")
                Issue.record(error)
            }
        }
    }
}
