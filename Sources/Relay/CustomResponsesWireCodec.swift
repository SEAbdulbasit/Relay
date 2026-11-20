import CoreFoundation
import Foundation

nonisolated struct CustomResponsesNamespaceTarget: Equatable, Hashable, Sendable {
    let namespace: String
    let name: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.namespace.utf8) == Data(rhs.namespace.utf8)
            && Data(lhs.name.utf8) == Data(rhs.name.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Data(namespace.utf8))
        hasher.combine(Data(name.utf8))
    }
}

nonisolated struct CustomResponsesNamespaceDefinition: Codable, Sendable {
    var name: String
    var description: String
    var tools: [ToolDefinition]

    init(name: String, description: String = "", tools: [ToolDefinition]) {
        self.name = name
        self.description = description
        self.tools = tools
    }
}

typealias CustomResponsesNamespaceMapping = [String: CustomResponsesNamespaceTarget]

/// Translates OpenAI Responses wire payloads to and from the portable subset supported by
/// custom Responses-compatible endpoints (LM Studio, OpenRouter, vLLM, and enterprise gateways).
nonisolated enum CustomResponsesTranslator {
    static let namespaceSeparator = "__"

    static func validIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    static func isStrictASCIIToolName(_ value: String) -> Bool {
        let utf8 = Array(value.utf8)
        guard !utf8.isEmpty, utf8.count <= 128 else { return false }
        let first = utf8[0]
        guard (first >= 0x41 && first <= 0x5A)
                || (first >= 0x61 && first <= 0x7A)
                || first == 0x5F else {
            return false
        }
        for byte in utf8.dropFirst() {
            let isUpper = byte >= 0x41 && byte <= 0x5A
            let isLower = byte >= 0x61 && byte <= 0x7A
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isUnderscore = byte == 0x5F
            if !(isUpper || isLower || isDigit || isUnderscore) {
                return false
            }
        }
        return LMStudioWireCodec.validName(value)
    }

    static func validToolIdentifier(_ value: Any?) -> String? {
        guard let value = validIdentifier(value),
              isStrictASCIIToolName(value) else {
            return nil
        }
        return value
    }

    static func exactMappedTarget(
        for flatName: String,
        in mapping: CustomResponsesNamespaceMapping
    ) -> CustomResponsesNamespaceTarget? {
        guard isStrictASCIIToolName(flatName) else { return nil }
        let flatBytes = Data(flatName.utf8)
        guard let matchedEntry = mapping.first(where: { Data($0.key.utf8) == flatBytes }) else {
            return nil
        }
        let target = matchedEntry.value
        guard isStrictASCIIToolName(target.namespace),
              isStrictASCIIToolName(target.name) else {
            return nil
        }
        let expectedFlat = "\(target.namespace)\(namespaceSeparator)\(target.name)"
        guard Data(expectedFlat.utf8) == flatBytes else {
            return nil
        }
        return target
    }

    static func exactAllowedTool(
        _ candidate: String,
        in allowedTools: Set<String>
    ) -> Bool {
        guard isStrictASCIIToolName(candidate) else { return false }
        let candidateBytes = Data(candidate.utf8)
        return allowedTools.contains(where: { isStrictASCIIToolName($0) && Data($0.utf8) == candidateBytes })
    }

    static func validatedArguments(_ item: [String: Any], required: Bool) throws -> String {
        let hasArguments = item.index(forKey: "arguments") != nil
        let hasInput = item.index(forKey: "input") != nil
        if !hasArguments && !hasInput {
            if required { throw CustomResponsesFailure.invalidResponse }
            return ""
        }
        var resolved: String?
        if hasArguments {
            guard let value = item["arguments"] as? String,
                  value.utf8.count <= LMStudioWireCodec.maximumArgumentBytes else {
                throw CustomResponsesFailure.invalidResponse
            }
            resolved = value
        }
        if hasInput {
            guard let value = item["input"] as? String,
                  value.utf8.count <= LMStudioWireCodec.maximumArgumentBytes else {
                throw CustomResponsesFailure.invalidResponse
            }
            if let first = resolved {
                guard Data(first.utf8) == Data(value.utf8) else {
                    throw CustomResponsesFailure.invalidResponse
                }
            } else {
                resolved = value
            }
        }
        guard let result = resolved else {
            throw CustomResponsesFailure.invalidResponse
        }
        return result
    }

    static func validateRawCallItem(
        _ item: [String: Any],
        mapping: CustomResponsesNamespaceMapping,
        requireArguments: Bool
    ) throws -> (name: String, rawNamespace: String?, arguments: String) {
        guard let name = validToolIdentifier(item["name"]) else {
            throw CustomResponsesFailure.invalidResponse
        }
        let rawNamespace: String?
        if item.index(forKey: "namespace") != nil {
            guard let explicitNS = validToolIdentifier(item["namespace"]) else {
                throw CustomResponsesFailure.invalidResponse
            }
            if let target = exactMappedTarget(for: name, in: mapping) {
                guard Data(explicitNS.utf8) == Data(target.namespace.utf8) else {
                    throw CustomResponsesFailure.invalidResponse
                }
            } else {
                let flatCandidate = "\(explicitNS)\(namespaceSeparator)\(name)"
                guard exactMappedTarget(for: flatCandidate, in: mapping)
                        == CustomResponsesNamespaceTarget(namespace: explicitNS, name: name) else {
                    throw CustomResponsesFailure.invalidResponse
                }
            }
            rawNamespace = explicitNS
        } else {
            rawNamespace = nil
        }
        let arguments = try validatedArguments(item, required: requireArguments)
        return (name, rawNamespace, arguments)
    }

    static func validateRawOutputItems(
        _ output: [[String: Any]],
        mapping: CustomResponsesNamespaceMapping
    ) throws {
        for item in output {
            guard let type = validIdentifier(item["type"]) else {
                throw CustomResponsesFailure.invalidResponse
            }
            if type == "function_call" || type == "custom_tool_call" {
                _ = try validateRawCallItem(item, mapping: mapping, requireArguments: true)
            }
        }
    }

    private static func canonicalJSONBytes(_ value: Any?) -> Data? {
        guard let value else { return Data() }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return data
    }

    private static func mergedNamespaceDescription(namespaceDescription: String, innerDescription: String) -> String {
        let nsDesc = namespaceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let fnDesc = innerDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nsDesc.isEmpty && !fnDesc.isEmpty {
            return "\(nsDesc) — \(fnDesc)"
        } else if !nsDesc.isEmpty {
            return nsDesc
        }
        return innerDescription
    }

    private static func functionDeclarationsAreCompatible(
        existing: [String: Any],
        candidate: [String: Any],
        allowedDescriptions: Set<Data>
    ) -> Bool {
        guard (existing["type"] as? String) == "function",
              (candidate["type"] as? String) == "function",
              let existingName = validToolIdentifier(existing["name"]),
              let candidateName = validToolIdentifier(candidate["name"]),
              Data(existingName.utf8) == Data(candidateName.utf8) else {
            return false
        }
        if existing.index(forKey: "strict") != nil, (existing["strict"] as? Bool) != false {
            return false
        }
        if candidate.index(forKey: "strict") != nil, (candidate["strict"] as? Bool) != false {
            return false
        }
        guard let existingParams = canonicalJSONBytes(existing["parameters"]),
              let candidateParams = canonicalJSONBytes(candidate["parameters"]),
              existingParams == candidateParams else {
            return false
        }
        let existingDesc = ((existing["description"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return allowedDescriptions.contains(Data(existingDesc.utf8))
    }

    static func validateAndRewriteRequestObject(
        _ raw: [String: Any]
    ) throws -> (object: [String: Any], mapping: CustomResponsesNamespaceMapping) {
        var root = raw
        var mapping: CustomResponsesNamespaceMapping = [:]
        var toolIndexByName: [Data: Int] = [:]
        var namespaceInnerDescByFlatName: [Data: Data] = [:]

        if root.index(forKey: "tools") != nil {
            guard let tools = root["tools"] as? [[String: Any]] else {
                throw CustomResponsesFailure.invalidResponse
            }
            var flatTools: [[String: Any]] = []
            for tool in tools {
                guard let type = validIdentifier(tool["type"]) else {
                    throw CustomResponsesFailure.invalidResponse
                }
                switch type {
                case "namespace":
                    guard let ns = validToolIdentifier(tool["name"]),
                          let inner = tool["tools"] as? [[String: Any]] else {
                        throw CustomResponsesFailure.invalidResponse
                    }
                    if tool.index(forKey: "description") != nil, !(tool["description"] is String) {
                        throw CustomResponsesFailure.invalidResponse
                    }
                    let rawNSDesc = (tool["description"] as? String) ?? ""
                    let nsDesc = rawNSDesc.trimmingCharacters(in: .whitespacesAndNewlines)
                    for var fn in inner {
                        guard let fnType = validIdentifier(fn["type"]),
                              fnType == "function",
                              let name = validToolIdentifier(fn["name"]) else {
                            throw CustomResponsesFailure.invalidResponse
                        }
                        if fn.index(forKey: "namespace") != nil {
                            guard let fnNS = validToolIdentifier(fn["namespace"]),
                                  Data(fnNS.utf8) == Data(ns.utf8) else {
                                throw CustomResponsesFailure.invalidResponse
                            }
                        }
                        if fn.index(forKey: "description") != nil, !(fn["description"] is String) {
                            throw CustomResponsesFailure.invalidResponse
                        }
                        if fn.index(forKey: "parameters") != nil {
                            guard let params = fn["parameters"] as? [String: Any],
                                  (params["type"] as? String) == "object",
                                  canonicalJSONBytes(params) != nil else {
                                throw CustomResponsesFailure.invalidResponse
                            }
                        }
                        let flatName = "\(ns)\(namespaceSeparator)\(name)"
                        guard isStrictASCIIToolName(flatName) else {
                            throw CustomResponsesFailure.invalidResponse
                        }
                        let flatBytes = Data(flatName.utf8)
                        let target = CustomResponsesNamespaceTarget(namespace: ns, name: name)
                        if let existingTarget = exactMappedTarget(for: flatName, in: mapping), existingTarget != target {
                            throw CustomResponsesFailure.invalidResponse
                        }
                        let rawInnerDesc = (fn["description"] as? String) ?? ""
                        let innerDesc = rawInnerDesc.trimmingCharacters(in: .whitespacesAndNewlines)
                        let mergedDesc = mergedNamespaceDescription(
                            namespaceDescription: rawNSDesc,
                            innerDescription: rawInnerDesc
                        )
                        let trimmedMergedDesc = mergedDesc.trimmingCharacters(in: .whitespacesAndNewlines)
                        fn["name"] = flatName
                        fn.removeValue(forKey: "namespace")
                        if !nsDesc.isEmpty {
                            fn["description"] = mergedDesc
                        }
                        fn["strict"] = false
                        let allowedDescs: Set<Data> = [Data(innerDesc.utf8), Data(trimmedMergedDesc.utf8)]
                        if let existingIdx = toolIndexByName[flatBytes] {
                            if let prevInnerDesc = namespaceInnerDescByFlatName[flatBytes] {
                                guard prevInnerDesc == Data(innerDesc.utf8),
                                      functionDeclarationsAreCompatible(
                                          existing: flatTools[existingIdx],
                                          candidate: fn,
                                          allowedDescriptions: [Data(trimmedMergedDesc.utf8)]
                                      ) else {
                                    throw CustomResponsesFailure.invalidResponse
                                }
                            } else {
                                guard functionDeclarationsAreCompatible(
                                    existing: flatTools[existingIdx],
                                    candidate: fn,
                                    allowedDescriptions: allowedDescs
                                ) else {
                                    throw CustomResponsesFailure.invalidResponse
                                }
                                flatTools[existingIdx] = fn
                                namespaceInnerDescByFlatName[flatBytes] = Data(innerDesc.utf8)
                            }
                        } else {
                            toolIndexByName[flatBytes] = flatTools.count
                            namespaceInnerDescByFlatName[flatBytes] = Data(innerDesc.utf8)
                            flatTools.append(fn)
                        }
                        mapping[flatName] = target
                    }
                case "function", "custom":
                    guard let name = validToolIdentifier(tool["name"]),
                          tool.index(forKey: "namespace") == nil else {
                        throw CustomResponsesFailure.invalidResponse
                    }
                    if tool.index(forKey: "description") != nil, !(tool["description"] is String) {
                        throw CustomResponsesFailure.invalidResponse
                    }
                    if type == "function", tool.index(forKey: "parameters") != nil {
                        guard let params = tool["parameters"] as? [String: Any],
                              (params["type"] as? String) == "object",
                              canonicalJSONBytes(params) != nil else {
                            throw CustomResponsesFailure.invalidResponse
                        }
                    }
                    let nameBytes = Data(name.utf8)
                    if let existingIdx = toolIndexByName[nameBytes] {
                        guard type == "function",
                              let innerDescBytes = namespaceInnerDescByFlatName[nameBytes] else {
                            throw CustomResponsesFailure.invalidResponse
                        }
                        let existingMergedDesc = ((flatTools[existingIdx]["description"] as? String) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let allowedDescs: Set<Data> = [innerDescBytes, Data(existingMergedDesc.utf8)]
                        guard functionDeclarationsAreCompatible(
                            existing: tool,
                            candidate: flatTools[existingIdx],
                            allowedDescriptions: allowedDescs
                        ) else {
                            throw CustomResponsesFailure.invalidResponse
                        }
                    } else {
                        toolIndexByName[nameBytes] = flatTools.count
                        flatTools.append(tool)
                    }
                default:
                    // Drop OpenAI server-side-only tool types (web_search, file_search, computer_use_preview, etc.).
                    continue
                }
            }
            root["tools"] = flatTools
        }

        // Strip OpenAI-only encrypted reasoning fields rejected by third-party Responses endpoints.
        root.removeValue(forKey: "include")

        let mappedKeyBytes = Set(mapping.keys.map { Data($0.utf8) })
        let plainOnlyToolNames = Set(toolIndexByName.keys).subtracting(mappedKeyBytes)
        if root.index(forKey: "input") != nil {
            guard let input = root["input"] as? [[String: Any]] else {
                throw CustomResponsesFailure.invalidResponse
            }
            var rewrittenInput: [[String: Any]] = []
            for var item in input {
                guard let type = validIdentifier(item["type"]) ?? (item["role"] is String ? "message" : nil) else {
                    throw CustomResponsesFailure.invalidResponse
                }
                if type == "reasoning" {
                    continue
                }
                if type == "function_call" || type == "custom_tool_call" {
                    guard let name = validToolIdentifier(item["name"]) else {
                        throw CustomResponsesFailure.invalidResponse
                    }
                    _ = try validatedArguments(item, required: true)
                    if item.index(forKey: "namespace") != nil {
                        guard let ns = validToolIdentifier(item["namespace"]),
                              exactMappedTarget(for: name, in: mapping) == nil else {
                            throw CustomResponsesFailure.invalidResponse
                        }
                        let flatName = "\(ns)\(namespaceSeparator)\(name)"
                        guard isStrictASCIIToolName(flatName),
                              !plainOnlyToolNames.contains(Data(flatName.utf8)) else {
                            throw CustomResponsesFailure.invalidResponse
                        }
                        let target = CustomResponsesNamespaceTarget(namespace: ns, name: name)
                        if let existing = exactMappedTarget(for: flatName, in: mapping), existing != target {
                            throw CustomResponsesFailure.invalidResponse
                        }
                        item["name"] = flatName
                        item.removeValue(forKey: "namespace")
                        mapping[flatName] = target
                    }
                }
                if (type == "function_call_output" || type == "custom_tool_call_output"),
                   let parts = item["output"] as? [[String: Any]] {
                    let (textSummary, imageParts) = splitToolOutputParts(parts)
                    item["output"] = textSummary
                    rewrittenInput.append(item)
                    if !imageParts.isEmpty {
                        var userContent: [[String: Any]] = [
                            ["type": "input_text", "text": "(screenshot returned by the tool call above:)"]
                        ]
                        userContent.append(contentsOf: imageParts)
                        rewrittenInput.append([
                            "role": "user",
                            "content": userContent
                        ])
                    }
                    continue
                }
                rewrittenInput.append(item)
            }
            root["input"] = pruneStaleImages(rewrittenInput)
        }

        return (root, mapping)
    }

    static func rewriteRequestData(_ body: Data) throws -> (body: Data, mapping: CustomResponsesNamespaceMapping) {
        guard body.count <= LMStudioWireCodec.maximumInputBytes else {
            throw CustomResponsesFailure.responseTooLarge
        }
        guard let raw = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw CustomResponsesFailure.invalidResponse
        }
        let (rewritten, mapping) = try validateAndRewriteRequestObject(raw)
        guard JSONSerialization.isValidJSONObject(rewritten),
              let data = try? JSONSerialization.data(withJSONObject: rewritten) else {
            throw CustomResponsesFailure.invalidResponse
        }
        guard data.count <= LMStudioWireCodec.maximumInputBytes else {
            throw CustomResponsesFailure.responseTooLarge
        }
        return (data, mapping)
    }

    static func rewriteRequestObject(_ raw: [String: Any]) -> (object: [String: Any], mapping: CustomResponsesNamespaceMapping) {
        if let valid = try? validateAndRewriteRequestObject(raw) {
            return valid
        }
        var root = raw
        var mapping: CustomResponsesNamespaceMapping = [:]

        if let tools = root["tools"] as? [[String: Any]] {
            var flatTools: [[String: Any]] = []
            for tool in tools {
                let type = tool["type"] as? String ?? ""
                switch type {
                case "namespace":
                    guard let ns = validToolIdentifier(tool["name"]),
                          let inner = tool["tools"] as? [[String: Any]] else { continue }
                    let nsDesc = (tool["description"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    for var fn in inner where (fn["type"] as? String) == "function" {
                        guard let name = validToolIdentifier(fn["name"]) else { continue }
                        if fn.index(forKey: "namespace") != nil {
                            guard let fnNS = validToolIdentifier(fn["namespace"]),
                                  Data(fnNS.utf8) == Data(ns.utf8) else { continue }
                        }
                        let flatName = "\(ns)\(namespaceSeparator)\(name)"
                        guard isStrictASCIIToolName(flatName) else { continue }
                        let target = CustomResponsesNamespaceTarget(namespace: ns, name: name)
                        if let existing = exactMappedTarget(for: flatName, in: mapping), existing != target { continue }
                        mapping[flatName] = target
                        fn["name"] = flatName
                        fn.removeValue(forKey: "namespace")
                        let innerDesc = (fn["description"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !nsDesc.isEmpty && !innerDesc.isEmpty {
                            fn["description"] = "\(nsDesc) — \(innerDesc)"
                        } else if !nsDesc.isEmpty {
                            fn["description"] = nsDesc
                        }
                        fn["strict"] = false
                        flatTools.append(fn)
                    }
                case "function", "custom":
                    guard validToolIdentifier(tool["name"]) != nil,
                          tool.index(forKey: "namespace") == nil else { continue }
                    flatTools.append(tool)
                default:
                    continue
                }
            }
            root["tools"] = flatTools
        }

        root.removeValue(forKey: "include")

        if let input = root["input"] as? [[String: Any]] {
            var rewrittenInput: [[String: Any]] = []
            for var item in input {
                let type = item["type"] as? String ?? ""
                if type == "reasoning" {
                    continue
                }
                if (type == "function_call" || type == "custom_tool_call"),
                   item.index(forKey: "namespace") != nil {
                    if let ns = validToolIdentifier(item["namespace"]),
                       let name = validToolIdentifier(item["name"]),
                       exactMappedTarget(for: name, in: mapping) == nil,
                       (try? validatedArguments(item, required: false)) != nil {
                        let flatName = "\(ns)\(namespaceSeparator)\(name)"
                        if isStrictASCIIToolName(flatName) {
                            let target = CustomResponsesNamespaceTarget(namespace: ns, name: name)
                            if let existing = exactMappedTarget(for: flatName, in: mapping), existing != target {
                                // Keep contradictory item untouched rather than overwriting mapping.
                            } else {
                                item["name"] = flatName
                                item.removeValue(forKey: "namespace")
                                mapping[flatName] = target
                            }
                        }
                    }
                }
                if (type == "function_call_output" || type == "custom_tool_call_output"),
                   let parts = item["output"] as? [[String: Any]] {
                    let (textSummary, imageParts) = splitToolOutputParts(parts)
                    item["output"] = textSummary
                    rewrittenInput.append(item)
                    if !imageParts.isEmpty {
                        var userContent: [[String: Any]] = [
                            ["type": "input_text", "text": "(screenshot returned by the tool call above:)"]
                        ]
                        userContent.append(contentsOf: imageParts)
                        rewrittenInput.append([
                            "role": "user",
                            "content": userContent
                        ])
                    }
                    continue
                }
                rewrittenInput.append(item)
            }
            root["input"] = pruneStaleImages(rewrittenInput)
        }

        return (root, mapping)
    }

    static func splitToolOutputParts(_ parts: [[String: Any]]) -> (text: String, images: [[String: Any]]) {
        var texts: [String] = []
        var images: [[String: Any]] = []
        for part in parts {
            switch part["type"] as? String ?? "" {
            case "input_text", "output_text", "text":
                if let text = part["text"] as? String {
                    texts.append(text)
                }
            case "input_image":
                images.append(part)
            default:
                if let data = try? JSONSerialization.data(withJSONObject: part),
                   let str = String(data: data, encoding: .utf8) {
                    texts.append(str)
                }
            }
        }
        if !images.isEmpty {
            let note = images.count == 1
                ? "(the tool also returned a screenshot, attached in the next message)"
                : "(the tool also returned \(images.count) screenshots, attached in the next message)"
            texts.append(note)
        }
        return (texts.joined(separator: "\n"), images)
    }

    static func pruneStaleImages(_ items: [[String: Any]]) -> [[String: Any]] {
        var lastItemWithImage: Int?
        for (idx, item) in items.enumerated() {
            if let content = item["content"] as? [[String: Any]],
               content.contains(where: { ($0["type"] as? String) == "input_image" }) {
                lastItemWithImage = idx
            }
        }
        guard let keepIndex = lastItemWithImage else { return items }
        var result = items
        for idx in 0..<keepIndex {
            guard let content = result[idx]["content"] as? [[String: Any]] else { continue }
            var stripped: [[String: Any]] = []
            var dropped = false
            for part in content {
                if (part["type"] as? String) == "input_image" {
                    dropped = true
                    stripped.append([
                        "type": "input_text",
                        "text": "(an older screenshot was here; omitted — only the newest screenshot is kept)"
                    ])
                } else {
                    stripped.append(part)
                }
            }
            if dropped {
                result[idx]["content"] = stripped
            }
        }
        return result
    }

    static func unflattenResponseItem(_ item: [String: Any], mapping: CustomResponsesNamespaceMapping) -> [String: Any] {
        guard !mapping.isEmpty else { return item }
        guard let type = validIdentifier(item["type"]),
              type == "function_call" || type == "custom_tool_call",
              let flatName = validToolIdentifier(item["name"]),
              let target = exactMappedTarget(for: flatName, in: mapping) else {
            return item
        }
        if item.index(forKey: "namespace") != nil {
            guard let explicitNS = validToolIdentifier(item["namespace"]),
                  Data(explicitNS.utf8) == Data(target.namespace.utf8) else {
                return item
            }
        }
        if item.index(forKey: "arguments") != nil || item.index(forKey: "input") != nil {
            guard (try? validatedArguments(item, required: false)) != nil else {
                return item
            }
        }
        var copy = item
        copy["name"] = target.name
        copy["namespace"] = target.namespace
        return copy
    }

    static func rewriteResponseObject(_ obj: [String: Any], mapping: CustomResponsesNamespaceMapping) -> [String: Any] {
        guard !mapping.isEmpty else { return obj }
        var root = obj
        var mutated = false

        if let item = root["item"] as? [String: Any] {
            let updated = unflattenResponseItem(item, mapping: mapping)
            if (updated["name"] as? String) != (item["name"] as? String)
                || (updated["namespace"] as? String) != (item["namespace"] as? String) {
                root["item"] = updated
                mutated = true
            }
        }
        if var response = root["response"] as? [String: Any],
           let output = response["output"] as? [[String: Any]] {
            let updatedOutput = output.map { unflattenResponseItem($0, mapping: mapping) }
            response["output"] = updatedOutput
            root["response"] = response
            mutated = true
        }
        if let output = root["output"] as? [[String: Any]] {
            root["output"] = output.map { unflattenResponseItem($0, mapping: mapping) }
            mutated = true
        }
        return mutated ? root : obj
    }

    static func rewriteSSEDataLine(_ line: String, mapping: CustomResponsesNamespaceMapping) -> String {
        guard !mapping.isEmpty, line.hasPrefix("data: ") else { return line }
        let jsonPart = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard !jsonPart.isEmpty, jsonPart != "[DONE]",
              let rawData = jsonPart.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            return line
        }
        let rewritten = rewriteResponseObject(obj, mapping: mapping)
        guard let outData = try? JSONSerialization.data(withJSONObject: rewritten),
              let outText = String(data: outData, encoding: .utf8) else {
            return line
        }
        return "data: " + outText
    }

    nonisolated struct SSELineBuffer: Sendable {
        let mapping: CustomResponsesNamespaceMapping
        private var pending = Data()

        init(mapping: CustomResponsesNamespaceMapping) {
            self.mapping = mapping
        }

        mutating func push(_ chunk: Data) -> Data {
            pending.append(chunk)
            var out = Data()
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: 0..<nl)
                pending.removeSubrange(0...nl)
                emitLine(lineData, into: &out, appendNewline: true)
            }
            return out
        }

        mutating func flush() -> Data {
            guard !pending.isEmpty else { return Data() }
            let rest = pending
            pending.removeAll()
            var out = Data()
            emitLine(rest, into: &out, appendNewline: false)
            return out
        }

        private func emitLine(_ lineData: Data, into out: inout Data, appendNewline: Bool) {
            var stripped = lineData
            let hadCR = stripped.last == 0x0D
            if hadCR { stripped.removeLast() }
            if let text = String(data: stripped, encoding: .utf8) {
                let rewritten = CustomResponsesTranslator.rewriteSSEDataLine(text, mapping: mapping)
                if let rewrittenBytes = rewritten.data(using: .utf8) {
                    out.append(rewrittenBytes)
                } else {
                    out.append(stripped)
                }
            } else {
                out.append(stripped)
            }
            if hadCR { out.append(0x0D) }
            if appendNewline { out.append(0x0A) }
        }
    }
}

nonisolated enum CustomResponsesWireCodec {
    static func models(from data: Data) throws -> [String] {
        guard data.count <= LMStudioWireCodec.maximumOutputBytes else {
            throw CustomResponsesFailure.responseTooLarge
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let models) = value.object?["data"],
              models.count <= 2_048 else {
            throw CustomResponsesFailure.invalidResponse
        }
        let names = try models.map { item -> String in
            guard let id = item.object?["id"]?.string else {
                throw CustomResponsesFailure.invalidResponse
            }
            return try CustomResponsesConfiguration.validatedModelID(id)
        }
        guard !names.isEmpty else {
            throw CustomResponsesFailure.emptyModelList
        }
        guard Set(names.map { LMStudioProtocolID($0) }).count == names.count else {
            throw CustomResponsesFailure.invalidResponse
        }
        return names
    }

    static func priorToolCallIDs(in messages: [ModelMessage]) -> Set<LMStudioProtocolID> {
        Set(messages.flatMap(\.toolCalls).map { LMStudioProtocolID($0.id) })
    }

    static func request(
        model: String,
        reasoningEffort: String = CustomResponsesConfiguration.defaultReasoningEffort,
        messages: [ModelMessage],
        tools: [ToolDefinition],
        namespaces: [CustomResponsesNamespaceDefinition] = [],
        image: Data? = nil,
        imageAnnotation: String? = nil,
        stream: Bool = true
    ) throws -> (data: Data, mapping: CustomResponsesNamespaceMapping) {
        let validModel = try CustomResponsesConfiguration.validatedModelID(model)
        let validEffort = try CustomResponsesConfiguration.validatedReasoningEffort(reasoningEffort)
        if let image {
            guard !image.isEmpty, image.count <= LMStudioVisionAttachment.maximumJPEGBytes,
                  let annotation = imageAnnotation, annotation.utf8.count <= 2_048 else {
                throw CustomResponsesFailure.invalidResponse
            }
        }

        let history: [ModelMessage]
        do {
            history = try LMStudioWireCodec.canonicalHistory(messages)
        } catch LMStudioFailure.inputLimit {
            throw CustomResponsesFailure.responseTooLarge
        } catch {
            throw CustomResponsesFailure.invalidResponse
        }

        guard tools.count <= 64, Set(tools.map { Data($0.name.utf8) }).count == tools.count,
              tools.allSatisfy({ CustomResponsesTranslator.validToolIdentifier($0.name) != nil && $0.parameters.object?["type"] == .string("object") }),
              namespaces.count <= 64, Set(namespaces.map { Data($0.name.utf8) }).count == namespaces.count,
              namespaces.allSatisfy({ CustomResponsesTranslator.validToolIdentifier($0.name) != nil }) else {
            throw CustomResponsesFailure.invalidResponse
        }

        var inputItems: [[String: Any]] = []
        var textAndToolBytes = validModel.utf8.count
        for message in history {
            textAndToolBytes += message.role.utf8.count + message.content.utf8.count
            guard textAndToolBytes <= LMStudioWireCodec.maximumInputBytes else {
                throw CustomResponsesFailure.responseTooLarge
            }
            switch message.role {
            case "system", "user":
                inputItems.append([
                    "type": "message",
                    "role": message.role,
                    "content": [
                        ["type": "input_text", "text": message.content]
                    ]
                ])
            case "assistant":
                let calls = message.toolCalls
                if !message.content.isEmpty || calls.isEmpty {
                    inputItems.append([
                        "type": "message",
                        "role": "assistant",
                        "content": [
                            ["type": "output_text", "text": message.content]
                        ]
                    ])
                }
                for call in calls {
                    guard CustomResponsesTranslator.validIdentifier(call.id) != nil,
                          CustomResponsesTranslator.validToolIdentifier(call.name) != nil,
                          let argData = try? LMStudioWireCodec.jsonData(.object(call.arguments)),
                          argData.count <= LMStudioWireCodec.maximumArgumentBytes else {
                        throw CustomResponsesFailure.invalidResponse
                    }
                    let argString = String(decoding: argData, as: UTF8.self)
                    textAndToolBytes += call.id.utf8.count + call.name.utf8.count + argData.count
                    guard textAndToolBytes <= LMStudioWireCodec.maximumInputBytes else {
                        throw CustomResponsesFailure.responseTooLarge
                    }
                    inputItems.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": argString
                    ])
                }
            case "tool":
                guard let id = CustomResponsesTranslator.validIdentifier(message.toolCallID) else {
                    throw CustomResponsesFailure.invalidResponse
                }
                inputItems.append([
                    "type": "function_call_output",
                    "call_id": id,
                    "output": message.content
                ])
            default:
                throw CustomResponsesFailure.invalidResponse
            }
        }

        if let image, let annotation = imageAnnotation {
            let trimmedAnnotation = annotation.trimmingCharacters(in: .whitespacesAndNewlines)
            var content: [[String: Any]] = []
            if !trimmedAnnotation.isEmpty {
                content.append(["type": "input_text", "text": trimmedAnnotation])
            }
            content.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(image.base64EncodedString())"
            ])
            inputItems.append([
                "type": "message",
                "role": "user",
                "content": content
            ])
        }

        var rawTools: [[String: Any]] = try tools.map { tool in
            guard let paramData = try? LMStudioWireCodec.jsonData(tool.parameters),
                  let paramObj = (try? JSONSerialization.jsonObject(with: paramData)) as? [String: Any] else {
                throw CustomResponsesFailure.invalidResponse
            }
            textAndToolBytes += tool.name.utf8.count + tool.description.utf8.count + paramData.count
            guard textAndToolBytes <= LMStudioWireCodec.maximumInputBytes else {
                throw CustomResponsesFailure.responseTooLarge
            }
            return [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": paramObj,
                "strict": false
            ]
        }
        for ns in namespaces {
            guard CustomResponsesTranslator.validToolIdentifier(ns.name) != nil,
                  ns.tools.count <= 64,
                  Set(ns.tools.map { Data($0.name.utf8) }).count == ns.tools.count else {
                throw CustomResponsesFailure.invalidResponse
            }
            let innerTools: [[String: Any]] = try ns.tools.map { tool in
                guard CustomResponsesTranslator.validToolIdentifier(tool.name) != nil,
                      tool.parameters.object?["type"] == .string("object"),
                      let paramData = try? LMStudioWireCodec.jsonData(tool.parameters),
                      let paramObj = (try? JSONSerialization.jsonObject(with: paramData)) as? [String: Any] else {
                    throw CustomResponsesFailure.invalidResponse
                }
                textAndToolBytes += ns.name.utf8.count + tool.name.utf8.count + tool.description.utf8.count + paramData.count
                guard textAndToolBytes <= LMStudioWireCodec.maximumInputBytes else {
                    throw CustomResponsesFailure.responseTooLarge
                }
                return [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": paramObj,
                    "strict": false
                ]
            }
            rawTools.append([
                "type": "namespace",
                "name": ns.name,
                "description": ns.description,
                "tools": innerTools
            ])
        }

        var payload: [String: Any] = [
            "model": validModel,
            "input": inputItems,
            "temperature": 0.15,
            "max_output_tokens": 1536,
            "stream": stream
        ]
        if validEffort != "none" {
            payload["reasoning"] = ["effort": validEffort]
        }
        if !rawTools.isEmpty {
            payload["tools"] = rawTools
            payload["tool_choice"] = "auto"
        }

        let (rewritten, mapping) = try CustomResponsesTranslator.validateAndRewriteRequestObject(payload)
        var finalObject = rewritten
        if let finalTools = finalObject["tools"] as? [[String: Any]], finalTools.isEmpty {
            finalObject.removeValue(forKey: "tools")
            finalObject.removeValue(forKey: "tool_choice")
        }
        return try serializePayload(finalObject, mapping: mapping, hasImage: image != nil)
    }

    private static func serializePayload(
        _ object: [String: Any],
        mapping: CustomResponsesNamespaceMapping,
        hasImage: Bool
    ) throws -> (data: Data, mapping: CustomResponsesNamespaceMapping) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw CustomResponsesFailure.invalidResponse
        }
        let maxBytes = hasImage
            ? LMStudioWireCodec.maximumInputBytes + 6 * 1_024 * 1_024
            : LMStudioWireCodec.maximumInputBytes
        guard data.count <= maxBytes else {
            throw CustomResponsesFailure.responseTooLarge
        }
        return (data, mapping)
    }

    static func reply(
        from data: Data,
        availableTools: Set<String>,
        priorCallIDs: Set<LMStudioProtocolID> = [],
        mapping: CustomResponsesNamespaceMapping = [:]
    ) throws -> ModelReply {
        guard data.count <= LMStudioWireCodec.maximumOutputBytes else {
            throw CustomResponsesFailure.responseTooLarge
        }
        guard let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CustomResponsesFailure.invalidResponse
        }
        if rawObject["error"] is [String: Any] {
            throw CustomResponsesFailure.requestRejected
        }
        let rawResponseObject = (rawObject["response"] as? [String: Any]) ?? rawObject

        if rawResponseObject["error"] is [String: Any] {
            throw CustomResponsesFailure.requestRejected
        }
        if rawResponseObject.index(forKey: "status") != nil {
            guard let status = rawResponseObject["status"] as? String, status == "completed" else {
                throw CustomResponsesFailure.invalidResponse
            }
        }
        guard let rawOutput = rawResponseObject["output"] as? [[String: Any]] else {
            throw CustomResponsesFailure.invalidResponse
        }
        try CustomResponsesTranslator.validateRawOutputItems(rawOutput, mapping: mapping)
        let output = rawOutput.map { CustomResponsesTranslator.unflattenResponseItem($0, mapping: mapping) }

        return try parseOutputItems(
            output,
            availableTools: availableTools,
            priorCallIDs: priorCallIDs,
            mapping: mapping,
            streamedText: ""
        )
    }

    fileprivate static func parseOutputItems(
        _ output: [[String: Any]],
        availableTools: Set<String>,
        priorCallIDs: Set<LMStudioProtocolID>,
        mapping: CustomResponsesNamespaceMapping = [:],
        streamedText: String
    ) throws -> ModelReply {
        var seenCallIDs = priorCallIDs
        var textParts: [String] = []
        var toolCalls: [ToolCall] = []

        for item in output {
            guard let type = CustomResponsesTranslator.validIdentifier(item["type"]) else {
                throw CustomResponsesFailure.invalidResponse
            }
            switch type {
            case "message":
                guard let content = item["content"] as? [[String: Any]] else {
                    throw CustomResponsesFailure.invalidResponse
                }
                for part in content {
                    let partType = part["type"] as? String ?? ""
                    if partType == "output_text" || partType == "text" {
                        guard let text = part["text"] as? String else {
                            throw CustomResponsesFailure.invalidResponse
                        }
                        textParts.append(text)
                    } else if partType == "refusal" {
                        if let refusal = part["refusal"] as? String {
                            textParts.append(refusal)
                        }
                    }
                }
            case "function_call", "custom_tool_call":
                guard toolCalls.count < LMStudioWireCodec.maximumCalls else {
                    throw CustomResponsesFailure.invalidResponse
                }
                let rawIDValue: Any?
                if item.index(forKey: "call_id") != nil {
                    rawIDValue = item["call_id"]
                } else {
                    rawIDValue = item["id"]
                }
                guard let id = CustomResponsesTranslator.validIdentifier(rawIDValue),
                      seenCallIDs.insert(LMStudioProtocolID(id)).inserted,
                      let rawName = CustomResponsesTranslator.validToolIdentifier(item["name"]) else {
                    throw CustomResponsesFailure.invalidResponse
                }
                let namespace: String
                if item.index(forKey: "namespace") != nil {
                    guard let explicitNS = CustomResponsesTranslator.validToolIdentifier(item["namespace"]) else {
                        throw CustomResponsesFailure.invalidResponse
                    }
                    namespace = explicitNS
                } else {
                    namespace = ""
                }
                let resolvedName = try resolveToolName(
                    rawName: rawName,
                    namespace: namespace,
                    allowedTools: availableTools,
                    mapping: mapping
                )
                let argString = try CustomResponsesTranslator.validatedArguments(item, required: true)
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(argString.utf8)),
                      let arguments = value.object else {
                    throw CustomResponsesFailure.invalidResponse
                }
                toolCalls.append(ToolCall(id: id, name: resolvedName, arguments: arguments))
            case "reasoning":
                continue
            default:
                continue
            }
        }

        let combinedText = !streamedText.isEmpty ? streamedText : textParts.joined()
        guard combinedText.utf8.count <= LMStudioWireCodec.maximumOutputBytes else {
            throw CustomResponsesFailure.responseTooLarge
        }
        guard !combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !toolCalls.isEmpty else {
            throw CustomResponsesFailure.invalidResponse
        }
        return ModelReply(content: combinedText, toolCalls: toolCalls)
    }

    fileprivate static func resolveToolName(
        rawName: String,
        namespace: String,
        allowedTools: Set<String>,
        mapping: CustomResponsesNamespaceMapping = [:]
    ) throws -> String {
        guard CustomResponsesTranslator.isStrictASCIIToolName(rawName) else {
            throw CustomResponsesFailure.invalidResponse
        }
        if !namespace.isEmpty {
            guard CustomResponsesTranslator.isStrictASCIIToolName(namespace) else {
                throw CustomResponsesFailure.invalidResponse
            }
            let flatCandidate = "\(namespace)\(CustomResponsesTranslator.namespaceSeparator)\(rawName)"
            guard CustomResponsesTranslator.exactMappedTarget(for: flatCandidate, in: mapping)
                    == CustomResponsesNamespaceTarget(namespace: namespace, name: rawName) else {
                throw CustomResponsesFailure.invalidResponse
            }
            if CustomResponsesTranslator.exactAllowedTool(flatCandidate, in: allowedTools) {
                return flatCandidate
            }
            if CustomResponsesTranslator.exactAllowedTool(rawName, in: allowedTools) {
                return rawName
            }
            throw CustomResponsesFailure.invalidResponse
        } else if CustomResponsesTranslator.exactAllowedTool(rawName, in: allowedTools) {
            return rawName
        }
        throw CustomResponsesFailure.invalidResponse
    }
}

nonisolated struct CustomResponsesSSEDecoder: Sendable {
    private struct PartialFunctionCall: Sendable {
        let itemID: String, callID: String, rawName: String, rawNamespace: String?, kind: String
        var arguments: String
        var hasDeltaArguments = false, argumentsDone = false, itemDone = false
    }
    private let availableTools: Set<String>
    private let priorCallIDs: Set<LMStudioProtocolID>
    private let mapping: CustomResponsesNamespaceMapping
    private var totalBytes = 0
    private var buffer = Data()
    private var eventLines: [String] = [], textParts: [String] = []
    private var callsByIndex: [Int: PartialFunctionCall] = [:]
    private var indexByItemID: [Data: Int] = [:], indexByCallID: [Data: Int] = [:]
    private var itemIDsByIndex: [Int: Data] = [:], itemTypesByIndex: [Int: Data] = [:]
    private var added = Set<Int>(), done = Set<Int>()
    private var responseID: Data?
    private var completedReply: ModelReply?
    private var sawEvent = false
    private(set) var sawCompleted = false

    init(availableTools: Set<String>, priorCallIDs: Set<LMStudioProtocolID> = [],
         mapping: CustomResponsesNamespaceMapping = [:]) {
        self.availableTools = availableTools; self.priorCallIDs = priorCallIDs; self.mapping = mapping
    }
    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= LMStudioWireCodec.maximumOutputBytes - totalBytes else { throw CustomResponsesFailure.responseTooLarge }
        totalBytes += chunk.count; buffer.append(chunk)
        guard buffer.count <= 256 * 1_024 else { throw CustomResponsesFailure.responseTooLarge }
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if lineData.last == 0x0D { lineData.removeLast() }
            guard let line = String(data: lineData, encoding: .utf8) else { throw CustomResponsesFailure.invalidResponse }
            try consume(line: line)
        }
    }
    mutating func finish() throws -> ModelReply {
        if !buffer.isEmpty {
            var lineData = buffer; buffer.removeAll()
            if lineData.last == 0x0D { lineData.removeLast() }
            guard let line = String(data: lineData, encoding: .utf8) else { throw CustomResponsesFailure.invalidResponse }
            try consume(line: line)
        }
        try flushEvent()
        guard sawEvent, sawCompleted, let completedReply else { throw CustomResponsesFailure.streamDisconnected }
        // Only the actual coherent terminal response grants dispatch data.
        // Partial calls/text never synthesize a result after completion.
        return completedReply
    }
    private mutating func consume(line: String) throws {
        if line.isEmpty { try flushEvent(); return }
        if line.hasPrefix(":") || line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") { return }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5)); if value.first == " " { value.removeFirst() }
            eventLines.append(value)
            guard eventLines.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1_024 else { throw CustomResponsesFailure.responseTooLarge }
        }
    }
    private static func identifier(_ value: Any?) throws -> String {
        guard let value = CustomResponsesTranslator.validIdentifier(value) else { throw CustomResponsesFailure.invalidResponse }
        return value
    }
    private static func index(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              (0..<LMStudioWireCodec.maximumCalls).contains(number.intValue),
              number.doubleValue == Double(number.intValue) else { throw CustomResponsesFailure.invalidResponse }
        return number.intValue
    }
    private mutating func bindResponse(_ value: Any?) throws {
        let bytes = Data(try Self.identifier(value).utf8)
        if let responseID { guard responseID == bytes else { throw CustomResponsesFailure.invalidResponse } }
        else { responseID = bytes }
    }
    private static func arguments(_ item: [String: Any], required: Bool) throws -> String {
        try CustomResponsesTranslator.validatedArguments(item, required: required)
    }
    private mutating func recordItem(_ object: [String: Any], isDone: Bool) throws {
        let index = try Self.index(object["output_index"])
        guard let item = object["item"] as? [String: Any],
              let kind = CustomResponsesTranslator.validIdentifier(item["type"]) else { throw CustomResponsesFailure.invalidResponse }
        if isDone { guard done.insert(index).inserted else { throw CustomResponsesFailure.invalidResponse } }
        else { guard added.insert(index).inserted, !done.contains(index) else { throw CustomResponsesFailure.invalidResponse } }
        let kindBytes = Data(kind.utf8)
        if let previous = itemTypesByIndex[index] { guard previous == kindBytes else { throw CustomResponsesFailure.invalidResponse } }
        itemTypesByIndex[index] = kindBytes
        if item.index(forKey: "id") != nil {
            let id = Data(try Self.identifier(item["id"]).utf8)
            if let previous = itemIDsByIndex[index] { guard previous == id else { throw CustomResponsesFailure.invalidResponse } }
            if let previous = indexByItemID[id] { guard previous == index else { throw CustomResponsesFailure.invalidResponse } }
            itemIDsByIndex[index] = id; indexByItemID[id] = index
        }
        guard kind == "function_call" || kind == "custom_tool_call" else { return }
        let itemID = try Self.identifier(item["id"]), callID = try Self.identifier(item["call_id"])
        let (rawName, rawNamespace, args) = try CustomResponsesTranslator.validateRawCallItem(
            item,
            mapping: mapping,
            requireArguments: isDone
        )
        if let other = indexByCallID[Data(callID.utf8)] { guard other == index else { throw CustomResponsesFailure.invalidResponse } }
        indexByCallID[Data(callID.utf8)] = index
        if var previous = callsByIndex[index] {
            guard isDone, !previous.itemDone,
                  Data(previous.itemID.utf8) == Data(itemID.utf8),
                  Data(previous.callID.utf8) == Data(callID.utf8),
                  Data(previous.rawName.utf8) == Data(rawName.utf8),
                  previous.rawNamespace.map({ Data($0.utf8) }) == rawNamespace.map({ Data($0.utf8) }),
                  Data(previous.kind.utf8) == kindBytes else { throw CustomResponsesFailure.invalidResponse }
            if previous.hasDeltaArguments || previous.argumentsDone || !previous.arguments.isEmpty {
                guard Data(previous.arguments.utf8) == Data(args.utf8) else { throw CustomResponsesFailure.invalidResponse }
            }
            previous.arguments = args; previous.itemDone = true; callsByIndex[index] = previous
        } else {
            var partial = PartialFunctionCall(
                itemID: itemID,
                callID: callID,
                rawName: rawName,
                rawNamespace: rawNamespace,
                kind: kind,
                arguments: args
            )
            partial.itemDone = isDone; callsByIndex[index] = partial
        }
    }
    private func resolveCallIndex(from object: [String: Any]) throws -> Int {
        let id = Data(try Self.identifier(object["item_id"]).utf8)
        guard let index = indexByItemID[id], let call = callsByIndex[index], Data(call.itemID.utf8) == id else { throw CustomResponsesFailure.invalidResponse }
        if object.index(forKey: "output_index") != nil {
            guard try Self.index(object["output_index"]) == index else { throw CustomResponsesFailure.invalidResponse }
        }
        if object.index(forKey: "call_id") != nil {
            let callID = try Self.identifier(object["call_id"])
            guard Data(callID.utf8) == Data(call.callID.utf8) else { throw CustomResponsesFailure.invalidResponse }
        }
        if object.index(forKey: "name") != nil {
            guard let rawName = CustomResponsesTranslator.validToolIdentifier(object["name"]),
                  Data(rawName.utf8) == Data(call.rawName.utf8) else { throw CustomResponsesFailure.invalidResponse }
        }
        if object.index(forKey: "namespace") != nil {
            guard let rawNamespace = CustomResponsesTranslator.validToolIdentifier(object["namespace"]),
                  let expectedNamespace = call.rawNamespace,
                  Data(rawNamespace.utf8) == Data(expectedNamespace.utf8) else { throw CustomResponsesFailure.invalidResponse }
        }
        return index
    }
    private mutating func complete(_ response: [String: Any]) throws {
        try bindResponse(response["id"])
        guard response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else { throw CustomResponsesFailure.invalidResponse }
        var seenIDs = Set<Data>(), seenCallIDs = Set<Data>()
        for (index, item) in output.enumerated() {
            guard let kind = CustomResponsesTranslator.validIdentifier(item["type"]) else { throw CustomResponsesFailure.invalidResponse }
            if let previous = itemTypesByIndex[index] { guard previous == Data(kind.utf8) else { throw CustomResponsesFailure.invalidResponse } }
            if item.index(forKey: "id") != nil {
                let id = Data(try Self.identifier(item["id"]).utf8)
                guard seenIDs.insert(id).inserted else { throw CustomResponsesFailure.invalidResponse }
                if let other = indexByItemID[id] { guard other == index else { throw CustomResponsesFailure.invalidResponse } }
                if let original = itemIDsByIndex[index] { guard original == id else { throw CustomResponsesFailure.invalidResponse } }
            } else if itemIDsByIndex[index] != nil { throw CustomResponsesFailure.invalidResponse }
            if kind == "function_call" || kind == "custom_tool_call" {
                let itemID = try Self.identifier(item["id"]), callID = try Self.identifier(item["call_id"])
                let (rawName, rawNamespace, args) = try CustomResponsesTranslator.validateRawCallItem(
                    item,
                    mapping: mapping,
                    requireArguments: true
                )
                guard seenCallIDs.insert(Data(callID.utf8)).inserted else { throw CustomResponsesFailure.invalidResponse }
                if let other = indexByCallID[Data(callID.utf8)] { guard other == index else { throw CustomResponsesFailure.invalidResponse } }
                if let partial = callsByIndex[index] {
                    guard Data(partial.itemID.utf8) == Data(itemID.utf8),
                          Data(partial.callID.utf8) == Data(callID.utf8),
                          Data(partial.kind.utf8) == Data(kind.utf8),
                          Data(partial.rawName.utf8) == Data(rawName.utf8),
                          partial.rawNamespace.map({ Data($0.utf8) }) == rawNamespace.map({ Data($0.utf8) }),
                          Data(partial.arguments.utf8) == Data(args.utf8) else { throw CustomResponsesFailure.invalidResponse }
                }
            } else if callsByIndex[index] != nil { throw CustomResponsesFailure.invalidResponse }
        }
        // No earlier partial may disappear or move in the completed array.
        guard callsByIndex.keys.allSatisfy({ $0 < output.count }), itemTypesByIndex.keys.allSatisfy({ $0 < output.count }) else { throw CustomResponsesFailure.invalidResponse }
        let normalizedOutput = output.map { CustomResponsesTranslator.unflattenResponseItem($0, mapping: mapping) }
        let reply = try CustomResponsesWireCodec.parseOutputItems(
            normalizedOutput,
            availableTools: availableTools,
            priorCallIDs: priorCallIDs,
            mapping: mapping,
            streamedText: ""
        )
        let streamed = textParts.joined()
        guard streamed.isEmpty || Data(streamed.utf8) == Data(reply.content.utf8) else { throw CustomResponsesFailure.invalidResponse }
        completedReply = reply; sawCompleted = true
    }
    private mutating func flushEvent() throws {
        guard !eventLines.isEmpty else { return }
        let payload = eventLines.joined(separator: "\n"); eventLines.removeAll(keepingCapacity: true)
        if payload == "[DONE]" { guard sawCompleted else { throw CustomResponsesFailure.streamDisconnected }; return }
        guard !sawCompleted, let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CustomResponsesFailure.invalidResponse }
        if object["error"] is [String: Any] { throw CustomResponsesFailure.requestRejected }
        if object.index(forKey: "response_id") != nil { try bindResponse(object["response_id"]) }
        sawEvent = true
        switch object["type"] as? String ?? "" {
        case "response.created", "response.in_progress":
            guard let response = object["response"] as? [String: Any] else { throw CustomResponsesFailure.invalidResponse }
            try bindResponse(response["id"])
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else { throw CustomResponsesFailure.invalidResponse }; textParts.append(delta)
        case "response.output_text.done":
            guard let text = object["text"] as? String else { throw CustomResponsesFailure.invalidResponse }
            // A done event can describe one content part, not all previous
            // message parts. The whole accumulated text is reconciled only
            // against the complete terminal output below.
            if textParts.isEmpty { textParts.append(text) }
        case "response.output_item.added", "response.output_item.done":
            try recordItem(object, isDone: object["type"] as? String == "response.output_item.done")
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            let index = try resolveCallIndex(from: object)
            guard var call = callsByIndex[index], !call.itemDone, !call.argumentsDone else { throw CustomResponsesFailure.invalidResponse }
            if object["type"] as? String == "response.function_call_arguments.delta" {
                guard let delta = object["delta"] as? String, call.hasDeltaArguments || call.arguments.isEmpty else { throw CustomResponsesFailure.invalidResponse }
                call.hasDeltaArguments = true; call.arguments += delta
            } else {
                let args = try Self.arguments(object, required: true)
                if call.hasDeltaArguments || !call.arguments.isEmpty { guard Data(call.arguments.utf8) == Data(args.utf8) else { throw CustomResponsesFailure.invalidResponse } }
                call.arguments = args; call.argumentsDone = true
            }
            guard call.arguments.utf8.count <= LMStudioWireCodec.maximumArgumentBytes else { throw CustomResponsesFailure.invalidResponse }
            callsByIndex[index] = call
        case "response.completed":
            guard let response = object["response"] as? [String: Any] else { throw CustomResponsesFailure.invalidResponse }; try complete(response)
        case "response.failed", "response.incomplete", "response.cancelled", "error": throw CustomResponsesFailure.requestRejected
        default: break
        }
    }
}
