import CryptoKit
import Foundation
import Observation
import Darwin

/// The download is immutable and checksum pinned; no executable code is fetched.
nonisolated struct ModelManifest: Codable, Sendable, Equatable {
    let displayName: String
    let filename: String
    let sourceURL: URL
    let size: Int64
    let sha256: String

    static let recommended = ModelManifest(
        displayName: "Gemma 4 E2B",
        filename: "gemma-4-E2B-it.litertlm",
        sourceURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/1caa527c1e88b55f046fcd8d2b4265606680663d/gemma-4-E2B-it.litertlm")!,
        size: 2_588_147_712,
        sha256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
    )

    static let gemma4E4B = ModelManifest(
        displayName: "Gemma 4 E4B",
        filename: "gemma-4-E4B-it.litertlm",
        sourceURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm")!,
        size: 3_659_530_240,
        sha256: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0"
    )

    static let catalog: [ModelManifest] = [
        .gemma4E4B,
        .recommended
    ]

    static let supportedArchitecturesNote = "Compatible with LiteRT-LM (.litertlm) packages for Gemma 4 (E2B, E4B, 12B, 26B-A4B, 31B with MTP speculative decoding), Qwen 3, Qwen 2.5, Gemma 3 / 3n, and FunctionGemma."

    static func resolveInstalledURL(for manifest: ModelManifest, in directory: URL? = nil) -> URL? {
        let modelDirectory = directory ?? URL.applicationSupportDirectory.appending(path: "Relay/Models", directoryHint: .isDirectory)
        let candidate = modelDirectory.appendingPathComponent(manifest.filename)
        guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isReadableKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, values.isReadable == true,
              Int64(values.fileSize ?? -1) == manifest.size else { return nil }
        return candidate
    }
}

/// Model provisioning is separate from engine readiness. Nothing downloads until Start is pressed.
@Observable @MainActor
final class ModelDownload {
    enum Phase { case idle, downloading, verifying, ready, cancelled, failed }
    enum FailureCategory { case connection, diskSpace, storageAccess, existingPackage, package, other }

    private(set) var phase: Phase = .idle
    private(set) var status = "Download the recommended model, or import one you already have."
    private(set) var progress: Double = 0
    private(set) var receivedBytes: Int64 = 0
    var totalBytes: Int64 { manifest.size }
    private(set) var errorMessage: String?
    private(set) var installedURL: URL?
    private(set) var verifiedAt: Date?
    private(set) var verificationAttempts = 0
    private(set) var failureCategory: FailureCategory?
    private(set) var recoverySuggestion: String?
    var resumeSupported: Bool { true }
    private(set) var resumableBytes: Int64 = 0
    private(set) var hostSupportsResume: Bool?
    var hasCurrentVerifiedInstallation: Bool {
        guard phase == .ready, let installedURL, let verifiedStamp else { return false }
        return (try? Self.fileStamp(installedURL)) == verifiedStamp
    }
    var isBusy: Bool { phase == .downloading || phase == .verifying }
    var existingFileAvailable: Bool { FileManager.default.fileExists(atPath: destinationURL.path) }
    let manifest: ModelManifest
    let directory: URL
    var destinationURL: URL { directory.appendingPathComponent(manifest.filename) }

    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let sessionConfiguration: URLSessionConfiguration?
    @ObservationIgnored private var verifiedStamp: FileStamp?
    @ObservationIgnored private let chunkBytes: Int64

    init(manifest: ModelManifest = .recommended, directory: URL? = nil, sessionConfiguration: URLSessionConfiguration? = nil,
         chunkBytes: Int64 = ModelResumeProtocol.maximumChunkBytes) {
        self.manifest = manifest
        self.chunkBytes = chunkBytes
        self.sessionConfiguration = sessionConfiguration
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Relay/Models", directoryHint: .isDirectory)
    }

    func start() { begin(allowDownload: true) }
    func waitForCurrentOperation() async { await operation?.value }
    func verifyExisting() async {
        guard !isBusy else { return }
        if hasCurrentVerifiedInstallation {
            status = "This installed package is already verified and unchanged. Ready to load."
            return
        }
        begin(allowDownload: false)
        await operation?.value
    }

    func cancel() {
        guard isBusy else { return }
        revision += 1
        operation?.cancel()
        phase = .cancelled
        installedURL = nil
        verifiedStamp = nil
        verifiedAt = nil
        errorMessage = nil
        failureCategory = nil
        recoverySuggestion = "Press Resume to reuse checked completed segments when supported. The incomplete segment restarts. Hosts that send a whole file start again; no unverified package is ready to load."
        status = hostSupportsResume == false ? "Paused. This host sent a whole-file transfer, which starts again. Existing models were kept." : "Paused. Completed segments and existing models were kept."
    }

    private func begin(allowDownload: Bool) {
        guard !isBusy else { return }
        if hasCurrentVerifiedInstallation {
            status = "This installed package is already verified and unchanged. Ready to load."
            return
        }
        revision += 1
        let expected = revision
        errorMessage = nil
        installedURL = nil
        verifiedStamp = nil
        verifiedAt = nil
        failureCategory = nil
        recoverySuggestion = nil
        receivedBytes = 0
        hostSupportsResume = nil
        progress = 0
        phase = existingFileAvailable ? .verifying : .downloading
        status = existingFileAvailable ? "Checking the existing model’s SHA-256…" : "Connecting to the model host…"
        let previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let checkpoint = ModelDownloadCheckpoint()
            do {
                try check(expected)
                try Self.validateManifest(manifest)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if existingFileAvailable {
                    phase = .verifying
                    let stamp = try Self.fileStamp(destinationURL)
                    verificationAttempts += 1
                    try await Self.verifyFile(at: destinationURL, manifest: manifest)
                    try check(expected)
                    guard try Self.fileStamp(destinationURL) == stamp else { throw RelayError.message("The installed model changed during verification. Recheck the file before loading.") }
                    try finish(destinationURL)
                    operation = nil
                    return
                }
                guard allowDownload else { throw RelayError.message("No recommended model is installed yet. Download it or choose a local .litertlm file.") }
                guard (1...ModelResumeProtocol.maximumChunkBytes).contains(chunkBytes) else { throw RelayError.message("Invalid model segment size.") }
                // Conservative free-space budget also permits a server to ignore Range and
                // return a full body. Low-space resume optimization is deliberately not claimed.
                try Self.checkAvailableSpace(at: directory, required: manifest.size)
                try Self.checkAvailableSpace(at: FileManager.default.temporaryDirectory, required: manifest.size)
                status = "Checking saved local transfer state…"
                var saved = try await checkpoint.open(manifest: manifest, directory: directory)
                try check(expected)
                resumableBytes = saved.offset
                hostSupportsResume = saved.etag == nil ? nil : true
                receivedBytes = saved.offset
                progress = Double(saved.offset) / Double(manifest.size)
                let configuration = sessionConfiguration ?? URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 86_400
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                var allowRanges = true
                while saved.offset < manifest.size {
                    try check(expected)
                    let offset = saved.offset
                    let end = min(manifest.size - 1, offset + chunkBytes - 1)
                    status = offset > 0 ? "Resuming from a checked local checkpoint…" : "Connecting to the model host…"
                    var request = URLRequest(url: manifest.sourceURL)
                    request.setValue("Relay-model-setup/0.2", forHTTPHeaderField: "User-Agent")
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    if allowRanges {
                        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                        if let etag = saved.etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }
                    }
                    let delegate = ModelDownloadProgress(maximumBytes: manifest.size, rangeOffset: offset, maximumChunkBytes: end - offset + 1) { [weak self] bytes, isRange in
                        Task { @MainActor in
                            guard let self, self.revision == expected, self.phase == .downloading else { return }
                            self.receivedBytes = bytes
                            self.hostSupportsResume = isRange
                            self.progress = min(1, max(0, Double(bytes) / Double(self.manifest.size)))
                            self.status = isRange ? "Downloading \(self.manifest.displayName)… Segments are saved after checks." : "Downloading \(self.manifest.displayName)… Whole-file transfer; pausing starts it again."
                        }
                    }
                    let temporaryURL: URL
                    let response: URLResponse
                    do {
                        (temporaryURL, response) = try await session.download(for: request, delegate: delegate)
                    } catch {
                        if let reason = delegate.failureReason { throw RelayError.message(reason) }
                        throw error
                    }
                    if let reason = delegate.failureReason {
                        try? FileManager.default.removeItem(at: temporaryURL)
                        throw RelayError.message(reason)
                    }
                    defer { try? FileManager.default.removeItem(at: temporaryURL) }
                    try check(expected)
                    let validation: ModelResumeProtocol.ValidatedResponse
                    do {
                        validation = try ModelResumeProtocol.validate(response: response, expectedTotal: manifest.size,
                            requestedOffset: offset, requestedEnd: end, expectedETag: saved.etag)
                        if !allowRanges, case .chunk = validation { throw RelayError.message("The host returned an unsolicited partial body. Nothing was installed.") }
                    } catch {
                        guard allowRanges else { throw error }
                        // A missing/changed validator or invalid range cannot be joined. One
                        // fresh full-body attempt follows; the original model is never touched.
                        try await checkpoint.discardOwned()
                        saved = try await checkpoint.open(manifest: manifest, directory: directory)
                        try check(expected)
                        allowRanges = false; resumableBytes = 0; receivedBytes = 0; progress = 0
                        continue
                    }
                    switch validation {
                    case .complete:
                        hostSupportsResume = false
                        phase = .verifying; receivedBytes = manifest.size; progress = 1
                        status = "Checking the complete model before installation…"
                        verificationAttempts += 1
                        try await Self.verifyFile(at: temporaryURL, manifest: manifest)
                        try check(expected)
                        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                        try finish(destinationURL)
                        try? await checkpoint.discardOwned()
                        if revision == expected { operation = nil }
                        return
                    case .chunk(let start, let last, _, let etag):
                        hostSupportsResume = true
                        let size = try temporaryURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                        guard size.isRegularFile == true, size.isSymbolicLink != true,
                              Int64(size.fileSize ?? -1) == last - start + 1 else { throw RelayError.message("The model segment ended at the wrong byte count. Its bytes were not appended.") }
                        saved = try await checkpoint.append(chunkURL: temporaryURL, expectedOffset: offset, etag: etag)
                        try check(expected)
                        resumableBytes = saved.offset; receivedBytes = saved.offset
                        progress = Double(saved.offset) / Double(manifest.size)
                    }
                }
                phase = .verifying; status = "Checking every model byte before installation…"
                verificationAttempts += 1
                guard try await checkpoint.fullDigest() == manifest.sha256.lowercased() else {
                    try await checkpoint.discardOwned()
                    throw RelayError.message("The complete model SHA-256 did not match. Only the owned invalid transfer was discarded; installed models were kept.")
                }
                let partialURL = try await checkpoint.finalURL()
                try await Self.verifyFile(at: partialURL, manifest: manifest)
                try check(expected)
                try FileManager.default.moveItem(at: partialURL, to: destinationURL)
                try finish(destinationURL)
                try? await checkpoint.discardOwned()
            } catch is CancellationError {
                try? await checkpoint.close()
                if revision == expected { phase = .cancelled; status = "Paused. Completed chunks are kept; the current segment restarts." }
            } catch {
                try? await checkpoint.close()
                guard revision == expected else { return }
                let category = Self.classifyFailure(error, existingPackage: existingFileAvailable && phase == .verifying)
                phase = .failed
                failureCategory = category
                recoverySuggestion = Self.recovery(for: category)
                errorMessage = error.localizedDescription
                status = "Model setup needs attention. " + (recoverySuggestion ?? "")
            }
            if revision == expected { operation = nil }
        }
    }

    private func check(_ expected: Int) throws {
        try Task.checkCancellation()
        guard revision == expected else { throw CancellationError() }
    }

    private func finish(_ url: URL) throws {
        verifiedStamp = try Self.fileStamp(url)
        verifiedAt = Date()
        receivedBytes = manifest.size
        progress = 1
        installedURL = url
        phase = .ready
        status = "Model verified and saved on this Mac. It is ready to load."
    }

    static func validateManifest(_ manifest: ModelManifest) throws {
        guard manifest.size > 0, manifest.size <= 8_589_934_592,
              manifest.sourceURL.scheme == "https", manifest.sourceURL.host?.isEmpty == false,
              manifest.sourceURL.user == nil, manifest.sourceURL.password == nil,
              manifest.sourceURL.query == nil, manifest.sourceURL.fragment == nil,
              !manifest.filename.hasPrefix("."), !manifest.filename.contains("\0"), manifest.filename.utf8.count <= 200,
              manifest.filename == URL(fileURLWithPath: manifest.filename).lastPathComponent,
              manifest.filename.hasSuffix(".litertlm"),
              manifest.sha256.count == 64, manifest.sha256 == manifest.sha256.lowercased(),
              manifest.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw RelayError.message("The model download specification is invalid.")
        }
    }

    static func validateResponse(_ response: URLResponse, expectedSize: Int64) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RelayError.message("The model host did not return a complete download. Check your connection and retry.")
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength == expectedSize else {
            throw RelayError.message("The download’s reported size differs from the pinned model. Nothing was installed.")
        }
    }

    static func classifyFailure(_ error: Error, existingPackage: Bool) -> FailureCategory {
        let value = error as NSError
        if value.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(value.code) { return .connection }
        if value.domain == NSCocoaErrorDomain, value.code == NSFileWriteOutOfSpaceError { return .diskSpace }
        if value.domain == NSPOSIXErrorDomain, value.code == Int(ENOSPC) { return .diskSpace }
        if value.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(value.code) { return .storageAccess }
        if value.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM), Int(EROFS)].contains(value.code) { return .storageAccess }
        if existingPackage { return .existingPackage }
        if error is RelayError { return .package }
        return .other
    }

    static func recovery(for category: FailureCategory) -> String {
        switch category {
        case .connection: "Check the connection and press Resume. Checked completed chunks are kept; the incomplete segment restarts. Existing models are kept."
        case .diskSpace: "Free space on the model and temporary-file volumes, then retry. Existing models and completed transfer checkpoints are kept."
        case .storageAccess: "Choose a writable local model location or fix its storage access, then retry or import a model. Existing files were not replaced."
        case .existingPackage: "The existing package was kept. Import another compatible model, or move the invalid package yourself before restarting the download. Retrying does not overwrite it."
        case .package: "Check the package and pinned source. Retry a fresh download or import a compatible local model; nothing unverified is ready to load."
        case .other: "Retry explicitly after checking the model folder and connection, or import a compatible local model. Saved completed chunks are checked before resuming."
        }
    }

    nonisolated private struct FileStamp: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }
    private static func fileStamp(_ url: URL) throws -> FileStamp {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw RelayError.message("The verified model is missing or is no longer a regular local file.")
        }
        return FileStamp(device: metadata.st_dev, inode: metadata.st_ino, size: metadata.st_size,
                         modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
                         changedSeconds: Int64(metadata.st_ctimespec.tv_sec), changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec))
    }

    private static func checkAvailableSpace(at directory: URL, required: Int64) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
        if let available, available < required + 268_435_456 {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [NSLocalizedDescriptionKey: "Free at least \(ByteCountFormatter.string(fromByteCount: required + 268_435_456, countStyle: .file)) for the model and temporary setup files, then retry."])
        }
    }

    /// Large files are read in bounded chunks away from the UI actor. Cancellation is checked per chunk.
    @concurrent static func verifyFile(at url: URL, manifest: ModelManifest) async throws {
        let before = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard before.isRegularFile == true, before.isSymbolicLink != true,
              Int64(before.fileSize ?? -1) == manifest.size else {
            throw RelayError.message("The model’s file size does not match the pinned package. The existing file was not replaced.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var read: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            read += Int64(data.count)
            guard read <= manifest.size else { throw RelayError.message("The model changed during verification. Nothing was installed.") }
            digest.update(data: data)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard read == manifest.size, actual == manifest.sha256.lowercased(),
              after.fileSize == before.fileSize, after.contentModificationDate == before.contentModificationDate else {
            throw RelayError.message("SHA-256 verification failed. The package was not installed or replaced; retry the download or select another model.")
        }
    }
}

/// URLSession owns this immutable delegate during the transfer; progress crosses to MainActor explicitly.
nonisolated final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let failureLock = NSLock()
    private var firstFailure: String?
    var failureReason: String? { failureLock.withLock { firstFailure } }
    private func recordFailure(_ reason: String) { failureLock.withLock { if firstFailure == nil { firstFailure = reason } } }
    let maximumBytes: Int64
    let rangeOffset: Int64
    let maximumChunkBytes: Int64
    let progress: @Sendable (Int64, Bool) -> Void
    init(maximumBytes: Int64, rangeOffset: Int64 = 0, maximumChunkBytes: Int64 = ModelResumeProtocol.maximumChunkBytes,
         progress: @escaping @Sendable (Int64, Bool) -> Void) {
        self.maximumBytes = maximumBytes; self.rangeOffset = rangeOffset
        self.maximumChunkBytes = maximumChunkBytes; self.progress = progress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let reason = rejectionReason(response: downloadTask.response, receivedBytes: totalBytesWritten) {
            recordFailure(reason)
            downloadTask.cancel()
            return
        }
        let isRange = (downloadTask.response as? HTTPURLResponse)?.statusCode == 206
        progress((isRange ? rangeOffset : 0) + totalBytesWritten, isRange)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { recordFailure("The model host attempted an unsafe redirect. Only HTTPS without credentials is allowed."); completionHandler(nil); return }
        completionHandler(request)
    }
    /// Header/body budgets deliberately do not validate ETag or Content-Range: those
    /// failures retain the caller's single fresh whole-file fallback.
    func rejectionReason(response: URLResponse?, receivedBytes: Int64) -> String? {
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
            return "The model host returned an unexpected HTTP response. Nothing was installed."
        }
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let encoding, !encoding.isEmpty, encoding != "identity" {
            return "The model host returned an encoded body instead of the pinned model bytes."
        }
        let mime = http.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("text/" ) || mime.contains("html") || mime.contains("json") || mime.contains("xml") {
            return "The model host returned a text or error page instead of a model package."
        }
        let limit = http.statusCode == 206 ? min(maximumChunkBytes, maximumBytes - rangeOffset) : maximumBytes
        if limit <= 0 || receivedBytes < 0 || receivedBytes > limit || http.expectedContentLength > limit {
            return "The model response exceeded the requested byte budget. Nothing was installed."
        }
        return nil
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
