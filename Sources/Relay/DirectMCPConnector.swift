import Foundation
import Observation

nonisolated struct DirectMCPResource: Identifiable, Sendable {
    var id: String { uri }
    let uri: String
    let title: String
    let description: String?
}

nonisolated struct DirectMCPTool: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let title: String
    let description: String?
    let schema: [String: JSONValue]
    fileprivate let headers: [DirectMCPArgumentHeader]
}

nonisolated struct DirectMCPReadPreview: Identifiable, Sendable {
    let id = UUID()
    let endpoint: URL
    let methodName: String
    let target: String
    let arguments: String?
    fileprivate let method: DirectMCPWire.Method
    fileprivate let params: [String: JSONValue]
    fileprivate let headers: [String: String]
}

/// Manual source panel only. No model tool, automatic dispatch, durable credentials, or polling.
@Observable @MainActor final class DirectMCPConnector {
    private(set) var endpoint: URL?
    private(set) var connectionName = ""
    private(set) var protocolVersion = ""
    private(set) var resources: [DirectMCPResource] = []
    private(set) var tools: [DirectMCPTool] = []
    private(set) var preview: DirectMCPReadPreview?
    private(set) var output: String?
    private(set) var isBusy = false
    private(set) var status = "Connect an endpoint to list its available reads."

    @ObservationIgnored private var transport: DirectMCPTransport?
    @ObservationIgnored private var wire: DirectMCPWire?
    @ObservationIgnored private var revision = 0

    func connect(address: String, token: String, legacyOnly: Bool = false) async {
        guard !isBusy, endpoint == nil, !Task.isCancelled else { return }
        let target: DirectMCPEndpoint
        do { target = try DirectMCPEndpoint(address, token: token) }
        catch { status = error.localizedDescription; return }
        revision += 1
        let expected = revision
        let candidate = DirectMCPTransport(endpoint: target)
        transport = candidate
        isBusy = true
        status = "Connecting and listing available reads…"
        defer { if expected == revision { isBusy = false } }
        do {
            let discovery = try await discover(candidate, legacyOnly: legacyOnly)
            try requireCurrent(expected)
            let catalog = try await list(candidate, wire: discovery.wire, capabilities: discovery.capabilities)
            try requireCurrent(expected)
            wire = discovery.wire
            endpoint = target.url
            connectionName = discovery.name
            protocolVersion = discovery.wire.version
            resources = catalog.resources
            tools = catalog.tools
            status = "Listed \(resources.count) resources and \(tools.count) tools labeled read-only."
                + (catalog.limited ? " Some entries were skipped or exceeded the list limits." : "")
        } catch {
            guard expected == revision else { return }
            candidate.invalidate()
            transport = nil
            status = Self.status(for: error)
        }
    }

    func disconnect() {
        revision += 1
        transport?.invalidate()
        transport = nil
        wire = nil
        endpoint = nil
        connectionName = ""
        protocolVersion = ""
        resources = []
        tools = []
        preview = nil
        output = nil
        isBusy = false
        status = "Disconnected. Endpoint data and token cleared from this session."
    }

    func clearPreview() { preview = nil }

    func prepareResource(_ resourceID: String) {
        guard !isBusy else { return }
        preview = nil
        guard let endpoint, let resource = resources.first(where: { $0.id == resourceID }) else { return }
        preview = DirectMCPReadPreview(endpoint: endpoint, methodName: DirectMCPWire.Method.read.rawValue,
            target: resource.uri, arguments: nil, method: .read, params: ["uri": .string(resource.uri)], headers: [:])
    }

    func prepareTool(_ toolID: String, arguments: String) {
        guard !isBusy else { return }
        preview = nil
        guard let endpoint, let tool = tools.first(where: { $0.id == toolID }) else { return }
        do {
            let decoded = try Self.parseArguments(arguments, schema: tool.schema)
            let values = try DirectMCPArgumentHeader.values(tool.headers, arguments: decoded)
            let canonical = JSONValue.object(decoded).pretty
            preview = DirectMCPReadPreview(endpoint: endpoint, methodName: DirectMCPWire.Method.call.rawValue,
                target: tool.name, arguments: canonical, method: .call,
                params: ["name": .string(tool.name), "arguments": .object(decoded)], headers: values)
        } catch { status = error.localizedDescription }
    }

    func performReviewedRead(_ id: UUID) async {
        guard !isBusy else { return }
        guard !Task.isCancelled, let endpoint, let wire, let transport,
              let request = preview, request.id == id, request.endpoint == endpoint else {
            status = DirectMCPFailure.review.localizedDescription
            return
        }
        preview = nil // One use, consumed before the first suspension point.
        output = nil
        isBusy = true
        status = "Sending the reviewed read to the selected endpoint…"
        let expected = revision
        defer { if expected == revision { isBusy = false } }
        do {
            let reply = try await transport.send(request.method, wire: wire, parameters: request.params, parameterHeaders: request.headers)
            try requireCurrent(expected)
            output = try Self.readText(reply.result, request: request)
            status = "The endpoint returned text for the reviewed read."
        } catch {
            guard expected == revision else { return }
            if let failure = error as? DirectMCPFailure {
                switch failure {
                case .sessionChanged, .authorization: disconnect()
                default: break
                }
            }
            status = Self.status(for: error)
        }
    }

    private func requireCurrent(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == revision else { throw CancellationError() }
    }

    private func discover(_ transport: DirectMCPTransport, legacyOnly: Bool) async throws
        -> (wire: DirectMCPWire, name: String, capabilities: [String: JSONValue]) {
        if !legacyOnly {
            do {
                let modern = DirectMCPWire(version: DirectMCPWire.currentVersion, sessionID: nil)
                let reply = try await transport.send(.discover, wire: modern)
                guard case .array(let versions) = reply.result["supportedVersions"],
                      versions.contains(.string(modern.version)), let capabilities = reply.result["capabilities"]?.object else {
                    throw DirectMCPFailure.version
                }
                let metadata = reply.result["_meta"]?.object?["io.modelcontextprotocol/serverInfo"]?.object
                return (modern, Self.name(metadata), capabilities)
            } catch let failure as DirectMCPFailure where failure.allowsLegacyDiscovery {
                try Task.checkCancellation()
            }
        }
        let offer = DirectMCPWire(version: "2025-11-25", sessionID: nil)
        let reply = try await transport.send(.initialize, wire: offer, parameters: [
            "protocolVersion": .string(offer.version), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Relay"), "version": .string("0.1.0")])
        ])
        guard let version = reply.result["protocolVersion"]?.string, DirectMCPWire.legacyVersions.contains(version),
              let capabilities = reply.result["capabilities"]?.object else { throw DirectMCPFailure.version }
        let legacy = DirectMCPWire(version: version, sessionID: reply.sessionID)
        _ = try await transport.send(.initialized, wire: legacy)
        return (legacy, Self.name(reply.result["serverInfo"]?.object), capabilities)
    }

    private func list(_ transport: DirectMCPTransport, wire: DirectMCPWire, capabilities: [String: JSONValue]) async throws
        -> (resources: [DirectMCPResource], tools: [DirectMCPTool], limited: Bool) {
        var resources: [DirectMCPResource] = []
        var tools: [DirectMCPTool] = []
        var limited = false
        if capabilities["resources"]?.object != nil {
            let page = try await entries(transport, wire: wire, method: .listResources, key: "resources")
            resources = page.items.compactMap(Self.resource)
            limited = page.limited || resources.count < page.items.count
        }
        if capabilities["tools"]?.object != nil {
            let page = try await entries(transport, wire: wire, method: .listTools, key: "tools")
            tools = page.items.compactMap(Self.tool)
            limited = limited || page.limited || tools.count < page.items.count
        }
        guard Set(resources.map(\.id)).count == resources.count, Set(tools.map(\.id)).count == tools.count else {
            throw DirectMCPFailure.reply
        }
        return (resources, tools, limited)
    }

    private func entries(_ transport: DirectMCPTransport, wire: DirectMCPWire, method: DirectMCPWire.Method, key: String) async throws
        -> (items: [JSONValue], limited: Bool) {
        var entries: [JSONValue] = []
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<4 {
            try Task.checkCancellation()
            let params = cursor.map { ["cursor": JSONValue.string($0)] } ?? [:]
            let reply = try await transport.send(method, wire: wire, parameters: params)
            guard case .array(let items) = reply.result[key] else { throw DirectMCPFailure.reply }
            let capacity = 80 - entries.count
            entries += items.prefix(capacity)
            if items.count > capacity { return (entries, true) }
            guard let next = reply.result["nextCursor"]?.string else { return (entries, false) }
            if entries.count == 80 { return (entries, true) }
            guard !next.isEmpty, next.utf8.count <= 2048, seen.insert(next).inserted else { throw DirectMCPFailure.reply }
            cursor = next
        }
        return (entries, true)
    }

    private static func resource(_ value: JSONValue) -> DirectMCPResource? {
        guard let object = value.object, let uri = object["uri"]?.string,
              safeTarget(uri, maximum: 2048), URLComponents(string: uri)?.scheme != nil else { return nil }
        let title = label(object["title"] ?? object["name"], maximum: 220) ?? bounded(uri, limit: 220)
        return DirectMCPResource(uri: uri, title: title, description: label(object["description"], maximum: 600))
    }

    private static func tool(_ value: JSONValue) -> DirectMCPTool? {
        guard let object = value.object, let name = object["name"]?.string, safeTarget(name, maximum: 256),
              let schema = object["inputSchema"]?.object, schema["type"]?.string == "object",
              let hints = object["annotations"]?.object, hints["readOnlyHint"] == .bool(true),
              hints["destructiveHint"] != .bool(true),
              let headers = try? DirectMCPArgumentHeader.parse(schema) else { return nil }
        return DirectMCPTool(name: name, title: label(object["title"] ?? hints["title"], maximum: 220) ?? name,
                             description: label(object["description"], maximum: 600), schema: schema, headers: headers)
    }

    private static func name(_ object: [String: JSONValue]?) -> String {
        label(object?["title"] ?? object?["name"], maximum: 160) ?? "MCP endpoint"
    }

    private static func safeTarget(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func parseArguments(_ raw: String, schema: [String: JSONValue]) throws -> [String: JSONValue] {
        guard raw.utf8.count <= 4096, let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
              let object = decoded.object, safeArgument(decoded, depth: 0) else { throw DirectMCPFailure.arguments }
        if case .array(let keys) = schema["required"] {
            guard keys.allSatisfy({ key in key.string.map { object[$0] != nil } == true }) else { throw DirectMCPFailure.arguments }
        }
        if schema["additionalProperties"] == .bool(false),
           !Set(object.keys).isSubset(of: Set(schema["properties"]?.object?.keys.map { $0 } ?? [])) { throw DirectMCPFailure.arguments }
        return object
    }

    private static func safeArgument(_ value: JSONValue, depth: Int) -> Bool {
        guard depth <= 20 else { return false }
        switch value {
        case .number(let number): return number.isFinite && abs(number) <= 9_007_199_254_740_991
        case .array(let items): return items.allSatisfy { safeArgument($0, depth: depth + 1) }
        case .object(let items): return items.values.allSatisfy { safeArgument($0, depth: depth + 1) }
        default: return true
        }
    }

    private static func readText(_ result: [String: JSONValue], request: DirectMCPReadPreview) throws -> String {
        let text: [String]
        if request.method == .read {
            guard case .array(let items) = result["contents"] else { throw DirectMCPFailure.reply }
            text = items.compactMap { item in
                guard let fields = item.object, fields["uri"]?.string == request.target else { return nil }
                return fields["text"]?.string
            }
        } else {
            guard result["isError"] != .bool(true) else { throw DirectMCPFailure.toolError }
            var blocks: [String] = []
            if case .array(let contents) = result["content"] {
                blocks = contents.compactMap { item in
                    guard let fields = item.object, fields["type"]?.string == "text" else { return nil }
                    return fields["text"]?.string
                }
            }
            if blocks.isEmpty, let structured = result["structuredContent"]?.object { blocks = [JSONValue.object(structured).pretty] }
            text = blocks
        }
        let visible = text.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { throw DirectMCPFailure.noText }
        let bounded = bounded(visible, limit: 24_000)
        return bounded + (bounded.utf8.count < visible.utf8.count ? "\n\n[Relay display limit reached]" : "")
    }

    private static func label(_ value: JSONValue?, maximum: Int) -> String? {
        guard let raw = value?.string else { return nil }
        let safe = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return safe.isEmpty ? nil : bounded(safe, limit: maximum)
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        var bytes = value.utf8.prefix(limit)
        while !bytes.isEmpty {
            if let decoded = String(bytes: bytes, encoding: .utf8) { return decoded }
            bytes = bytes.dropLast()
        }
        return ""
    }

    private static func status(for error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Request cancelled. Reconnect or preview the read again." }
        if let failure = error as? DirectMCPFailure { return failure.localizedDescription }
        return "The MCP connection failed. Check the endpoint and network, then reconnect."
    }
}

nonisolated fileprivate struct DirectMCPArgumentHeader: Sendable {
    enum Kind: String { case string, integer, boolean }
    let name: String
    let path: [String]
    let kind: Kind

    static func parse(_ schema: [String: JSONValue]) throws -> [Self] {
        var output: [Self] = []
        var names = Set<String>()
        let nameBytes = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
        func containsMarker(_ node: JSONValue, depth: Int) -> Bool {
            guard depth <= 32 else { return true }
            if let object = node.object { return object["x-mcp-header"] != nil || object.values.contains { containsMarker($0, depth: depth + 1) } }
            if case .array(let values) = node { return values.contains { containsMarker($0, depth: depth + 1) } }
            return false
        }
        func walk(_ node: [String: JSONValue], path: [String]) throws {
            guard path.count <= 20 else { throw DirectMCPFailure.reply }
            if let marker = node["x-mcp-header"] {
                guard !path.isEmpty, let name = marker.string, !name.isEmpty, name.utf8.count <= 100,
                      name.utf8.allSatisfy(nameBytes.contains), names.insert(name.lowercased()).inserted,
                      let type = node["type"]?.string, let kind = Kind(rawValue: type), output.count < 16 else {
                    throw DirectMCPFailure.reply
                }
                output.append(Self(name: name, path: path, kind: kind))
            }
            for (key, value) in node where key != "properties" && key != "x-mcp-header" {
                guard !containsMarker(value, depth: 0) else { throw DirectMCPFailure.reply }
            }
            for (name, value) in node["properties"]?.object ?? [:] {
                if let property = value.object { try walk(property, path: path + [name]) }
                else if containsMarker(value, depth: 0) { throw DirectMCPFailure.reply }
            }
        }
        try walk(schema, path: [])
        return output
    }

    static func values(_ headers: [Self], arguments: [String: JSONValue]) throws -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            let node = header.path.reduce(Optional(JSONValue.object(arguments))) { $0?.object?[$1] }
            guard let node, node != .null else { continue }
            switch (header.kind, node) {
            case (.string, .string(let string)): result[header.name] = string
            case (.integer, .number(let number)) where number.rounded() == number:
                result[header.name] = String(Int64(number))
            case (.boolean, .bool(let value)): result[header.name] = value ? "true" : "false"
            default: throw DirectMCPFailure.arguments
            }
        }
        return result
    }
}
