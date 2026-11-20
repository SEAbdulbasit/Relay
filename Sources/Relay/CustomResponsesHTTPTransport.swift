import Foundation

/// Ephemeral transport for custom Responses endpoints.
/// Non-loopback endpoints require HTTPS with default system TLS server trust;
/// literal loopback endpoints (127.0.0.1 / ::1) may use HTTP.
/// Redirects, cookies, caches, credentials storage, and inherited proxies are disabled.
nonisolated enum CustomResponsesHTTPTransport {
    static let maximumChunkBytes = 8_192
    static let maximumQueuedChunks = 16

    nonisolated private final class Delegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            completionHandler(
                challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                    ? .performDefaultHandling
                    : .cancelAuthenticationChallenge,
                nil
            )
        }
    }

    static func make() -> LMStudioClient.Transport {
        .init(open: { request in
            let endpoint = try validateOutboundRequest(request)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0,
                "ProxyAutoDiscoveryEnable": 0
            ]
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 180
            configuration.waitsForConnectivity = false
            configuration.allowsCellularAccess = false

            let delegate = Delegate()
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, let responseURL = http.url else {
                    session.invalidateAndCancel()
                    throw CustomResponsesFailure.invalidResponse
                }
                guard responseURL == request.url,
                      responseURL == endpoint.modelsURL || responseURL == endpoint.responsesURL else {
                    session.invalidateAndCancel()
                    throw CustomResponsesFailure.invalidBaseURL
                }
                switch http.statusCode {
                case 200...299:
                    break
                case 401, 403:
                    session.invalidateAndCancel()
                    throw CustomResponsesFailure.unauthorized
                case 429:
                    session.invalidateAndCancel()
                    throw CustomResponsesFailure.rateLimited
                default:
                    session.invalidateAndCancel()
                    throw CustomResponsesFailure.requestRejected
                }
                let initialBudget: LMStudioHTTPReadBudget
                do {
                    initialBudget = try LMStudioHTTPReadBudget(expectedLength: response.expectedContentLength)
                } catch LMStudioFailure.responseLimit {
                    session.invalidateAndCancel()
                    throw CustomResponsesFailure.responseTooLarge
                } catch {
                    session.invalidateAndCancel()
                    throw CustomResponsesFailure.invalidResponse
                }
                let stream = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(maximumQueuedChunks)) { continuation in
                    let reader = Task {
                        do {
                            var chunk = Data(), budget = initialBudget
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                do {
                                    try budget.accept(1)
                                } catch LMStudioFailure.responseLimit {
                                    throw CustomResponsesFailure.responseTooLarge
                                }
                                chunk.append(byte)
                                if chunk.count == maximumChunkBytes || byte == 10 {
                                    switch continuation.yield(chunk) {
                                    case .enqueued: break
                                    case .dropped: throw CustomResponsesFailure.responseTooLarge
                                    case .terminated: throw CancellationError()
                                    @unknown default: throw CustomResponsesFailure.streamDisconnected
                                    }
                                    chunk.removeAll(keepingCapacity: true)
                                }
                            }
                            if !chunk.isEmpty {
                                switch continuation.yield(chunk) {
                                case .enqueued: break
                                case .dropped: throw CustomResponsesFailure.responseTooLarge
                                case .terminated: throw CancellationError()
                                @unknown default: throw CustomResponsesFailure.streamDisconnected
                                }
                            }
                            continuation.finish()
                        } catch {
                            bytes.task.cancel()
                            session.invalidateAndCancel()
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in
                        reader.cancel()
                        bytes.task.cancel()
                        session.invalidateAndCancel()
                    }
                }
                return .init(
                    url: responseURL,
                    status: http.statusCode,
                    contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
                    body: stream,
                    cancel: {
                        bytes.task.cancel()
                        session.invalidateAndCancel()
                    }
                )
            } catch {
                session.invalidateAndCancel()
                if error is CancellationError { throw CancellationError() }
                if let error = error as? CustomResponsesFailure { throw error }
                throw CustomResponsesFailure.requestRejected
            }
        })
    }

    static func makeRequest(
        url: URL,
        method: String,
        body: Data? = nil,
        apiKey: Data?,
        endpoint: CustomResponsesEndpoint,
        requiresAPIKey: Bool
    ) throws -> URLRequest {
        guard url == endpoint.modelsURL || url == endpoint.responsesURL else {
            throw CustomResponsesFailure.invalidBaseURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")

        if let apiKey {
            let validKey = try CustomResponsesCredentials.validateKeyData(apiKey)
            guard let token = String(data: validKey, encoding: .utf8) else {
                throw CustomResponsesFailure.invalidAPIKey
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            guard endpoint.isLoopback && !requiresAPIKey else {
                throw CustomResponsesFailure.missingAPIKey
            }
        }

        if let body {
            guard url == endpoint.responsesURL, method == "POST" else {
                throw CustomResponsesFailure.invalidBaseURL
            }
            request.httpBody = body
        }

        _ = try validateOutboundRequest(request, expectedEndpoint: endpoint, requiresAPIKey: requiresAPIKey)
        return request
    }

    @discardableResult
    static func validateOutboundRequest(
        _ request: URLRequest,
        expectedEndpoint: CustomResponsesEndpoint? = nil,
        requiresAPIKey: Bool? = nil
    ) throws -> CustomResponsesEndpoint {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw CustomResponsesFailure.invalidBaseURL
        }
        let path = components.percentEncodedPath
        let basePath: String
        let isModels: Bool
        if path.hasSuffix("/models") {
            basePath = String(path.dropLast("/models".count))
            isModels = true
        } else if path.hasSuffix("/responses") {
            basePath = String(path.dropLast("/responses".count))
            isModels = false
        } else {
            throw CustomResponsesFailure.invalidBaseURL
        }

        var baseComponents = components
        baseComponents.percentEncodedPath = basePath.isEmpty ? "/v1" : basePath
        guard let baseURLString = baseComponents.url?.absoluteString else {
            throw CustomResponsesFailure.invalidBaseURL
        }
        let endpoint = try CustomResponsesEndpoint(parsing: baseURLString)
        if let expectedEndpoint, endpoint != expectedEndpoint {
            throw CustomResponsesFailure.invalidBaseURL
        }
        guard url == (isModels ? endpoint.modelsURL : endpoint.responsesURL),
              request.httpShouldHandleCookies == false else {
            throw CustomResponsesFailure.invalidBaseURL
        }

        let headers = request.allHTTPHeaderFields ?? [:]
        for (name, _) in headers {
            let lowered = name.lowercased()
            if lowered == "cookie" || lowered == "proxy-authorization" || lowered == "x-api-key" {
                throw CustomResponsesFailure.invalidAPIKey
            }
        }

        // The transport does not know the selected local policy. Its typed
        // client/makeRequest already enforce an explicitly required local key.
        // Only literal loopback may omit Authorization at this boundary.
        let mustHaveKey = (requiresAPIKey ?? false) || !endpoint.isLoopback
        if let auth = request.value(forHTTPHeaderField: "Authorization") {
            guard auth.hasPrefix("Bearer ") else {
                throw CustomResponsesFailure.invalidAPIKey
            }
            let keySlice = Data(auth.dropFirst("Bearer ".count).utf8)
            _ = try CustomResponsesCredentials.validateKeyData(keySlice)
        } else if mustHaveKey {
            throw CustomResponsesFailure.missingAPIKey
        }

        if isModels {
            guard request.httpMethod == "GET", request.httpBody == nil else {
                throw CustomResponsesFailure.invalidBaseURL
            }
        } else {
            guard request.httpMethod == "POST",
                  let body = request.httpBody,
                  body.count <= LMStudioWireCodec.maximumInputBytes + 6 * 1_024 * 1_024 else {
                throw CustomResponsesFailure.invalidBaseURL
            }
        }
        return endpoint
    }
}
