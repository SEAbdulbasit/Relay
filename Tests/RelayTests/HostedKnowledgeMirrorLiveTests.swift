import Foundation
import Security
import Testing
@testable import Relay

/// Runs against a separately started, owned HTTPS knowledge mirror.
@MainActor
struct HostedKnowledgeMirrorLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_HOSTED_MIRROR_TEST"] == "1"),
          .timeLimit(.minutes(1)))
    func encryptedVaultSynchronizesThroughMCPAndOldLinkLosesAccess() async throws {
        let environment = ProcessInfo.processInfo.environment
        let origin = try HostedKnowledgeMirrorTransport.origin(
            try #require(environment["RELAY_HOSTED_MIRROR_TEST_ORIGIN"])
        )
        try #require(origin.host == "127.0.0.1" && origin.port != nil)
        let certificate = URL(fileURLWithPath: try #require(environment["RELAY_HOSTED_MIRROR_TEST_CERTIFICATE"]))
        let delegate = try MirrorFixtureTLS(certificate: Data(contentsOf: certificate))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let suite = "relay.mirror.live-fixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root.appending(path: "Projects"), withIntermediateDirectories: true)
        let relativePath = "Projects/Café.md"
        let note = root.appending(path: relativePath)
        let initial = "Synthetic note \(UUID().uuidString)"
        let revised = "Revised synthetic note \(UUID().uuidString)"
        try Data(initial.utf8).write(to: note)

        let credentials = CustomResponsesCredentials.Store.memory()
        let mirror = HostedKnowledgeMirror(root: root, defaults: defaults, keychain: credentials, send: {
            try await HostedKnowledgeMirrorTransport.send($0, session: session)
        }, readAccess: {
            try await HostedKnowledgeMirrorTransport.readAccess(at: $0, session: session)
        })
        await mirror.enable(origin: origin.absoluteString)
        let link = try #require(mirror.connectorURL(), "Mirror did not accept the fixture upload.")
        #expect(mirror.lastSync != nil)
        await mirror.refreshAccess()
        #expect(mirror.access == HostedKnowledgeMirrorAccess(notesRead: 0, toolCalls: 0, lastAccessTimestamp: nil))
        let client = FixtureMCPClient(session: session, endpoint: link)
        try await client.initialize()
        let catalog = try await client.request("tools/list")
        let tools = try #require(catalog["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["get_files", "get_structure"])
        let original = try await client.read(path: relativePath)
        #expect(original == "=== \(relativePath) ===\n\(initial)")

        try Data(revised.utf8).write(to: note, options: .atomic)
        let relaunched = HostedKnowledgeMirror(root: root, defaults: defaults, keychain: credentials, send: {
            try await HostedKnowledgeMirrorTransport.send($0, session: session)
        }, readAccess: {
            try await HostedKnowledgeMirrorTransport.readAccess(at: $0, session: session)
        })
        await relaunched.synchronize(immediate: true)
        let otherSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { otherSession.invalidateAndCancel() }
        let otherClient = FixtureMCPClient(session: otherSession, endpoint: link)
        try await otherClient.initialize()
        let updated = try await otherClient.read(path: relativePath)
        #expect(updated == "=== \(relativePath) ===\n\(revised)")

        await relaunched.refreshAccess()
        #expect(relaunched.access?.notesRead == 1)
        #expect(relaunched.access?.toolCalls == 2)
        #expect(relaunched.access?.lastAccess != nil)

        await relaunched.disable()
        #expect(!relaunched.isEnabled && !relaunched.deletionPending)
        #expect(relaunched.connectorURL() == nil)
        #expect(relaunched.access == nil)
        // The service must acknowledge a retry even after the first DELETE succeeded.
        var repeatedDelete = URLRequest(url: link.deletingLastPathComponent().appending(path: "vault"))
        repeatedDelete.httpMethod = "DELETE"
        try await HostedKnowledgeMirrorTransport.send(repeatedDelete, session: session)
        let refused = try await client.request("tools/call", parameters: [
            "name": "get_files", "arguments": ["paths": [relativePath]]
        ])
        #expect(refused["isError"] as? Bool == true)
        let refusal = (refused["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(!refusal.contains(initial) && !refusal.contains(revised))
        #expect(try Data(contentsOf: note) == Data(revised.utf8))
    }
}

@MainActor
private final class FixtureMCPClient {
    let session: URLSession
    let endpoint: URL
    var version: String?
    var sessionID: String?

    init(session: URLSession, endpoint: URL) {
        self.session = session
        self.endpoint = endpoint
    }

    func initialize() async throws {
        let result = try await request("initialize", parameters: [
            "protocolVersion": "2025-03-26", "capabilities": [:],
            "clientInfo": ["name": "Relay isolated live fixture", "version": "1"]
        ])
        version = try #require(result["protocolVersion"] as? String)
        _ = try await request("notifications/initialized", notification: true)
    }

    func read(path: String) async throws -> String {
        let result = try await request("tools/call", parameters: ["name": "get_files", "arguments": ["paths": [path]]])
        try #require(result["isError"] as? Bool != true)
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    func request(_ method: String, parameters: [String: Any] = [:], notification: Bool = false) async throws -> [String: Any] {
        let id = UUID().uuidString
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": parameters]
        if !notification { body["id"] = id }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, reply) = try await session.data(for: request)
        let response = try #require(reply as? HTTPURLResponse)
        try #require((200...299).contains(response.statusCode))
        if let newSession = response.value(forHTTPHeaderField: "MCP-Session-Id") { sessionID = newSession }
        if notification { return [:] }

        let messages: [Data]
        if response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true {
            messages = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
                guard line.hasPrefix("data:") else { return nil }
                return Data(line.dropFirst(5).utf8)
            }
        } else {
            messages = [data]
        }
        for message in messages {
            if let object = try JSONSerialization.jsonObject(with: message) as? [String: Any],
               object["id"] as? String == id {
                return try #require(object["result"] as? [String: Any], "Fixture MCP reply lacked a matching result.")
            }
        }
        try #require(Bool(false), "Fixture MCP response contained no matching reply.")
        return [:]
    }
}

private nonisolated final class MirrorFixtureTLS: NSObject, URLSessionTaskDelegate {
    let certificate: Data

    init(certificate: Data) throws {
        _ = try #require(SecCertificateCreateWithData(nil, certificate as CFData))
        self.certificate = certificate
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, certificate as CFData),
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil),
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              SecCertificateCopyData(leaf) as Data == certificate else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
