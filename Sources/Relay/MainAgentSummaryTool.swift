import Foundation

/// Actual captured-source summary. Model arguments select only a source the
/// current local task already admits; no argument creates capture/input scope.
@MainActor enum MainAgentSummaryTool {
    static let name = "summarize_screen"
    typealias Generate = @MainActor ([ModelMessage], @escaping @MainActor @Sendable () async throws -> Void) async throws -> ModelReply
    enum Failure: LocalizedError, Equatable {
        case arguments, unavailable, readerUnavailable
        var errorDescription: String? {
            switch self {
            case .arguments: "Choose an observed running app or one explicitly granted PDF path, with an optional bounded summary preference."
            case .unavailable: "The admitted original source could not produce a summary for this task. No replacement source was read."
            case .readerUnavailable: "The completed summary reader was closed or could not be presented. No displayed success was reported."
            }
        }
    }
    struct Request {
        let applicationID: String?, pdfPath: String?, preference: String
    }
    static var definition: ToolDefinition {
        .init(name: name,
            description: "Summarize an admitted app's bounded text or granted PDF; open its reader. No later-frontmost fallback or edits. Honor coverage/body_omitted; raw summary requires fresh same-source proof.",
            parameters: .object(["type": .string("object"), "additionalProperties": .bool(false),
                "properties": .object(["application_id": .object(["type": .string("string")]),
                    "path": .object(["type": .string("string")]),
                    "preference": .object(["type": .string("string")])])]))
    }
    static func decode(_ call: ToolCall) throws -> Request {
        guard call.name == name, Set(call.arguments.keys).isSubset(of: ["application_id", "path", "preference"]) else { throw Failure.arguments }
        for value in call.arguments.values { guard case .string = value else { throw Failure.arguments } }
        let app = call.arguments["application_id"]?.string, path = call.arguments["path"]?.string
        let preference = call.arguments["preference"]?.string ?? ""
        guard app == nil || path == nil, preference.utf8.count <= 1_000,
              preference.isEmpty || BoundTextSelection.usableText(preference, maximumBytes: 1_000),
              app.map({ !$0.isEmpty && $0.utf8.count <= 255 }) ?? true,
              path.map({ !$0.isEmpty && $0.utf8.count <= 4_096 }) ?? true else { throw Failure.arguments }
        return Request(applicationID: app, pdfPath: path, preference: preference)
    }
    @MainActor final class Produced {
        let checkpointResult: ToolResult
        private let captured: DocumentSummaryCurrentSource.Captured
        private let completion: DocumentSummaryCoordinator.AgentCompletion
        private let coordinator: DocumentSummaryCoordinator
        private let contextProof: ModelInputSourceProof
        private let runID: UUID, scopeID: UUID, sourceRevision: Int
        private var publicationBegan = false
        private(set) var wasPublished = false
        fileprivate init(captured: DocumentSummaryCurrentSource.Captured,
                         completion: DocumentSummaryCoordinator.AgentCompletion,
                         coordinator: DocumentSummaryCoordinator, contextProof: ModelInputSourceProof,
                         runID: UUID, scopeID: UUID, sourceRevision: Int) throws {
            try captured.validateSnapshotScope(); try completion.validate(); try contextProof.validateFinalMetadata()
            self.captured = captured; self.completion = completion; self.coordinator = coordinator
            self.contextProof = contextProof; self.runID = runID; self.scopeID = scopeID; self.sourceRevision = sourceRevision
            checkpointResult = ToolResult(summary: "A bounded captured-source summary finished and is waiting for its saved checkpoint before reader presentation.",
                evidence: "No displayed success, private summary body or current-document/action authority was published.", verified: true)
        }
        func closeIfUnpublished() { if !wasPublished { coordinator.close(id: completion.id) } }
        /// Called only AFTER actual outer result settlement. All asynchronous
        /// source checks precede private reader/model-result publication.
        func publish(in panels: DocumentSummaryPanelController) async throws -> (result: ToolResult, proof: ModelInputSourceProof) {
            guard !publicationBegan else { throw Failure.unavailable }
            publicationBegan = true
            do {
                try await contextProof.validate()
                try captured.validateSnapshotScope(); try completion.validate()
                var bodyProof: ModelInputSourceProof?
                do {
                    bodyProof = try captured.sourceProof(runID: runID, scopeID: scopeID,
                        sourceRevision: sourceRevision, inputProof: contextProof)
                    try await bodyProof?.validate()
                } catch { bodyProof = nil }
                // A body miss never hides revoked input A or a revoked task.
                try await contextProof.validate()
                try captured.validateSnapshotScope(); try completion.validate()
                try bodyProof?.validateFinalMetadata(); try contextProof.validateFinalMetadata()
                let text = try completion.completedText()
                let session = try completion.publishToReader()
                panels.present(session: session, coordinator: coordinator)
                guard panels.isPresented(session: session, coordinator: coordinator) else { throw Failure.readerUnavailable }
                try captured.validateSnapshotScope(); try completion.validate()
                try bodyProof?.validateFinalMetadata(); try contextProof.validateFinalMetadata()
                var payload: [String: JSONValue] = ["displayed": .bool(true), "captured_snapshot": .bool(true),
                    "body_omitted": .bool(bodyProof == nil), "source_kind": .string(captured.source.kind.rawValue),
                    "truncated": .bool(captured.source.truncated), "captured_at": .string(captured.source.capturedAt.ISO8601Format()),
                    "coverage": .string(captured.source.coverage),
                    "scope": .string("A bounded captured text snapshot, not proof of a physical action, whole-goal completion or unchanged future contents. Images, video/audio and dedicated transcripts were not read.")]
                if bodyProof != nil {
                    payload["summary"] = .string(text)
                    payload["application"] = .string(captured.source.application)
                    payload["window_title"] = .string(captured.source.title)
                }
                let encoded = JSONValue.object(payload).pretty
                guard encoded.utf8.count <= 24_000 else { throw Failure.unavailable }
                wasPublished = true
                return (ToolResult(summary: encoded,
                    evidence: bodyProof == nil ? "The actual summary reader is displayed. Its captured body is omitted from agent context because fresh same-source body proof is unavailable."
                        : "The actual summary reader is displayed. The returned summary has a fresh same-retained-source body proof; revalidation remains required before later model use.", verified: true), bodyProof ?? contextProof)
            } catch {
                panels.close(id: completion.id); coordinator.close(id: completion.id)
                throw error
            }
        }
    }
    static func execute(source: DocumentSummaryCurrentSource, coordinator: DocumentSummaryCoordinator,
        contextProof: ModelInputSourceProof, runID: UUID, scopeID: UUID, sourceRevision: Int,
        validateOwner: @escaping @MainActor @Sendable () throws -> Void,
        generate: @escaping Generate) async throws -> Produced {
        try validateOwner(); try await contextProof.validate()
        let captured = try await source.capture()
        try await contextProof.validate(); try captured.validateSnapshotScope(); try validateOwner()
        let scopeCheck = captured.snapshotScopeValidator
        let bodyProof = try captured.sourceProof(runID: runID, scopeID: scopeID,
            sourceRevision: sourceRevision, inputProof: contextProof)
        let authorize: @MainActor @Sendable () async throws -> Void = {
            try validateOwner(); try scopeCheck(); try await contextProof.validate()
            try await bodyProof?.validate()
            try await contextProof.validate(); try scopeCheck(); try validateOwner()
        }
        let session = try coordinator.startForAgent(isSourceAuthorized: {
            do { try validateOwner(); try scopeCheck(); return true } catch { return false }
        }, capture: { captured.source }, generate: { messages in
            do {
                try await authorize()
                let reply = try await generate(messages, authorize)
                try await authorize(); return reply
            } catch { try await authorize(); throw error }
        })
        do {
            let completion = try await coordinator.waitForAgentCompletion(session, validateOwner: validateOwner)
            try await contextProof.validate(); try captured.validateSnapshotScope(); try completion.validate(); try validateOwner()
            return try Produced(captured: captured, completion: completion, coordinator: coordinator,
                contextProof: contextProof, runID: runID, scopeID: scopeID, sourceRevision: sourceRevision)
        } catch { coordinator.close(id: session.id); throw error }
    }
}
