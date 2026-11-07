import Foundation

/// Builds an inference view without changing the audit history. Fresh sources,
/// exact requests, call arguments and opaque workflow receipts remain intact.
nonisolated enum ContextWindow {
    struct Result { let messages: [ModelMessage]; let omittedMessages: Int; let compactedMessages: Int }
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
        var inferenceHistory = history
        for index in 0..<start where history[index].role == "tool" && history[index].toolName == "observe_app" {
            guard var payload = try? JSONDecoder().decode([String: JSONValue].self, from: Data(history[index].content.utf8)) else { continue }
            payload["reference_status"] = .string("Expired from an earlier task. Historical source facts remain; do not reuse these IDs. Observe the intended app again before acting.")
            removeExpiredNativeReferences(from: &payload)
            inferenceHistory[index].content = JSONValue.object(payload).pretty
        }
        let compacted = compactActive(Array(inferenceHistory.dropFirst(start)), budget: budget)
        let active = compacted.messages
        guard !active.isEmpty, bytes(active) <= budget, active.count <= maximumMessages else {
            throw RelayError.message("This task exceeds the local model's working context. Completed work is preserved; reduce attached text or continue with a narrower request.")
        }
        var retainedStart = start
        var used = bytes(active)
        let boundaries = history.prefix(start).indices.filter { history[$0].role == "user" }
        for boundary in boundaries.reversed() {
            let candidate = Array(inferenceHistory[boundary..<retainedStart])
            let size = bytes(candidate)
            guard used + size <= budget - 300, history.count - boundary <= maximumMessages else { break }
            guard isWellFormed(Array(history.dropFirst(boundary))) else { continue }
            used += size
            retainedStart = boundary
        }
        var selected = Array(inferenceHistory[retainedStart..<start]) + active
        if retainedStart > 0 {
            selected.insert(ModelMessage(role: "user", content: "Context window notice: earlier completed conversation is omitted from this inference window to fit the local model. Full history remains in Relay. Do not guess omitted facts, prior approvals, recipients or outcomes; inspect or ask if essential. The current request follows."), at: 0)
        }
        guard bytes(selected) <= budget, selected.count <= maximumMessages else {
            throw RelayError.message("The current task plus its context notice exceed the local context budget. Reduce the current request; no history was deleted.")
        }
        guard isWellFormed(selected) else {
            throw RelayError.message("The local context could not preserve complete tool pairs. No action was dispatched.")
        }
        return Result(messages: selected, omittedMessages: retainedStart, compactedMessages: compacted.count)
    }

    /// Only memory pressure permits abbreviation. The newest native snapshot is
    /// never truncated: its last row can be the only actionable requested target.
    /// Other tools can return opaque draft/review IDs or exact source quotations,
    /// so their complete results are deliberately outside this transformation.
    private static func compactActive(_ history: [ModelMessage], budget: Int) -> (messages: [ModelMessage], count: Int) {
        var selected = history, compactedCount = 0
        var pending: [String: (call: ToolCall, position: Int)] = [:]
        var observations: [(index: Int, call: ToolCall, callPosition: Int, result: ToolResult)] = []
        var nextCallPosition = 0
        for (index, message) in history.enumerated() {
            for call in message.toolCalls {
                pending[call.id] = (call, nextCallPosition)
                nextCallPosition += 1
            }
            guard message.role == "tool", let id = message.toolCallID, let pendingCall = pending.removeValue(forKey: id) else { continue }
            let call = pendingCall.call
            guard call.name == "observe_app", message.toolName == call.name,
                  let result = try? JSONDecoder().decode(ToolResult.self, from: Data(message.content.utf8)) else { continue }
            observations.append((index, call, pendingCall.position, result))
        }
        let invalidatingTools: Set<String> = ["observe_app", "set_value", "press_control", "scroll_control", "open_app", "open_file",
            "search_finder", "move_file", "browser_navigate", "search_web", "open_url", "write_file", "create_document",
            "create_spreadsheet", "stage_attachment", "create_mail_draft", "send_mail"]
        let orderedCalls = history.flatMap(\.toolCalls)
        func laterAttempts(after position: Int) -> ArraySlice<ToolCall> {
            return orderedCalls.dropFirst(position + 1)
        }
        var expired = Set<Int>()
        for observation in observations {
            guard laterAttempts(after: observation.callPosition).contains(where: { invalidatingTools.contains($0.name) }),
                  var payload = try? JSONDecoder().decode([String: JSONValue].self, from: Data(history[observation.index].content.utf8)) else { continue }
            expired.insert(observation.index)
            // A later attempt invalidates native refs even if its effect failed,
            // was uncertain, or targeted another app. Historical facts stay whole.
            payload["reference_status"] = .string("Expired after a later observation or action attempt. Do not reuse these IDs; observe the intended app again before acting. This does not prove that the later action succeeded.")
            removeExpiredNativeReferences(from: &payload)
            selected[observation.index].content = JSONValue.object(payload).pretty
        }
        guard bytes(selected) > budget else { return (selected, 0) }
        for index in selected.indices {
            guard bytes(selected) > budget else { return (selected, compactedCount) }
            if selected[index].role == "assistant", !selected[index].toolCalls.isEmpty, !selected[index].content.isEmpty {
                selected[index].content = ""
                compactedCount += 1
            }
        }
        for observation in observations {
            guard bytes(selected) > budget else { break }
            guard expired.contains(observation.index),
                  let bundle = observation.call.arguments["bundle_id"]?.string,
                  laterAttempts(after: observation.callPosition).contains(where: {
                      invalidatingTools.contains($0.name) && $0.arguments["bundle_id"]?.string == bundle
                  }) else { continue }
            let receipt = JSONValue.object([
                "summary": .string("Superseded app observation omitted; old refs are invalid. Re-observe for source facts or controls."),
                "evidence": .string("Full original remains in local Activity."),
                "bundle_id": .string(bundle),
                "verified": .bool(observation.result.verified)
            ]).pretty
            guard receipt.utf8.count < selected[observation.index].content.utf8.count else { continue }
            selected[observation.index].content = receipt
            compactedCount += 1
        }
        for index in selected.indices {
            guard bytes(selected) > budget else { break }
            let available = budget - (bytes(selected) - selected[index].content.utf8.count)
            guard let excerpt = boundedReadSource(selected[index], maximumBytes: min(4_000, available)),
                  excerpt.content.utf8.count < selected[index].content.utf8.count else { continue }
            selected[index] = excerpt
            compactedCount += 1
        }
        return (selected, compactedCount)
    }

    /// Only the native AX formatter's complete record shape is recognized.
    /// Labels/values can contain reference-like source text, so only its first
    /// element_id token and final validated location token may be removed.
    private static func removeExpiredNativeReferences(from payload: inout [String: JSONValue]) {
        guard let evidence = payload["evidence"]?.string,
              evidence.hasPrefix("Native AX observation of ") || evidence.hasPrefix("Native AX fallback of "),
              let summary = payload["summary"]?.string else { return }
        var removed = false
        let lines = summary.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            guard let space = line.firstIndex(of: " "), line.hasPrefix("element_id="),
                  UUID(uuidString: String(line[line.index(line.startIndex, offsetBy: "element_id=".count)..<space])) != nil else { return line }
            var record = String(line[line.index(after: space)...])
            guard record.hasPrefix("role=AX"), record.contains(" title="), record.contains(" description="),
                  record.contains(" identifier="), record.contains(" value=") else { return line }
            if record.hasPrefix("role=AXWindow ") {
                guard record.range(of: #" enabled=(?:true|false) focused=(?:true|false) minimized=(?:true|false)$"#, options: .regularExpression) != nil else { return line }
            } else {
                if let range = record.range(of: #" window_id=[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) {
                    record = String(record[..<range.lowerBound])
                }
                guard record.hasSuffix(" enabled=true") || record.hasSuffix(" enabled=false") else { return line }
            }
            removed = true
            return "expired_control " + record
        }
        guard removed else { return }
        payload["summary"] = .string(lines.joined(separator: "\n"))
        if let status = payload["reference_status"]?.string {
            payload["reference_status"] = .string(status + " Executable native reference tokens were removed; labels, values and evidence remain historical.")
        }
    }

    /// Source/list tools may supply an explicitly partial inference excerpt.
    /// Controls and opaque/action receipts are never candidates. Evidence and
    /// verification remain whole; listings stop only at complete source lines.
    private static func boundedReadSource(_ message: ModelMessage, maximumBytes: Int) -> ModelMessage? {
        let textTools: Set<String> = ["read_file", "read_sidekick_window"]
        let lineTools: Set<String> = ["list_apps", "list_files", "search_files", "read_calendar", "read_browser_page", "search_knowledge"]
        guard message.role == "tool", let tool = message.toolName, textTools.contains(tool) || lineTools.contains(tool),
              maximumBytes >= 256,
              var payload = try? JSONDecoder().decode([String: JSONValue].self, from: Data(message.content.utf8)),
              let source = payload["summary"]?.string,
              payload["evidence"]?.string != nil,
              case .bool = payload["verified"] else { return nil }
        payload["context_coverage"] = .string("Explicitly partial source excerpt for this inference window (original summary: \(source.utf8.count) UTF-8 bytes). Omitted text is not evidence. Full output remains in local Activity; narrow the source read if missing facts are needed.")
        var textBudget = min(maximumBytes, source.utf8.count - 1)
        while textBudget >= 64 {
            let excerpt: String
            if textTools.contains(tool) {
                let gap = "\n[... source text omitted ...]\n"
                let kept = max(0, textBudget - gap.utf8.count)
                excerpt = prefixText(source, bytes: kept / 2) + gap + suffixText(source, bytes: kept - kept / 2)
            } else {
                var lines: [String] = [], used = 0
                for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                    let next = line.utf8.count + (lines.isEmpty ? 0 : 1)
                    guard used + next <= textBudget else { break }
                    lines.append(String(line)); used += next
                }
                excerpt = lines.joined(separator: "\n")
                guard !excerpt.isEmpty else { return nil }
            }
            payload["summary"] = .string(excerpt)
            var selected = message
            selected.content = JSONValue.object(payload).pretty
            if selected.content.utf8.count <= maximumBytes { return selected }
            textBudget = textBudget * 3 / 4
        }
        return nil
    }

    private static func suffixText(_ text: String, bytes: Int) -> String {
        var result = Array(text.utf8.suffix(max(0, bytes)))
        while String(bytes: result, encoding: .utf8) == nil, !result.isEmpty { result.removeFirst() }
        return String(decoding: result, as: UTF8.self)
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
