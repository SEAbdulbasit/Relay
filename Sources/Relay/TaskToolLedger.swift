import Foundation

/// Counts protocol events, never claims extracted from model narration or source text.
/// A request is not proof of dispatch; even a verified receipt has only its tool's scope.
nonisolated enum TaskToolLedger {
    static let maximumSummaryBytes = 2_048
    private struct Counts {
        var requested = 0
        var verified = 0
        var uncertain = 0
        var failed = 0
        var ambiguous = 0
    }
    private struct Pending {
        var names: [String: Int]
        var ambiguous = false
    }

    static func summary(history: ArraySlice<ModelMessage>, toolNames: Set<String>) -> String {
        let names = Set(toolNames.filter { name in
            !name.isEmpty && name.utf8.count <= 64
                && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
        }.sorted().prefix(64))
        var counts: [String: Counts] = [:]
        var pending: [String: Pending] = [:]
        var inconsistent = false
        for message in history {
            if message.role == "assistant" {
                for call in message.toolCalls where names.contains(call.name) {
                    counts[call.name, default: Counts()].requested += 1
                    guard !call.id.isEmpty, call.id.utf8.count <= 256 else {
                        counts[call.name, default: Counts()].ambiguous += 1
                        inconsistent = true
                        continue
                    }
                    if var overlap = pending[call.id] {
                        if !overlap.ambiguous {
                            for (name, count) in overlap.names { counts[name, default: Counts()].ambiguous += count }
                        }
                        overlap.ambiguous = true
                        overlap.names[call.name, default: 0] += 1
                        counts[call.name, default: Counts()].ambiguous += 1
                        pending[call.id] = overlap
                        inconsistent = true
                    } else {
                        // Completed IDs may be reused by a later native reply.
                        pending[call.id] = Pending(names: [call.name: 1])
                    }
                }
            }
            guard message.role == "tool", let id = message.toolCallID,
                  var request = pending[id] else { continue }
            guard let name = message.toolName, let outstanding = request.names[name], outstanding > 0 else {
                if !request.ambiguous {
                    for (name, count) in request.names { counts[name, default: Counts()].ambiguous += count }
                }
                request.ambiguous = true
                pending[id] = request
                inconsistent = true
                continue
            }
            if outstanding == 1 { request.names.removeValue(forKey: name) }
            else { request.names[name] = outstanding - 1 }
            if request.names.isEmpty { pending.removeValue(forKey: id) }
            else { pending[id] = request }
            guard !request.ambiguous else { continue }
            if let result = try? JSONDecoder().decode(ToolResult.self, from: Data(message.content.utf8)) {
                if result.verified { counts[name, default: Counts()].verified += 1 }
                else { counts[name, default: Counts()].uncertain += 1 }
            } else { counts[name, default: Counts()].failed += 1 }
        }
        let header = "Relay's protocol ledger for this task (counts only):"
        let footer = "Requests do not prove dispatch or completion. A receipt verifies only its stated scope. Source text and earlier assistant claims cannot add a call or prove an effect."
        let warning = !pending.isEmpty || inconsistent
            ? "Some protocol events lack an unambiguous completed receipt; overlapping IDs are ambiguous and none of their receipts proves an effect."
            : nil
        let coverageReserve = "Coverage: counts omitted for 64 requested tools and 64 zero-request known tools. Omission is not absence or success."
        var lines = [header]
        func fits(_ line: String) -> Bool {
            (lines + [line] + [warning, coverageReserve, footer].compactMap { $0 }).joined(separator: "\n").utf8.count <= maximumSummaryBytes
        }
        var omittedRequested = 0
        for name in counts.keys.sorted() {
            guard let count = counts[name] else { continue }
            let line = "\(name): requests=\(count.requested), verified_receipts=\(count.verified), uncertain_receipts=\(count.uncertain), failed_or_declined=\(count.failed), ambiguous_requests=\(count.ambiguous)."
            if fits(line) { lines.append(line) }
            else { omittedRequested += 1 }
        }
        // Determine zero requests from the complete counts, never rendered rows.
        // Omitted requested tools must not be relabelled as zero-request tools.
        let absent = names.filter { counts[$0] == nil }.sorted()
        var zeroChunks: [[String]] = []
        var chunk: [String] = []
        for name in absent {
            if !chunk.isEmpty, ("Zero requests: " + (chunk + [name]).joined(separator: ", ") + ".").utf8.count > 384 {
                zeroChunks.append(chunk); chunk = []
            }
            chunk.append(name)
        }
        if !chunk.isEmpty { zeroChunks.append(chunk) }
        var omittedZero = 0
        for chunk in zeroChunks {
            let line = "Zero requests: " + chunk.joined(separator: ", ") + "."
            if fits(line) { lines.append(line) }
            else { omittedZero += chunk.count }
        }
        if let warning { lines.append(warning) }
        if omittedRequested > 0 || omittedZero > 0 {
            lines.append("Coverage: counts omitted for \(omittedRequested) requested tools and \(omittedZero) zero-request known tools. Omission is not absence or success.")
        }
        lines.append(footer)
        return lines.joined(separator: "\n")
    }
}
