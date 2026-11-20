import Foundation

/// Fixed TLS origin, no redirects/cookies/credential-store/challenge credentials.
/// System TLS trust is handled normally; HTTP error/provider bodies stay closed.
nonisolated enum OpenRouterHTTPTransport {
    static let maximumChunkBytes = 8_192
    static let maximumQueuedChunks = 16
    nonisolated private final class Delegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
    static func make() -> OpenRouterClient.Transport { make(ownedLoopback: nil) }
    /// Explicit trusted test transport only. No saved/user/model endpoint can
    /// select this route; tests supply a fake key and their own literal server.
    static func ownedLoopback(_ endpoint: LMStudioEndpoint) -> OpenRouterClient.Transport { make(ownedLoopback: endpoint) }
    private static func make(ownedLoopback: LMStudioEndpoint?) -> OpenRouterClient.Transport {
        .init(open: { original in
            guard let logicalURL = original.url,
                  [OpenRouterClient.modelsURL, OpenRouterClient.completionsURL].contains(logicalURL),
                  (logicalURL == OpenRouterClient.modelsURL && original.httpMethod == "GET" && original.httpBody == nil)
                    || (logicalURL == OpenRouterClient.completionsURL && original.httpMethod == "POST"),
                  let auth = original.value(forHTTPHeaderField: "Authorization"), auth.hasPrefix("Bearer "),
                  original.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
                  original.value(forHTTPHeaderField: "X-API-Key") == nil,
                  original.value(forHTTPHeaderField: "Cookie") == nil else { throw OpenRouterFailure.protocolFailure }
            var request = original
            if let endpoint = ownedLoopback {
                request.url = logicalURL == OpenRouterClient.modelsURL ? endpoint.modelsURL : endpoint.completionsURL
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 180; configuration.timeoutIntervalForResource = 180
            configuration.waitsForConnectivity = false; configuration.allowsCellularAccess = false
            let delegate = Delegate()
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, let responseURL = http.url else { session.invalidateAndCancel(); throw LMStudioFailure.malformedResponse }
                guard responseURL == request.url else { throw LMStudioFailure.invalidEndpoint }
                guard (200...299).contains(http.statusCode) else { throw OpenRouterFailure.rejected(http.statusCode) }
                let initialBudget = try LMStudioHTTPReadBudget(expectedLength: response.expectedContentLength)
                let stream = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(maximumQueuedChunks)) { continuation in
                    let reader = Task {
                        do {
                            var chunk = Data(), budget = initialBudget
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                try budget.accept(1)
                                chunk.append(byte)
                                if chunk.count == maximumChunkBytes || byte == 10 {
                                    switch continuation.yield(chunk) {
                                    case .enqueued: break
                                    case .dropped: throw LMStudioFailure.responseLimit
                                    case .terminated: throw CancellationError()
                                    @unknown default: throw OpenRouterFailure.unavailable
                                    }
                                    chunk.removeAll(keepingCapacity: true)
                                }
                            }
                            if !chunk.isEmpty {
                                switch continuation.yield(chunk) {
                                case .enqueued: break
                                case .dropped: throw LMStudioFailure.responseLimit
                                case .terminated: throw CancellationError()
                                @unknown default: throw OpenRouterFailure.unavailable
                                }
                            }
                            continuation.finish()
                        } catch {
                            bytes.task.cancel(); session.invalidateAndCancel()
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in reader.cancel(); bytes.task.cancel(); session.invalidateAndCancel() }
                }
                return .init(url: logicalURL, status: http.statusCode,
                    contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "", body: stream,
                    cancel: { bytes.task.cancel(); session.invalidateAndCancel() })
            } catch {
                session.invalidateAndCancel()
                if error is CancellationError { throw CancellationError() }
                if let error = error as? OpenRouterFailure { throw error }
                throw OpenRouterFailure.unavailable
            }
        })
    }
}
