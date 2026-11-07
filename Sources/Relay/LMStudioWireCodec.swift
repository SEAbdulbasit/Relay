import Foundation

/// OpenAI-compatible framing only. No native runtime names, credentials,
/// endpoint-provided tools, executable code or text-extracted calls are added.
nonisolated enum LMStudioWireCodec {
    static let maximumInputBytes = 128 * 1_024
    static let maximumOutputBytes = 2 * 1_024 * 1_024
    static let maximumArgumentBytes = 64 * 1_024
    static let maximumCalls = 8
    static let maximumInputDepth = 32
    static let maximumInputNodes = 16_384

    /// Limit existing values before JSONEncoder can duplicate their contents.
    /// The later serialized-byte check still decides exact wire admission.
    private struct InputShapeBudget {
        var remaining = maximumInputBytes
        var nodes = 0
        mutating func text(_ text: String) throws {
            guard text.utf8.count <= remaining else { throw LMStudioFailure.inputLimit }
            remaining -= text.utf8.count
        }
        mutating func value(_ value: JSONValue, depth: Int = 0) throws {
            guard depth <= maximumInputDepth, nodes < maximumInputNodes, remaining > 0 else { throw LMStudioFailure.inputLimit }
            nodes += 1; remaining -= 1
            switch value {
            case .string(let string): try text(string)
            case .number(let number): if !number.isFinite { throw LMStudioFailure.malformedInput }
            case .object(let object):
                guard object.count <= maximumInputNodes - nodes else { throw LMStudioFailure.inputLimit }
                for (key, child) in object { try text(key); try self.value(child, depth: depth + 1) }
            case .array(let values):
                guard values.count <= maximumInputNodes - nodes else { throw LMStudioFailure.inputLimit }
                for child in values { try self.value(child, depth: depth + 1) }
            case .bool, .null: break
            }
        }
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }
    static func jsonData(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(value) }
        catch { throw LMStudioFailure.malformedInput }
    }

    /// Steering can settle between an assistant call and its late result in the
    /// local audit. For inference only, defer those non-tool messages until the
    /// complete exact result group; preserve all IDs, results and user order.
    static func canonicalHistory(_ messages: [ModelMessage]) throws -> [ModelMessage] {
        guard !messages.isEmpty, messages.count <= 160 else { throw LMStudioFailure.malformedHistory }
        var textBytes = 0
        for message in messages {
            guard message.content.utf8.count <= maximumInputBytes - textBytes else { throw LMStudioFailure.inputLimit }
            textBytes += message.content.utf8.count
        }
        var ordered: [ModelMessage] = [], deferred: [ModelMessage] = []
        var pending: [LMStudioProtocolID: String] = [:], seen = Set<LMStudioProtocolID>()
        for message in messages {
            guard ["system", "user", "assistant", "tool"].contains(message.role) else { throw LMStudioFailure.malformedHistory }
            guard message.toolCalls.count <= maximumCalls else { throw LMStudioFailure.malformedHistory }
            if message.role == "tool" {
                guard message.toolCalls.isEmpty, let id = message.toolCallID, let name = message.toolName,
                      !id.isEmpty, id.utf8.count <= 512, validName(name),
                      pending.removeValue(forKey: LMStudioProtocolID(id)) == name else { throw LMStudioFailure.malformedHistory }
                ordered.append(message)
                if pending.isEmpty { ordered += deferred; deferred.removeAll() }
                continue
            }
            guard message.toolCallID == nil, message.toolName == nil else { throw LMStudioFailure.malformedHistory }
            if !message.toolCalls.isEmpty {
                guard message.role == "assistant", pending.isEmpty else { throw LMStudioFailure.malformedHistory }
                for call in message.toolCalls {
                    guard !call.id.isEmpty, call.id.utf8.count <= 512, validName(call.name),
                          seen.insert(LMStudioProtocolID(call.id)).inserted else { throw LMStudioFailure.malformedHistory }
                    pending[LMStudioProtocolID(call.id)] = call.name
                }
                ordered.append(message)
            } else if pending.isEmpty { ordered.append(message) }
            else { deferred.append(message) }
        }
        guard pending.isEmpty, deferred.isEmpty else { throw LMStudioFailure.malformedHistory }
        return ordered
    }

    static func request(selection: LMStudioSelection, messages: [ModelMessage], tools: [ToolDefinition],
                        image: Data? = nil, imageAnnotation: String? = nil, stream: Bool = true) throws -> Data {
        let history = try canonicalHistory(messages)
        guard tools.count <= 64, Set(tools.map(\.name)).count == tools.count,
              tools.allSatisfy({ validName($0.name) && $0.parameters.object?["type"] == .string("object") }) else {
            throw LMStudioFailure.malformedToolCall
        }
        var shape = InputShapeBudget()
        for message in history {
            try shape.text(message.role); try shape.text(message.content)
            if let id = message.toolCallID { try shape.text(id) }
            if let name = message.toolName { try shape.text(name) }
            for call in message.toolCalls {
                try shape.text(call.id); try shape.text(call.name); try shape.value(.object(call.arguments))
            }
        }
        for tool in tools {
            try shape.text(tool.name); try shape.text(tool.description); try shape.value(tool.parameters)
        }
        var encoded: [JSONValue] = try history.map { message in
            var object: [String: JSONValue] = ["role": .string(message.role), "content": .string(message.content)]
            if message.role == "tool", let id = message.toolCallID { object["tool_call_id"] = .string(id) }
            if !message.toolCalls.isEmpty {
                object["tool_calls"] = .array(try message.toolCalls.map { call in
                    let data = try jsonData(.object(call.arguments))
                    guard data.count <= maximumArgumentBytes else { throw LMStudioFailure.malformedHistory }
                    return .object(["id": .string(call.id), "type": .string("function"), "function": .object([
                        "name": .string(call.name), "arguments": .string(String(decoding: data, as: UTF8.self))])])
                })
            }
            return .object(object)
        }
        if let image {
            guard !image.isEmpty, image.count <= LMStudioVisionAttachment.maximumJPEGBytes,
                  let annotation = imageAnnotation, annotation.utf8.count <= 2_048 else { throw LMStudioFailure.malformedResponse }
            encoded.append(.object(["role": .string("user"), "content": .array([
                .object(["type": .string("text"), "text": .string(annotation)]),
                .object(["type": .string("image_url"), "image_url": .object([
                    "url": .string("data:image/jpeg;base64," + image.base64EncodedString())])])])]))
        }
        let textOnly = try jsonData(.array(history.map { message in
            .object(["role": .string(message.role), "content": .string(message.content),
                "calls": .array(message.toolCalls.map { .object(["id": .string($0.id), "name": .string($0.name), "arguments": .object($0.arguments)]) })])
        }))
        let schemas = tools.map { tool in JSONValue.object(["type": .string("function"), "function": .object([
            "name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters])]) }
        guard textOnly.count + (try jsonData(.array(schemas))).count <= maximumInputBytes else { throw LMStudioFailure.inputLimit }
        var request: [String: JSONValue] = ["model": .string(selection.modelID), "messages": .array(encoded),
            "stream": .bool(stream), "temperature": .number(0.15), "max_tokens": .number(1_536)]
        if !tools.isEmpty { request["tools"] = .array(schemas); request["tool_choice"] = .string("auto") }
        let data = try jsonData(.object(request))
        guard data.count <= maximumInputBytes + 6 * 1_024 * 1_024 else { throw LMStudioFailure.inputLimit }
        return data
    }

    static func reply(_ value: JSONValue, availableTools: Set<String>, priorCallIDs: Set<LMStudioProtocolID> = []) throws -> ModelReply {
        guard value.object?["error"] == nil, let choices = value.object?["choices"], case .array(let entries) = choices,
              entries.count == 1, let choice = entries.first?.object, choice["index"] == .number(0),
              let message = choice["message"]?.object, message["role"] == .string("assistant"),
              let finish = choice["finish_reason"]?.string else { throw LMStudioFailure.malformedResponse }
        return try finishReply(content: message["content"], toolCalls: message["tool_calls"], finish: finish,
            availableTools: availableTools, priorCallIDs: priorCallIDs)
    }

    static func finishReply(content: JSONValue?, toolCalls: JSONValue?, finish: String,
                            availableTools: Set<String>, priorCallIDs: Set<LMStudioProtocolID>) throws -> ModelReply {
        guard ["stop", "tool_calls"].contains(finish) else { throw LMStudioFailure.truncatedOutput }
        let text: String
        switch content { case nil, .null: text = ""; case .string(let value): text = value; default: throw LMStudioFailure.malformedResponse }
        guard text.utf8.count <= maximumOutputBytes else { throw LMStudioFailure.responseLimit }
        var calls: [ToolCall] = [], seen = priorCallIDs
        if let toolCalls, toolCalls != .null {
            guard case .array(let entries) = toolCalls, entries.count <= maximumCalls else { throw LMStudioFailure.malformedToolCall }
            for entry in entries {
                guard let call = entry.object, call["type"] == .string("function"), let id = call["id"]?.string,
                      !id.isEmpty, id.utf8.count <= 512, seen.insert(LMStudioProtocolID(id)).inserted,
                      let function = call["function"]?.object, let name = function["name"]?.string,
                      validName(name), availableTools.contains(name), let arguments = function["arguments"]?.string,
                      arguments.utf8.count <= maximumArgumentBytes,
                      let value = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)),
                      let object = value.object else { throw LMStudioFailure.malformedToolCall }
                calls.append(ToolCall(id: id, name: name, arguments: object))
            }
        }
        guard (finish == "tool_calls") == !calls.isEmpty else { throw LMStudioFailure.malformedToolCall }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else { throw ModelProtocolError.emptyResponse }
        return .init(content: text, toolCalls: calls)
    }
}

/// Bytes are retained until complete UTF-8 lines and SSE event boundaries exist.
/// Partial arguments never become a ModelReply or a dispatchable action.
nonisolated struct LMStudioSSEDecoder {
    private struct Call { var id: String?; var name: String?; var arguments = "" }
    private var buffer = Data(), eventLines: [String] = []
    private var calls: [Int: Call] = [:]
    private var content = "", finish: String?, responseID: String?, bytes = 0
    private(set) var completed: ModelReply?
    let availableTools: Set<String>
    var priorCallIDs = Set<LMStudioProtocolID>()

    mutating func feed(_ data: Data) throws {
        guard completed == nil else {
            if data.contains(where: { ![9, 10, 13, 32].contains($0) }) { throw LMStudioFailure.malformedResponse }
            return
        }
        guard data.count <= LMStudioWireCodec.maximumOutputBytes - bytes else { throw LMStudioFailure.responseLimit }
        bytes += data.count; buffer.append(data)
        guard buffer.count <= 256 * 1_024 else { throw LMStudioFailure.responseLimit }
        while let newline = buffer.firstIndex(of: 10) {
            var line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            guard let string = String(data: line, encoding: .utf8) else { throw LMStudioFailure.invalidUTF8 }
            if string.isEmpty {
                try consumeEvent()
                if completed != nil {
                    guard buffer.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { throw LMStudioFailure.malformedResponse }
                    buffer.removeAll(); return
                }
                continue
            }
            if string.hasPrefix(":") { continue }
            if string.hasPrefix("data:") {
                let value = String(string.dropFirst(5)).drop(while: { $0 == " " })
                eventLines.append(String(value))
                guard eventLines.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1_024 else { throw LMStudioFailure.responseLimit }
            }
        }
    }

    mutating func end() throws -> ModelReply {
        guard let completed, buffer.allSatisfy({ [9, 10, 13, 32].contains($0) }), eventLines.isEmpty else { throw LMStudioFailure.incompleteStream }
        return completed
    }

    private mutating func consumeEvent() throws {
        guard !eventLines.isEmpty else { return }
        let event = eventLines.joined(separator: "\n"); eventLines.removeAll()
        if event == "[DONE]" {
            guard let finish else { throw LMStudioFailure.incompleteStream }
            guard calls.keys.sorted() == Array(0..<calls.count) else { throw LMStudioFailure.malformedToolCall }
            let callValues = calls.keys.sorted().map { index -> JSONValue in
                let call = calls[index]!
                return .object(["id": call.id.map(JSONValue.string) ?? .null, "type": .string("function"),
                    "function": .object(["name": call.name.map(JSONValue.string) ?? .null, "arguments": .string(call.arguments)])])
            }
            completed = try LMStudioWireCodec.finishReply(content: .string(content), toolCalls: .array(callValues), finish: finish,
                availableTools: availableTools, priorCallIDs: priorCallIDs)
            return
        }
        guard completed == nil, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(event.utf8)),
              let object = value.object, object["error"] == nil, let id = object["id"]?.string,
              let choices = object["choices"], case .array(let entries) = choices else { throw LMStudioFailure.malformedResponse }
        guard !id.isEmpty, id.utf8.count <= 512 else { throw LMStudioFailure.malformedResponse }
        if let responseID { guard LMStudioProtocolID.same(responseID, id) else { throw LMStudioFailure.malformedResponse } } else { responseID = id }
        if entries.isEmpty, object["usage"]?.object != nil { return }
        guard finish == nil, entries.count == 1,
              let choice = entries.first?.object, choice["index"] == .number(0),
              let delta = choice["delta"]?.object else { throw LMStudioFailure.malformedResponse }
        if let role = delta["role"], role != .string("assistant") { throw LMStudioFailure.malformedResponse }
        if let text = delta["content"], text != .null {
            guard let text = text.string, text.utf8.count <= LMStudioWireCodec.maximumOutputBytes - content.utf8.count else { throw LMStudioFailure.responseLimit }
            content += text
        }
        if let toolDeltas = delta["tool_calls"] {
            guard case .array(let entries) = toolDeltas else { throw LMStudioFailure.malformedToolCall }
            for entry in entries {
                guard let item = entry.object, case .number(let numericIndex) = item["index"],
                      numericIndex.isFinite, numericIndex.rounded() == numericIndex,
                      numericIndex >= 0, numericIndex < Double(LMStudioWireCodec.maximumCalls) else {
                    throw LMStudioFailure.malformedToolCall
                }
                let index = Int(numericIndex)
                var call = calls[index] ?? Call()
                if let type = item["type"], type != .string("function") { throw LMStudioFailure.malformedToolCall }
                if let id = item["id"] {
                    guard let id = id.string, !id.isEmpty, id.utf8.count <= 512, (call.id.map { LMStudioProtocolID.same($0, id) } ?? true) else { throw LMStudioFailure.malformedToolCall }
                    call.id = id
                }
                if let function = item["function"] {
                    guard let function = function.object else { throw LMStudioFailure.malformedToolCall }
                    if let name = function["name"] {
                        guard let name = name.string, LMStudioWireCodec.validName(name), call.name == nil || call.name == name else { throw LMStudioFailure.malformedToolCall }
                        call.name = name
                    }
                    if let arguments = function["arguments"] {
                        guard let fragment = arguments.string, fragment.utf8.count <= LMStudioWireCodec.maximumArgumentBytes - call.arguments.utf8.count else { throw LMStudioFailure.responseLimit }
                        call.arguments += fragment
                    }
                }
                calls[index] = call
            }
        }
        if let reason = choice["finish_reason"], reason != .null {
            guard let value = reason.string else { throw LMStudioFailure.malformedResponse }
            finish = value
        }
    }
}
