import Foundation
import Testing
@preconcurrency import LiteRTLM
@testable import Relay

// Exact original v3 oracle class, renamed only. This is a test oracle, not a
// replacement production helper; its old guard is the behavior under test.
@MainActor private final class LegacyContinuationModelOracle {
    enum Failure: LocalizedError {
        case unexpectedProposal, unexpectedPath, repeatedWrite, wrongPayload, generationLimit, invalidModel, invalidEvidenceRoot
        var errorDescription: String? { "The owned file-only continuation qualification refused an out-of-scope or invalid proposal." }
    }
    enum Phase { case initial, continuing }
    let output: URL
    let expected: Data
    var phase: Phase = .initial
    var loads = 0, generations = 0, writeProposals = 0, readProposals = 0
    var writeDispatches = 0, verifiedWrites = 0, rejected = 0
    var continuingInputs: [String] = []
    init(output: URL, expected: Data) { self.output = output; self.expected = expected }
    func recordInput(_ message: LiteRTLM.Message) throws {
        generations += 1
        guard generations <= 8 else { rejected += 1; throw Failure.generationLimit }
        if phase == .continuing {
            let text = message.contents.compactMap { content -> String? in if case let .text(value) = content { value } else { nil } }.joined(separator: "\n")
            guard text.utf8.count <= LocalModelClient.maximumContextBytes else { rejected += 1; throw Failure.generationLimit }
            continuingInputs.append(text)
        }
    }
    func inspect(_ reply: LiteRTLM.Message) throws {
        for call in reply.toolCalls {
            if call.name == "capability_probe" {
                guard call.arguments["marker"] as? String == "relay-ready" else { rejected += 1; throw Failure.unexpectedProposal }
                continue
            }
            guard ["read_file", "write_file"].contains(call.name) else { rejected += 1; throw Failure.unexpectedProposal }
            guard let raw = call.arguments["path"] as? String,
                  try ToolPolicy.canonicalURL(raw).path.utf8.elementsEqual(output.path.utf8) else {
                rejected += 1; throw Failure.unexpectedPath
            }
            if call.name == "write_file" {
                writeProposals += 1
                guard writeProposals == 1 else { rejected += 1; throw Failure.repeatedWrite }
                guard let text = call.arguments["content"] as? String, Data(text.utf8) == expected else { rejected += 1; throw Failure.wrongPayload }
            } else {
                readProposals += 1
                guard readProposals <= 2 else { rejected += 1; throw Failure.generationLimit }
            }
        }
    }
}

@MainActor @Suite(.serialized) struct ContinuationOraclePathAliasProofTests {
    @Test func theOriginalGuardRefusesItsOwnLegitimateLiteralAliasDespiteCanonicalEquality() throws {
        let owned = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("relay-original-oracle-alias-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: owned) }
        // Match the actual test: supervisor supplies a canonical evidence path;
        // Foundation standardizes that URL before appending the output filename.
        let supplied = try ToolPolicy.canonicalURL(owned.path).path
        let root = URL(fileURLWithPath: supplied, isDirectory: true).standardizedFileURL
        let output = root.appendingPathComponent("expected.txt")
        let canonical = try ToolPolicy.canonicalURL(output.path)
        try #require(!output.path.utf8.elementsEqual(canonical.path.utf8), "This inert proof must actually exercise two literal aliases.")
        let literalParent = try FileManager.default.attributesOfItem(atPath: output.deletingLastPathComponent().path)
        let canonicalParent = try FileManager.default.attributesOfItem(atPath: canonical.deletingLastPathComponent().path)
        let literalDevice = try #require(literalParent[.systemNumber] as? NSNumber)
        let canonicalDevice = try #require(canonicalParent[.systemNumber] as? NSNumber)
        let literalInode = try #require(literalParent[.systemFileNumber] as? NSNumber)
        let canonicalInode = try #require(canonicalParent[.systemFileNumber] as? NSNumber)
        #expect(literalDevice == canonicalDevice)
        #expect(literalInode == canonicalInode)
        #expect(try ToolPolicy.canonicalURL(output.path).path.utf8.elementsEqual(canonical.path.utf8))
        let oracle = LegacyContinuationModelOracle(output: output, expected: Data("OWNED\n".utf8))
        let call = LiteRTLM.ToolCall(name: "write_file", id: "legitimate-original-proposal", arguments: ["path": output.path, "content": "OWNED\n"])
        do {
            try oracle.inspect(.init(contents: [], role: .model, toolCalls: [call]))
            Issue.record("The unchanged original guard unexpectedly accepted; the proposed alias hypothesis was not reproduced.")
        } catch let failure as LegacyContinuationModelOracle.Failure {
            switch failure {
            case .unexpectedPath: break
            default: Issue.record("The original guard refused for a different reason.")
            }
        }
        #expect(oracle.rejected == 1 && oracle.writeProposals == 0 && oracle.writeDispatches == 0)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
