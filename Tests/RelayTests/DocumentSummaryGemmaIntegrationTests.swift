import Foundation
import Testing
@testable import Relay

@MainActor
struct DocumentSummaryGemmaIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"] != nil), .timeLimit(.minutes(5)))
    func actualGemmaSummarizesCapturedDocumentFinalDecisionWithoutToolsOrDesktopActions() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"])
        let configuration = ModelConfiguration(modelPath: path, computeBackend: "cpu", model: "Gemma 4 E2B")
        let client = LocalModelClient()
        defer { client.unload() }
        let background = (1...18).map { "Working note \($0): the team reviewed the synthetic launch checklist. No decision was made in this working note." }.joined(separator: "\n")
        let text = "Synthetic launch minutes. An earlier proposal of 25 widgets was rejected.\n\n" + background
            + "\n\nFINAL CONFIRMED DECISION: Ship 73 widgets on 2026-11-12. The release code is GREEN-5842."
        let source = try DocumentSummarySource(kind: .browser, title: "Synthetic launch minutes", application: "Synthetic browser",
            location: "http://127.0.0.1/fixture/minutes", text: text,
            coverage: "Synthetic captured static document text, including its offscreen final decision.")
        var modelCalls = 0
        let summaries = DocumentSummaryCoordinator(generate: { messages in
            modelCalls += 1
            let reply = try await client.complete(messages: messages, tools: [], configuration: configuration)
            #expect(reply.toolCalls.isEmpty)
            return reply
        })
        let started = ContinuousClock.now
        let session = try summaries.start { source }
        let deadline = started.advanced(by: .seconds(185))
        while summaries.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!summaries.isBusy && session.phase == .ready)
        #expect(session.resultText.contains("GREEN-5842"))
        #expect(session.resultText.contains("73"))
        #expect(modelCalls == 1)
        summaries.closeAll()
        #expect(session.source == nil && session.resultText.isEmpty)
        let elapsed = started.duration(to: .now).components
        print("Synthetic document summary: CPU, one tool-free generation, \(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) seconds. No browser, file or desktop action dispatched.")
    }
}
