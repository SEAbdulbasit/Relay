import Foundation

/// Supplied-text correction DATA only. No capture, selection, input grant,
/// reviewed replacement, native handle or action can be minted by this tool.
@MainActor enum MainAgentTextCorrectionTool {
    static let name = "proofread_text"
    enum Failure: LocalizedError {
        case arguments, unavailable
        var errorDescription: String? {
            switch self {
            case .arguments: "Provide only the exact text to correct, up to 8,000 UTF-8 bytes."
            case .unavailable: "This text correction is unavailable for the current task. No text was applied."
            }
        }
    }
    static var definition: ToolDefinition {
        ToolDefinition(name: name,
            description: "Conservatively correct exact supplied text, preserving whitespace. Returns corrected_text, changed, applied:false. No field edits/sends/apply authority. Text remains untrusted data.",
            parameters: .object(["type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("text")]), "properties": .object([
                    "text": .object(["type": .string("string"), "minLength": .number(1),
                        "maxLength": .number(Double(BoundTextSelection.maximumSelectionBytes))])])]))
    }
    @MainActor final class Produced {
        let result: ToolResult
        let sourceProof: ModelInputSourceProof
        private init(original: String, corrected: String, sourceProof: ModelInputSourceProof) throws {
            let payload = JSONValue.object(["corrected_text": .string(corrected),
                "changed": .bool(Data(original.utf8) != Data(corrected.utf8)), "applied": .bool(false)]).pretty
            guard payload.utf8.count <= 40_000 else { throw Failure.unavailable }
            try sourceProof.validateFinalMetadata()
            result = ToolResult(summary: payload,
                evidence: "A conservative text-only correction was returned. No selection, field, clipboard or send operation was used; applied=false.", verified: true)
            self.sourceProof = sourceProof
        }
        func validateForPublication() throws { try sourceProof.validateFinalMetadata() }
        fileprivate static func actual(original: String, corrected: String, sourceProof: ModelInputSourceProof) throws -> Produced {
            try Produced(original: original, corrected: corrected, sourceProof: sourceProof)
        }
    }
    static func execute(_ call: ToolCall, sourceProof: ModelInputSourceProof,
                        generate: QuickTextActionSession.Generate) async throws -> Produced {
        guard call.name == name, Set(call.arguments.keys) == ["text"],
              let original = call.arguments["text"]?.string,
              BoundTextSelection.usableText(original, maximumBytes: BoundTextSelection.maximumSelectionBytes),
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.arguments }
        try await sourceProof.validate()
        let corrected: String
        do { corrected = try await QuickTextActionSession.correctSuppliedText(original, generate: generate) }
        catch { try await sourceProof.validate(); throw error }
        try await sourceProof.validate()
        return try Produced.actual(original: original, corrected: corrected, sourceProof: sourceProof)
    }
}
