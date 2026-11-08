import Foundation

/// Local, process-only provenance for ordinary model history. Model/source text,
/// provider IDs and restored history cannot mint a group or source proof. Raw
/// history/Activity/journal remain untouched by this inference projection.
@MainActor final class LocalModelHistorySources {
    enum Failure: LocalizedError {
        case malformed, unavailable, capacity
        var errorDescription: String? {
            switch self {
            case .malformed: "The local tool history cannot preserve its exact accepted groups. No action from this model turn was dispatched."
            case .unavailable: "The selected local source context changed before model admission. Inspect a fresh authorized source; no action was repeated."
            case .capacity: "The current request and source-omission coverage cannot fit the local context. Reduce the request; original history remains available."
            }
        }
    }
    enum Receipt { case verified, unverified, notDispatched, failedOrUnknown }
    struct Projection {
        let messages: [ModelMessage]
        let originalIndices: [Int?]
        let sourceProof: ModelInputSourceProof?
        let validate: @MainActor @Sendable () async throws -> Void
        let omittedGroups: Int
        let omittedMessages: Int
        let compactedMessages: Int
    }
    private struct CallKey: Hashable {
        let id: Data, name: Data
        init(_ call: ToolCall) { id = Data(call.id.utf8); name = Data(call.name.utf8) }
    }
    private struct Group {
        let id: UUID
        let run: UUID?
        var start: Int
        let calls: [CallKey]
        let toolNames: [String]
        var covered: Bool
        var unavailable = false
        var inputProof: ModelInputSourceProof?
        var resultProofs: [CallKey: ModelInputSourceProof] = [:]
        var requiredSources: Set<CallKey>
        var returned: [CallKey: Receipt] = [:]
    }
    private var epoch = UUID()
    // Metadata lifetime follows actual retained history. This is not an action
    // ledger or a claimed total-memory/task-count bound. Lost proofs leave a
    // tombstone; they never turn old private bytes into source-free context.
    private var groups: [UUID: Group] = [:]
    private var starts: [Int: UUID] = [:]

    func reset() { epoch = UUID(); groups.removeAll(); starts.removeAll() }
    /// The Store supplies actual retained old positions when replacing history
    /// (for example keeping UI user input after steering). App-derived user-role
    /// corrections keep a tombstone; role == user alone is not provenance.
    func rebase(keepingOriginalIndices indices: [Int]) {
        epoch = UUID()
        let mapping = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        var retained: [UUID: Group] = [:], nextStarts: [Int: UUID] = [:]
        for var group in groups.values {
            guard let start = mapping[group.start] else { continue }
            group.start = start
            if group.covered { group.unavailable = true; group.inputProof = nil; group.resultProofs.removeAll() }
            retained[group.id] = group; nextStarts[start] = group.id
        }
        groups = retained; starts = nextStarts
    }
    /// Unregistered supported source calls are refused data, never reconstructed
    /// authority. This only creates a tombstone and no verified receipt metadata.
    private func quarantineUnregisteredSources(_ history: [ModelMessage]) {
        for (index, message) in history.enumerated() where starts[index] == nil
            && message.role == "assistant" && message.toolCalls.contains(where: { NativeCurrentModelContext.requiresCurrentSource($0.name) }) {
            let id = UUID(), calls = message.toolCalls.map(CallKey.init)
            let safe = Set(MacTools.definitions.map(\.name) + [NativeWindowReadTool.name, NativeWindowControlTools.outerName])
            groups[id] = Group(id: id, run: nil, start: index, calls: calls,
                toolNames: message.toolCalls.map { safe.contains($0.name) ? $0.name : "unrecognized_tool" },
                covered: true, unavailable: true, inputProof: nil, requiredSources: Set(calls))
            starts[index] = id
        }
    }

    func acceptReply(at index: Int, groupID: UUID, runID: UUID, reply: ModelReply,
                     inputProof: ModelInputSourceProof?) throws {
        guard index >= 0, starts[index] == nil, groups[groupID] == nil else { throw Failure.malformed }
        let calls = reply.toolCalls.map(CallKey.init)
        guard Set(calls.map(\.id)).count == calls.count else { throw Failure.malformed }
        let knownNames = Set(MacTools.definitions.map(\.name) + [NativeWindowReadTool.name,
            NativeWindowControlTools.outerName, SidekickWindowText.definition.name])
        let safeNames = reply.toolCalls.map { knownNames.contains($0.name) ? $0.name : "unrecognized_tool" }
        let required = Set(reply.toolCalls.filter { NativeCurrentModelContext.requiresCurrentSource($0.name) }.map(CallKey.init))
        groups[groupID] = Group(id: groupID, run: runID, start: index, calls: calls,
            toolNames: safeNames, covered: inputProof != nil || !required.isEmpty,
            inputProof: inputProof, requiredSources: required)
        starts[index] = groupID
    }
    /// App-generated narration/corrections derived from a particular model
    /// input remain dependent too. Actual user messages are never registered.
    func appDerivedMessage(at index: Int, runID: UUID, inputProof: ModelInputSourceProof?) throws {
        guard let inputProof else { return }
        let id = UUID()
        guard starts[index] == nil else { throw Failure.malformed }
        groups[id] = Group(id: id, run: runID, start: index, calls: [], toolNames: [],
            covered: true, inputProof: inputProof, requiredSources: [])
        starts[index] = id
    }
    func returned(groupID: UUID, call: ToolCall, receipt: Receipt) throws {
        guard var group = groups[groupID], group.calls.contains(CallKey(call)) else { throw Failure.malformed }
        group.returned[CallKey(call)] = receipt; groups[groupID] = group
    }
    /// The caller supplies only the proof from this actual native/plain-file
    /// result and accepted namespace. Nil is an explicit source tombstone.
    func resultSource(groupID: UUID, call: ToolCall, proof: ModelInputSourceProof?) throws {
        guard var group = groups[groupID], group.calls.contains(CallKey(call)) else { throw Failure.malformed }
        let key = CallKey(call)
        guard group.requiredSources.contains(key) else { return }
        if let proof { group.resultProofs[key] = proof }
        else { group.unavailable = true }
        groups[groupID] = group
    }
    func retireProof(groupID: UUID) {
        guard var group = groups[groupID], group.covered else { return }
        group.unavailable = true; group.inputProof = nil; group.resultProofs.removeAll()
        groups[groupID] = group
    }

    private func membership(_ history: [ModelMessage]) throws -> [Int: UUID] {
        guard ContextWindow.isWellFormed(history) else { throw Failure.malformed }
        var members: [Int: UUID] = [:]
        var pending: [Data: (name: Data, group: UUID?)] = [:]
        for (index, message) in history.enumerated() {
            let known = starts[index]
            if let known {
                guard let group = groups[known] else { throw Failure.malformed }
                if !group.calls.isEmpty {
                    guard message.role == "assistant", message.toolCalls.map(CallKey.init) == group.calls else { throw Failure.malformed }
                }
                members[index] = known
            }
            for call in message.toolCalls {
                guard pending.updateValue((Data(call.name.utf8), known), forKey: Data(call.id.utf8)) == nil else { throw Failure.malformed }
            }
            if message.role == "tool" {
                guard let id = message.toolCallID, let expected = pending.removeValue(forKey: Data(id.utf8)),
                      message.toolName.map({ Data($0.utf8) }) == expected.name else { throw Failure.malformed }
                if let group = expected.group { members[index] = group }
            }
        }
        return members
    }
    private func proof(_ group: Group) throws -> ModelInputSourceProof {
        guard !group.unavailable, group.requiredSources.allSatisfy({ group.resultProofs[$0] != nil }) else { throw Failure.unavailable }
        guard let proof = try ModelInputSourceProof.merging([group.inputProof] + group.resultProofs.values.map(Optional.init)) else { throw Failure.unavailable }
        return proof
    }
    private func notice(_ omitted: Set<UUID>, currentRun: UUID) -> ModelMessage {
        let omittedGroups = omitted.compactMap { groups[$0] }
        let names = Set(omittedGroups.flatMap(\.toolNames)).sorted()
        var verified = 0, unverified = 0, notDispatched = 0, unknown = 0
        for group in omittedGroups {
            for receipt in group.returned.values {
                switch receipt {
                case .verified: verified += 1
                case .unverified: unverified += 1
                case .notDispatched: notDispatched += 1
                case .failedOrUnknown: unknown += 1
                }
            }
        }
        return ModelMessage(role: "user", content: "Local source-history coverage (app-owned metadata, not authorization or goal proof):\n" + JSONValue.object([
            "omitted_complete_groups": .number(Double(omitted.count)),
            "earlier_run_groups": .number(Double(omittedGroups.filter { $0.run.map { $0 != currentRun } ?? false }.count)),
            "unregistered_groups": .number(Double(omittedGroups.filter { $0.run == nil }.count)),
            "tool_names": .array(names.map(JSONValue.string)),
            "returned_verified_receipts": .number(Double(verified)),
            "returned_unverified_receipts": .number(Double(unverified)),
            "known_not_dispatched": .number(Double(notDispatched)),
            "failed_or_unknown_receipts": .number(Double(unknown)),
            "coverage": .string("Whole source-dependent assistant/call/result groups were omitted because their current proof or context capacity was unavailable. Original Activity/journal facts remain. These counts do not certify the current goal. Do not repeat completed or uncertain effects to reconstruct omitted data; inspect a fresh authorized source and reassess.")
        ]).pretty)
    }

    func project(_ history: [ModelMessage], activeStart: Int, currentRun: UUID, budget: Int,
                 maximumMessages: Int = 140, gate: @escaping @MainActor @Sendable () throws -> Void) async throws -> Projection {
        try gate()
        quarantineUnregisteredSources(history)
        let expected = epoch, members = try membership(history)
        var omitted = Set<UUID>()
        func candidate() -> (messages: [ModelMessage], raw: [Int?], active: Int) {
            var messages: [ModelMessage] = [], raw: [Int?] = []
            for (index, message) in history.enumerated() {
                if let group = members[index], omitted.contains(group) { continue }
                messages.append(message); raw.append(index)
            }
            var active = raw.firstIndex(where: { ($0 ?? -1) >= activeStart }) ?? 0
            if !omitted.isEmpty {
                messages.insert(notice(omitted, currentRun: currentRun), at: active)
                raw.insert(nil, at: active)
            }
            active = min(active, max(0, messages.count - 1))
            return (messages, raw, active)
        }
        while true {
            try gate(); guard epoch == expected else { throw Failure.unavailable }
            let candidate = candidate()
            let selected: ContextWindow.Result
            do { selected = try ContextWindow.prepare(candidate.messages, activeStart: candidate.active,
                budget: budget, maximumMessages: maximumMessages) }
            catch {
                // Capacity omission needs no source IO. Only a whole covered
                // group can go; source-free/user/opaque legacy history stays.
                guard let oldest = groups.values.filter({ $0.covered && !omitted.contains($0.id) })
                    .sorted(by: { $0.start < $1.start }).first else { throw error }
                omitted.insert(oldest.id); continue
            }
            guard selected.originalIndices.count == selected.messages.count else { throw Failure.malformed }
            let raw = selected.originalIndices.map { index -> Int? in index.flatMap { candidate.raw[$0] } }
            let ids = Set(raw.compactMap { $0.flatMap { members[$0] } }).filter { groups[$0]?.covered == true }
            var proofs: [(UUID, ModelInputSourceProof)] = [], changed = false
            for id in ids.sorted(by: { (groups[$0]?.start ?? 0) < (groups[$1]?.start ?? 0) }) {
                try gate(); guard epoch == expected, let group = groups[id] else { throw Failure.unavailable }
                do {
                    let current = try proof(group)
                    try await current.validate(); try gate()
                    guard epoch == expected, let retained = groups[id], !retained.unavailable else { throw Failure.unavailable }
                    proofs.append((id, current))
                } catch {
                    try gate(); guard epoch == expected else { throw Failure.unavailable }
                    retireProof(groupID: id); omitted.insert(id); changed = true
                }
            }
            if changed { continue }
            let combined: ModelInputSourceProof?
            do { combined = try ModelInputSourceProof.merging(proofs.map { Optional($0.1) }) }
            catch {
                guard let oldest = proofs.first else { throw error }
                omitted.insert(oldest.0); continue
            }
            let includedIDs = proofs.map(\.0), check = combined?.validator
            let validate: @MainActor @Sendable () async throws -> Void = { [weak self] in
                guard let self else { throw Failure.unavailable }
                try gate(); guard self.epoch == expected else { throw Failure.unavailable }
                for id in includedIDs { guard let group = self.groups[id], !group.unavailable else { throw Failure.unavailable } }
                try await check?(); try gate()
                guard self.epoch == expected else { throw Failure.unavailable }
                for id in includedIDs { guard let group = self.groups[id], !group.unavailable else { throw Failure.unavailable } }
            }
            try await validate()
            return Projection(messages: selected.messages, originalIndices: raw, sourceProof: combined,
                validate: validate, omittedGroups: omitted.count,
                omittedMessages: selected.omittedMessages, compactedMessages: selected.compactedMessages)
        }
    }
}
