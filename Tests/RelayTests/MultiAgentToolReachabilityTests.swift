import Foundation
import Testing
@testable import Relay

/// Real local tools with deterministic role replies. No model or desktop input.
@MainActor struct MultiAgentToolReachabilityTests {
    @Test func inspectionAndFileActionsHaveReachableRoles() {
        let navigator = Set(ToolPartitioning.partitionedTools(for: .navigator, from: MacTools.definitions).map(\.name))
        let executor = Set(ToolPartitioning.partitionedTools(for: .executor, from: MacTools.definitions).map(\.name))
        #expect(["calculate"].allSatisfy(navigator.contains))
        #expect(["open_file", "preview_file_move", "move_file"].allSatisfy(executor.contains))
        #expect(navigator.isDisjoint(with: ["read_calendar", "search_files"]), "Private inspection bodies need current-source adapters before downstream automatic use.")
        #expect(navigator.isDisjoint(with: ["open_file", "write_file", "preview_file_move", "move_file"]))
        #expect(ToolPartitioning.partitionedTools(for: .planner, from: MacTools.definitions).isEmpty)
        let planner = AgentRole.planner.systemPrompt
        #expect(planner.contains("preview_file_move only") && planner.contains("exact returned preview_id"))
        #expect(planner.contains("move_file and explicit review") && planner.contains("separate steps"))
        #expect(planner.contains("Navigator calculate") && planner.contains("answered directly"))
    }

    @Test func navigatorReturnsActualArithmeticEvidenceToSynthesis() async throws {
        let tools = MacTools()
        var plannerTurns = 0, dispatched: [String] = [], receivedActualResult = false
        let orchestrator = MultiAgentOrchestrator(complete: { messages, advertised, _ in
            let system = messages.first?.content ?? ""
            if system.hasPrefix("ROLE: Planner") {
                plannerTurns += 1
                if plannerTurns == 1 {
                    return .init(content: """
                    {"taskType":"automation","steps":[{"id":"arithmetic","role":"Navigator","title":"Calculate the requested product"}]}
                    """, toolCalls: [])
                }
                receivedActualResult = messages.contains { $0.content.contains("Result: 10034697540") }
                return .init(content: "10034697540", toolCalls: [])
            }
            #expect(system.hasPrefix("ROLE: Navigator"))
            #expect(advertised.contains { $0.name == "calculate" })
            return .init(content: "", toolCalls: [.init(name: "calculate", arguments: ["expression": .string("428 × 23445555")])])
        }, execute: { call in
            dispatched.append(call.name)
            return try await tools.execute(call)
        })
        let result = try await orchestrator.executeTask(goal: "Calculate 428 × 23445555 using local arithmetic.")
        #expect(result.isSuccess && receivedActualResult)
        #expect(dispatched == ["calculate"])
        #expect(result.verifiedResults.first?.summary == "Result: 10034697540")
    }

    @Test(arguments: [false, true])
    func dependentMoveUsesActualPreviewAndExactReview(approve: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt"), destination = root.appendingPathComponent("renamed.txt")
        let bytes = Data("owned move fixture — Café".utf8)
        try bytes.write(to: source)
        let tools = MacTools(); tools.grants = [.init(path: root.path, writable: true)]
        var plannerTurns = 0, executorTurns = 0, reviews = 0, dispatched: [String] = [], actualTicket: String?
        let orchestrator = MultiAgentOrchestrator(complete: { messages, advertised, _ in
            let system = messages.first?.content ?? ""
            if system.hasPrefix("ROLE: Planner") {
                plannerTurns += 1
                if plannerTurns == 1 {
                    return .init(content: """
                    {"taskType":"automation","steps":[{"id":"preview","role":"Executor","title":"Prepare the exact file rename"},{"id":"move","role":"Executor","title":"Review and execute the returned rename ticket"}]}
                    """, toolCalls: [])
                }
                return .init(content: "The reviewed file rename completed.", toolCalls: [])
            }
            if system.hasPrefix("ROLE: Critic") {
                return .init(content: "VERIFIED: The actual local tool reported this step's checked outcome.", toolCalls: [])
            }
            #expect(system.hasPrefix("ROLE: Executor"))
            executorTurns += 1
            if executorTurns == 1 {
                #expect(advertised.contains { $0.name == "preview_file_move" })
                return .init(content: "", toolCalls: [.init(name: "preview_file_move", arguments: ["source": .string(source.path), "destination": .string(destination.path)])])
            }
            let ticket = try #require(actualTicket)
            #expect(messages.contains { $0.content.contains(ticket) })
            return .init(content: "", toolCalls: [.init(name: "move_file", arguments: ["preview_id": .string(ticket)])])
        }, execute: { call in
            dispatched.append(call.name)
            let result = try await tools.execute(call)
            if call.name == "preview_file_move" {
                let firstLine = try #require(result.summary.split(separator: "\n").first)
                #expect(firstLine.hasPrefix("preview_id: "))
                actualTicket = String(firstLine.dropFirst("preview_id: ".count))
                #expect(UUID(uuidString: actualTicket ?? "") != nil)
                #expect(FileManager.default.fileExists(atPath: source.path))
                #expect(!FileManager.default.fileExists(atPath: destination.path))
            }
            return result
        }, reviewReason: { tools.reviewReason(for: $0) }, requestReview: { call, reason in
            reviews += 1
            #expect(call.name == "move_file")
            #expect(call.arguments["preview_id"]?.string == actualTicket)
            #expect(reason.contains(source.lastPathComponent) && reason.contains(destination.lastPathComponent))
            // Approval is confined to the test-created file and exact ticket.
            if approve {
                try tools.prepareReview(call)
                try tools.authorize(call)
            }
            return approve
        })
        let result = try await orchestrator.executeTask(goal: "Rename the selected original.txt to renamed.txt after exact review.")
        #expect(reviews == 1 && executorTurns == 2)
        #expect(result.isSuccess == approve)
        #expect(dispatched == (approve ? ["preview_file_move", "move_file"] : ["preview_file_move"]))
        #expect(try Data(contentsOf: approve ? destination : source) == bytes)
        #expect(!FileManager.default.fileExists(atPath: (approve ? source : destination).path))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-role-tools-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
