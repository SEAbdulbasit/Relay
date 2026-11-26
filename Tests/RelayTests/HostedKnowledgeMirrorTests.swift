import CryptoKit
import Foundation
import Testing
@testable import Relay

@MainActor
struct HostedKnowledgeMirrorTests {
    @Test func unrelatedSuccessPageCannotAcknowledgeUploadOrDeletion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MirrorReceiptFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let catchAll = try #require(URL(string: "https://relay-receipt-fixture.invalid/unrelated"))
        var request = URLRequest(url: catchAll)
        request.httpMethod = "POST"
        await #expect(throws: HostedKnowledgeMirrorTransport.Failure.self) {
            try await HostedKnowledgeMirrorTransport.send(request, session: session)
        }
        request.httpMethod = "DELETE"
        await #expect(throws: HostedKnowledgeMirrorTransport.Failure.self) {
            try await HostedKnowledgeMirrorTransport.send(request, session: session)
        }

        request.url = catchAll.deletingLastPathComponent().appending(path: "vault")
        try await HostedKnowledgeMirrorTransport.send(request, session: session)
        request.httpMethod = "POST"
        try await HostedKnowledgeMirrorTransport.send(request, session: session)
    }

    @Test func wireIdentityAndCiphertextMatchMirrorContract() throws {
        let password = "abcdefghijklmnopqrstuvwx"
        let uid = "GOKXEcs6ez3EEZ0WOYYv"
        #expect(HostedKnowledgeMirrorTransport.userID(password) == uid)
        let endpoint = try HostedKnowledgeMirrorTransport.origin("HTTPS://MIRROR.EXAMPLE:443/")
        #expect(HostedKnowledgeMirrorTransport.url(origin: endpoint, password: password, resource: "mcp").absoluteString
                == "https://mirror.example/u_\(uid)/p_\(password)/mcp")
        for invalid in ["http://mirror.example", "https://user@mirror.example", "https://mirror.example/other",
                        "https://mirror.example/#fragment", "https://mirror.example/%2F"] {
            #expect(throws: HostedKnowledgeMirrorTransport.Failure.self) {
                try HostedKnowledgeMirrorTransport.origin(invalid)
            }
        }

        let note = Data("Fixture Café".utf8)
        let zip = try HostedKnowledgeMirrorTransport.zip(["Folder/Café.md": note])
        let ciphertext = try HostedKnowledgeMirrorTransport.seal(zip, password: password)
        #expect(ciphertext.first == 1)
        #expect(ciphertext.range(of: note) == nil)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
                                        salt: Data([0x73, 0x65, 0x6e, 0x74, 0x69, 0x65, 0x6e, 0x74, 0x2d, 0x6f, 0x73, 0x2d, 0x6d, 0x69, 0x72, 0x72, 0x6f, 0x72, 0x2d, 0x76, 0x31]),
                                        info: Data("vault-content-key".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.SealedBox(combined: ciphertext.dropFirst())
        #expect(try AES.GCM.open(sealed, using: key, authenticating: Data(uid.utf8)) == zip)
        #expect(throws: CryptoKitError.self) {
            try AES.GCM.open(sealed, using: key, authenticating: Data("different scope".utf8))
        }
        #expect(throws: HostedKnowledgeMirrorTransport.Failure.self) {
            try HostedKnowledgeMirrorTransport.zip(["../outside.md": note])
        }
    }

    @Test func launchCatchUpRetriesFailedRevisionAndDeleteThenMintsFreshLink() async throws {
        let suite = "relay.mirror.fixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let note = root.appending(path: "Fixture.md")
        try Data("first".utf8).write(to: note)
        let credentials = CustomResponsesCredentials.Store.memory()
        var requests: [URLRequest] = []
        var fails = false
        let send: (URLRequest) async throws -> Void = { request in
            requests.append(request)
            if fails { throw HostedKnowledgeMirrorTransport.Failure.requestFailed }
        }

        let first = HostedKnowledgeMirror(root: root, defaults: defaults, keychain: credentials, send: send)
        await first.enable(origin: "https://mirror.example")
        let originalLink = try #require(first.connectorURL())
        let originalSync = try #require(first.lastSync)
        #expect(requests.count == 1)
        #expect(requests.first?.httpBody?.first == 1)

        try Data("edit while window closed".utf8).write(to: note, options: .atomic)
        fails = true
        await first.synchronize()
        #expect(requests.count == 1)
        await first.synchronize()
        #expect(requests.count == 2)
        #expect(first.lastSync == originalSync)

        let relaunched = HostedKnowledgeMirror(root: root, defaults: defaults, keychain: credentials, send: send)
        fails = false
        await relaunched.synchronize(immediate: true)
        #expect(requests.count == 3)
        #expect(relaunched.lastSync != originalSync)
        await relaunched.synchronize(immediate: true)
        #expect(requests.count == 3)

        fails = true
        await relaunched.disable()
        #expect(relaunched.deletionPending)
        #expect(relaunched.connectorURL() == nil)
        #expect(requests.last?.httpMethod == "DELETE")

        let removalRetry = HostedKnowledgeMirror(root: root, defaults: defaults, keychain: credentials, send: send)
        fails = false
        await removalRetry.synchronize(immediate: true)
        #expect(!removalRetry.deletionPending)
        #expect(requests.last?.httpMethod == "DELETE")

        await removalRetry.enable(origin: "https://mirror.example")
        let replacementLink = try #require(removalRetry.connectorURL())
        #expect(replacementLink != originalLink)
        #expect(requests.last?.httpMethod == "POST")
    }

    @Test(.timeLimit(.minutes(1))) func disablingDuringPostRevokesLocallyAndDeletesAfterPostDrains() async throws {
        let suite = "relay.mirror.fixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let note = root.appending(path: "Fixture.md")
        try Data("original".utf8).write(to: note)

        let credentials = CustomResponsesCredentials.Store.memory()
        var events: [String] = []
        var duringPost: (() async -> Void)?
        let mirror = HostedKnowledgeMirror(root: root, defaults: defaults, keychain: credentials, send: { request in
            if request.httpMethod == "POST" {
                events.append("post begins")
                await duringPost?()
                events.append("post ends")
            } else {
                events.append("delete")
            }
        })
        await mirror.enable(origin: "https://mirror.example")
        #expect(mirror.connectorURL() != nil)
        events.removeAll()
        try Data("edit".utf8).write(to: note, options: .atomic)
        duringPost = { [weak mirror] in
            guard let mirror else { return }
            await mirror.disable()
            #expect(!mirror.isEnabled)
            #expect(mirror.connectorURL() == nil)
            #expect(mirror.lastSync == nil)
            #expect(mirror.deletionPending)
            #expect(events == ["post begins"])
            let restarted = HostedKnowledgeMirror(root: root, defaults: defaults, keychain: credentials)
            #expect(restarted.deletionPending)
        }
        await mirror.synchronize(immediate: true)
        await mirror.synchronize(immediate: true)
        #expect(events == ["post begins", "post ends", "delete"])
        #expect(mirror.connectorURL() == nil)
        #expect(mirror.lastSync == nil)
        #expect(!mirror.deletionPending)
    }
}

private nonisolated final class MirrorReceiptFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isVault = url.path == "/vault"
        let deleted = isVault && request.httpMethod == "DELETE"
        let text = isVault ? #"{"ok":true,"files":1,"lease_days":30}"# : "<html>Welcome</html>"
        guard let response = HTTPURLResponse(url: url, statusCode: deleted ? 204 : 200,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !deleted { client?.urlProtocol(self, didLoad: Data(text.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
