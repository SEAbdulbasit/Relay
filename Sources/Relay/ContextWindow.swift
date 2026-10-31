import Foundation

/// Drops only complete earlier request segments. Current work and complete tool pairs remain intact.
nonisolated enum ContextWindow {
    struct Result { let messages: [ModelMessage]; let omittedMessages: Int }
    static func boundedObservation(_ message: ModelMessage, maximumBytes: Int = 4_000) -> ModelMessage {
        guard message.role == "tool", message.content.utf8.count > maximumBytes else { return message }
        let object = message.content.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let summary = object?["summary"] as? String ?? message.content
        let evidence = object?["evidence"] as? String ?? "Full evidence remains in local Activity."
        var compact = message
        var payload: [String: JSONValue] = [
            "summary": .string(prefixText(summary, bytes: 2_800)),
            "evidence": .string(prefixText(evidence, bytes: 500)),
            "coverage": .string("Abbreviated observation for the local context budget; omitted content is not evidence. Full tool output remains in local Activity. Narrow the request if essential source text or controls are missing.")
        ]
        if let verified = object?["verified"] as? Bool { payload["verified"] = .bool(verified) }
        compact.content = JSONValue.object(payload).pretty
        var excerptBytes = 2_800
        while compact.content.utf8.count > max(1_024, maximumBytes), excerptBytes > 100 {
            excerptBytes /= 2
            payload["summary"] = .string(prefixText(summary, bytes: excerptBytes))
            payload["evidence"] = .string(prefixText(evidence, bytes: min(200, excerptBytes)))
            compact.content = JSONValue.object(payload).pretty
        }
        return compact
    }
    static func bytes(_ messages: [ModelMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.utf8.count + $1.toolCalls.reduce(0) { $0 + JSONValue.object($1.arguments).pretty.utf8.count } }
    }
    static func prepare(_ history: [ModelMessage], activeStart: Int, budget: Int, maximumMessages: Int = 140) throws -> Result {
        var start = min(history.count, max(0, activeStart))
        // An interrupted action can settle after a new user message. Keep its originating
        // request segment with the late result rather than emitting an orphan tool response.
        while !isWellFormed(Array(history.dropFirst(start))), start > 0 {
            start = history.prefix(start).lastIndex(where: { $0.role == "user" }) ?? 0
        }
        guard isWellFormed(Array(history.dropFirst(start))) else {
            throw RelayError.message("The current task has incomplete tool history. No action was dispatched; start a new conversation to recover.")
        }
        let active = Array(history.dropFirst(start))
        guard !active.isEmpty, bytes(active) <= budget, active.count <= maximumMessages else {
            throw RelayError.message("This task exceeds the local model's working context. Completed work is preserved; reduce attached text or continue with a narrower request.")
        }
        var retainedStart = start
        var used = bytes(active)
        let boundaries = history.prefix(start).indices.filter { history[$0].role == "user" }
        for boundary in boundaries.reversed() {
            let candidate = Array(history[boundary..<retainedStart])
            let size = bytes(candidate)
            guard used + size <= budget - 300, history.count - boundary <= maximumMessages else { break }
            guard isWellFormed(Array(history.dropFirst(boundary))) else { continue }
            used += size
            retainedStart = boundary
        }
        var selected = Array(history.dropFirst(retainedStart))
        if retainedStart > 0 {
            selected.insert(ModelMessage(role: "user", content: "Context window notice: earlier completed conversation is omitted from this inference window to fit the local model. Full history remains in Relay. Do not guess omitted facts, prior approvals, recipients or outcomes; inspect or ask if essential. The current request follows."), at: 0)
        }
        guard bytes(selected) <= budget, selected.count <= maximumMessages else {
            throw RelayError.message("The current task plus its context notice exceed the local context budget. Reduce the current request; no history was deleted.")
        }
        return Result(messages: selected, omittedMessages: retainedStart)
    }
    private static func prefixText(_ text: String, bytes: Int) -> String {
        var result = Array(text.utf8.prefix(bytes))
        while String(bytes: result, encoding: .utf8) == nil, !result.isEmpty { result.removeLast() }
        return String(decoding: result, as: UTF8.self)
    }
    static func isWellFormed(_ messages: [ModelMessage]) -> Bool {
        var pending = Set<String>()
        for message in messages {
            for call in message.toolCalls { guard pending.insert(call.id).inserted else { return false } }
            if message.role == "tool" {
                guard let id = message.toolCallID, pending.remove(id) != nil else { return false }
            }
        }
        return pending.isEmpty
    }
}
