import Foundation
import CryptoKit
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct ModelDownloadTests {
    private func manifest(size: Int64 = 3, hash: String = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") -> ModelManifest {
        .init(displayName: "Fixture", filename: "fixture.litertlm", sourceURL: URL(string: "https://example.com/fixture.litertlm")!, size: size, sha256: hash)
    }

    @Test func checksumAndSizeMustBothMatch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        try await ModelDownload.verifyFile(at: url, manifest: manifest())
        await #expect(throws: (any Error).self) { try await ModelDownload.verifyFile(at: url, manifest: manifest(size: 4)) }
        try Data("abd".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await ModelDownload.verifyFile(at: url, manifest: manifest()) }
    }

    @Test func partialAndErrorHTTPResponsesCannotInstall() throws {
        let url = URL(string: "https://example.com/model")!
        for code in [206, 403, 404, 500] {
            let response = try #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Length": "3"]))
            #expect(throws: (any Error).self) { try ModelDownload.validateResponse(response, expectedSize: 3) }
        }
        let wrongSize = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "20"]))
        #expect(throws: (any Error).self) { try ModelDownload.validateResponse(wrongSize, expectedSize: 3) }
    }

    @Test func initializationDoesNotDownloadOrMarkAnExistingFileVerified() {
        let download = ModelDownload(manifest: manifest(), directory: FileManager.default.temporaryDirectory)
        #expect(download.phase == .idle)
        #expect(!download.isBusy)
        #expect(download.installedURL == nil)
        #expect(download.receivedBytes == 0)
    }

    @Test func verificationFailureKeepsExistingFileAndNeverDownloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.litertlm")
        try Data("bad".utf8).write(to: file)
        let download = ModelDownload(manifest: manifest(), directory: directory)
        await download.verifyExisting()
        for _ in 0..<100 where download.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(download.phase == .failed)
        #expect(download.installedURL == nil)
        #expect(try Data(contentsOf: file) == Data("bad".utf8))
    }
    @Test func transportDownloadsVerifiesAndInstallsOnlyMatchingBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = manifest()
        ModelDownloadStubProtocol.responses.set(.init(status: 200, data: Data("abc".utf8)), for: manifest.sourceURL)
        let download = ModelDownload(manifest: manifest, directory: directory, sessionConfiguration: stubConfiguration())
        download.start()
        try await settle(download)
        #expect(download.phase == .ready)
        #expect(download.installedURL == directory.appendingPathComponent(manifest.filename))
        #expect(download.receivedBytes == 3)
        #expect(download.progress == 1)
        #expect(try Data(contentsOf: #require(download.installedURL)) == Data("abc".utf8))
    }

    @Test func transportHTTPFailureNeverInstallsAResponseBody() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = manifest()
        ModelDownloadStubProtocol.responses.set(.init(status: 403, data: Data("abc".utf8)), for: manifest.sourceURL)
        let download = ModelDownload(manifest: manifest, directory: directory, sessionConfiguration: stubConfiguration())
        download.start()
        try await settle(download)
        #expect(download.phase == .failed)
        #expect(download.installedURL == nil)
        #expect(!FileManager.default.fileExists(atPath: download.destinationURL.path))
    }

    @Test func cancellationOfPendingTransportNeverInstallsOrReportsReady() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = manifest()
        ModelDownloadStubProtocol.responses.set(.init(status: 200, data: nil), for: manifest.sourceURL)
        let download = ModelDownload(manifest: manifest, directory: directory, sessionConfiguration: stubConfiguration())
        download.start()
        for _ in 0..<200 where !ModelDownloadStubProtocol.responses.started(manifest.sourceURL) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ModelDownloadStubProtocol.responses.started(manifest.sourceURL))
        download.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(download.phase == .cancelled)
        #expect(download.installedURL == nil)
        #expect(!download.isBusy)
        #expect(!FileManager.default.fileExists(atPath: download.destinationURL.path))
    }

    @Test func unchangedVerifiedPackageSkipsRedundantHashButChangesInvalidateCache() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.litertlm")
        try Data("abc".utf8).write(to: file)
        let download = ModelDownload(manifest: manifest(), directory: directory)
        await download.verifyExisting()
        #expect(download.hasCurrentVerifiedInstallation)
        #expect(download.verificationAttempts == 1)
        let verified = try #require(download.verifiedAt)
        let modified = try #require(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        await download.verifyExisting()
        download.start()
        #expect(download.verificationAttempts == 1)
        #expect(download.verifiedAt == verified)
        #expect(download.status.contains("already verified"))
        try await Task.sleep(for: .milliseconds(5))
        try Data("abd".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        #expect(!download.hasCurrentVerifiedInstallation)
        await download.verifyExisting()
        #expect(download.phase == .failed)
        #expect(download.verificationAttempts == 2)
        #expect(download.installedURL == nil)
        #expect(download.failureCategory == .existingPackage)
        #expect(download.recoverySuggestion?.contains("move the invalid package yourself") == true)
        #expect(try Data(contentsOf: file) == Data("abd".utf8))
    }

    @Test func removedVerifiedPackageCannotBeReusedOrClaimResumable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.litertlm")
        try Data("abc".utf8).write(to: file)
        let download = ModelDownload(manifest: manifest(), directory: directory)
        await download.verifyExisting()
        try FileManager.default.removeItem(at: file)
        #expect(!download.hasCurrentVerifiedInstallation)
        await download.verifyExisting()
        #expect(download.installedURL == nil)
        #expect(download.phase == .failed)
        #expect(download.resumeSupported)
    }

    @Test func failureRecoveryDistinguishesConnectionDiskAccessAndExistingPackage() {
        #expect(ModelDownload.classifyFailure(URLError(.notConnectedToInternet), existingPackage: false) == .connection)
        #expect(ModelDownload.classifyFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), existingPackage: false) == .diskSpace)
        #expect(ModelDownload.classifyFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), existingPackage: false) == .storageAccess)
        #expect(ModelDownload.classifyFailure(RelayError.message("hash mismatch"), existingPackage: true) == .existingPackage)
        #expect(ModelDownload.recovery(for: .connection).contains("Resume"))
        #expect(ModelDownload.recovery(for: .existingPackage).contains("does not overwrite"))
    }

    @Test func immediateCancelBlocksQueuedNetworkStart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spec = manifest()
        ModelDownloadStubProtocol.responses.set(.init(status: 200, data: Data("abc".utf8)), for: spec.sourceURL)
        let download = ModelDownload(manifest: spec, directory: directory, sessionConfiguration: stubConfiguration())
        download.start()
        download.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(!ModelDownloadStubProtocol.responses.started(spec.sourceURL))
        #expect(download.phase == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: download.destinationURL.path))
    }

    @Test func canceledTransferCanRestartExplicitlyFromAnEmptyCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spec = manifest()
        ModelDownloadStubProtocol.responses.set(.init(status: 200, data: nil), for: spec.sourceURL)
        let download = ModelDownload(manifest: spec, directory: directory, sessionConfiguration: stubConfiguration())
        download.start()
        for _ in 0..<200 where !ModelDownloadStubProtocol.responses.started(spec.sourceURL) { try await Task.sleep(for: .milliseconds(5)) }
        download.cancel()
        #expect(download.phase == .cancelled)
        #expect(download.recoverySuggestion?.contains("Resume") == true)
        #expect(!FileManager.default.fileExists(atPath: download.destinationURL.path))
        ModelDownloadStubProtocol.responses.set(.init(status: 200, data: Data("abc".utf8)), for: spec.sourceURL)
        download.start()
        try await settle(download)
        #expect(download.phase == .ready)
        #expect(download.hasCurrentVerifiedInstallation)
        #expect(download.verificationAttempts == 1)
    }

    private func rangeManifest(_ bytes: Data) -> ModelManifest {
        manifest(size: Int64(bytes.count), hash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    nonisolated private static func segment(_ request: URLRequest, bytes: Data, tag: String = "\"fixture-v1\"") -> DownloadStubResponses.Response {
        guard let raw = request.value(forHTTPHeaderField: "Range"), raw.hasPrefix("bytes="),
              let start = Int(raw.dropFirst(6).split(separator: "-").first ?? ""),
              let end = Int(raw.split(separator: "-").last ?? ""), start >= 0, end >= start, end < bytes.count else {
            return .init(status: 200, data: bytes)
        }
        return .init(status: 206, data: bytes.subdata(in: start..<(end + 1)),
                     headers: ["Content-Range": "bytes \(start)-\(end)/\(bytes.count)", "ETag": tag])
    }
    private func pausedPrefix(bytes: Data, directory: URL) async throws -> ModelManifest {
        let spec = rangeManifest(bytes)
        ModelDownloadStubProtocol.responses.setHandler(for: spec.sourceURL) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=0-2" { return Self.segment(request, bytes: bytes) }
            return .init(status: 206, data: nil, headers: ["Content-Range": "bytes 3-5/\(bytes.count)", "Content-Length": "3", "ETag": "\"fixture-v1\""])
        }
        let first = ModelDownload(manifest: spec, directory: directory, sessionConfiguration: stubConfiguration(), chunkBytes: 3)
        first.start()
        for _ in 0..<400 where first.resumableBytes < 3 && first.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(first.resumableBytes == 3)
        first.cancel()
        await first.waitForCurrentOperation()
        #expect(!FileManager.default.fileExists(atPath: first.destinationURL.path))
        return spec
    }
    @Test func pausedTransferResumesAfterNewControllerWithExactRangeAndETag() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("abcdefghij".utf8)
        let spec = try await pausedPrefix(bytes: bytes, directory: directory)
        ModelDownloadStubProtocol.responses.setHandler(for: spec.sourceURL) { Self.segment($0, bytes: bytes) }
        let resumed = ModelDownload(manifest: spec, directory: directory, sessionConfiguration: stubConfiguration(), chunkBytes: 3)
        resumed.start(); try await settle(resumed)
        #expect(resumed.phase == .ready)
        #expect(try Data(contentsOf: resumed.destinationURL) == bytes)
        let requests = ModelDownloadStubProtocol.responses.requests(for: spec.sourceURL)
        #expect(requests.first?.value(forHTTPHeaderField: "Range") == "bytes=3-5")
        #expect(requests.first?.value(forHTTPHeaderField: "If-Range") == "\"fixture-v1\"")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" })
    }
    @Test func ignoredRangeReturnsCompleteBodyWithoutAppendingDuplicatePrefix() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("abcdefghij".utf8)
        let spec = try await pausedPrefix(bytes: bytes, directory: directory)
        ModelDownloadStubProtocol.responses.set(.init(status: 200, data: bytes), for: spec.sourceURL)
        let resumed = ModelDownload(manifest: spec, directory: directory, sessionConfiguration: stubConfiguration(), chunkBytes: 3)
        resumed.start(); try await settle(resumed)
        #expect(resumed.phase == .ready)
        #expect(try Data(contentsOf: resumed.destinationURL) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".partial") }.isEmpty)
    }
    @Test func changedRangeValidatorFallsBackOnceToFreshCompleteDownload() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("abcdefghij".utf8)
        let spec = try await pausedPrefix(bytes: bytes, directory: directory)
        ModelDownloadStubProtocol.responses.setHandler(for: spec.sourceURL) { Self.segment($0, bytes: bytes, tag: "\"changed-v2\"") }
        let resumed = ModelDownload(manifest: spec, directory: directory, sessionConfiguration: stubConfiguration(), chunkBytes: 3)
        resumed.start(); try await settle(resumed)
        #expect(resumed.phase == .ready)
        #expect(try Data(contentsOf: resumed.destinationURL) == bytes)
        let requests = ModelDownloadStubProtocol.responses.requests(for: spec.sourceURL)
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "Range") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "If-Range") == nil)
    }
    @Test func wrongRangeAndUnsolicitedPartialFailWithoutInstalling() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spec = rangeManifest(Data("abcdefghij".utf8))
        ModelDownloadStubProtocol.responses.set(.init(status: 206, data: Data("abc".utf8), headers: ["Content-Range": "bytes 4-6/10", "ETag": "\"fixture\""]), for: spec.sourceURL)
        let download = ModelDownload(manifest: spec, directory: directory, sessionConfiguration: stubConfiguration(), chunkBytes: 3)
        download.start(); try await settle(download)
        #expect(download.phase == .failed)
        #expect(!FileManager.default.fileExists(atPath: download.destinationURL.path))
        #expect(ModelDownloadStubProtocol.responses.requests(for: spec.sourceURL).count == 2)
    }

    @Test func earlyResponseGateRejectsErrorBodiesAndBudgetsWithoutRejectingRangeFallbacks() throws {
        let url = URL(string: "https://example.com/model")!
        let gate = ModelDownloadProgress(maximumBytes: 10, rangeOffset: 8, maximumChunkBytes: 2) { _, _ in }
        func response(_ status: Int = 200, _ headers: [String: String] = [:]) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
        }
        for status in [302, 401, 403, 404, 429, 500] {
            #expect(gate.rejectionReason(response: try response(status), receivedBytes: 1) != nil)
        }
        for mime in ["text/html", "application/problem+json", "application/xml", "text/plain"] {
            #expect(gate.rejectionReason(response: try response(200, ["Content-Type": mime]), receivedBytes: 1) != nil)
        }
        #expect(gate.rejectionReason(response: try response(200, ["Content-Encoding": "gzip"]), receivedBytes: 1) != nil)
        #expect(gate.rejectionReason(response: try response(200, ["Content-Length": "11"]), receivedBytes: 1) != nil)
        #expect(gate.rejectionReason(response: try response(206, ["Content-Length": "3"]), receivedBytes: 1) != nil)
        #expect(gate.rejectionReason(response: try response(206), receivedBytes: 3) != nil)
        #expect(gate.rejectionReason(response: try response(200), receivedBytes: 11) != nil)
        // Bad validators/ranges still reach the existing one-fresh-full-response fallback.
        #expect(gate.rejectionReason(response: try response(206, ["Content-Range": "bytes 4-5/10", "ETag": "changed"]), receivedBytes: 2) == nil)
        #expect(gate.rejectionReason(response: try response(200, ["Content-Type": "application/octet-stream", "Content-Encoding": "identity", "Content-Length": "10"]), receivedBytes: 10) == nil)
    }

    @Test func unsafeRedirectRecordsFirstFailureBeforeFollowing() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.com/model")!)
        let response = try #require(HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil))
        let gate = ModelDownloadProgress(maximumBytes: 10) { _, _ in }
        gate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                        newRequest: URLRequest(url: URL(string: "http://example.com/model")!)) { request in
            #expect(request == nil)
        }
        let first = gate.failureReason
        #expect(first?.contains("unsafe redirect") == true)
        gate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                        newRequest: URLRequest(url: URL(string: "file:///tmp/model")!)) { request in
            #expect(request == nil)
        }
        #expect(gate.failureReason == first)
    }

    @Test func manifestMatchesCheckpointBoundsAndRejectsAmbiguousSources() throws {
        let valid = manifest()
        func altered(size: Int64? = nil, filename: String? = nil, source: URL? = nil, hash: String? = nil) -> ModelManifest {
            .init(displayName: valid.displayName, filename: filename ?? valid.filename, sourceURL: source ?? valid.sourceURL,
                  size: size ?? valid.size, sha256: hash ?? valid.sha256)
        }
        try ModelDownload.validateManifest(altered(size: 8_589_934_592))
        for spec in [altered(size: 8_589_934_593), altered(filename: String(repeating: "a", count: 193) + ".litertlm"),
                     altered(hash: valid.sha256.uppercased()), altered(source: URL(string: "https://example.com/model?token=value")!),
                     altered(source: URL(string: "https://example.com/model#fragment")!)] {
            #expect(throws: (any Error).self) { try ModelDownload.validateManifest(spec) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadStubProtocol.self]
        return configuration
    }

    private func settle(_ download: ModelDownload) async throws {
        for _ in 0..<400 where download.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!download.isBusy)
        await download.waitForCurrentOperation()
    }

}


/// URLProtocol callbacks run on Foundation's queue; every mutable fixture value is lock-protected.
nonisolated private final class DownloadStubResponses: @unchecked Sendable {
    struct Response: Sendable {
        let status: Int; let data: Data?; let headers: [String: String]
        init(status: Int, data: Data?, headers: [String: String] = [:]) { self.status = status; self.data = data; self.headers = headers }
    }
    private let lock = NSLock()
    private var values: [URL: Response] = [:]
    private var requests: Set<URL> = []
    private var handlers: [URL: @Sendable (URLRequest) -> Response] = [:]
    private var captured: [URL: [URLRequest]] = [:]
    func set(_ response: Response, for url: URL) {
        lock.withLock { values[url] = response; handlers.removeValue(forKey: url); captured[url] = []; requests.remove(url) }
    }
    func setHandler(for url: URL, _ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock { handlers[url] = handler; values.removeValue(forKey: url); captured[url] = []; requests.remove(url) }
    }
    func requests(for url: URL) -> [URLRequest] { lock.withLock { captured[url] ?? [] } }
    func take(_ request: URLRequest) -> Response? {
        guard let url = request.url else { return nil }
        let pair = lock.withLock { () -> ((@Sendable (URLRequest) -> Response)?, Response?) in
            requests.insert(url); captured[url, default: []].append(request)
            return (handlers[url], values[url])
        }
        return pair.0?(request) ?? pair.1
    }
    func started(_ url: URL) -> Bool { lock.withLock { requests.contains(url) } }
}

nonisolated private final class ModelDownloadStubProtocol: URLProtocol, @unchecked Sendable {
    static let responses = DownloadStubResponses()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let stub = Self.responses.take(request),
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(stub.data?.count ?? 3)].merging(stub.headers) { _, custom in custom }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = stub.data {
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
