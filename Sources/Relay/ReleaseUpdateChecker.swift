import Foundation
import Observation

nonisolated struct RelayReleaseVersion: Comparable, Equatable, Sendable {
    let components: [Int]

    init?(_ value: String) {
        let digits = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard digits.utf8.count <= 32, (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

nonisolated struct PublishedRelayRelease: Equatable, Sendable {
    let tag: String
    let url: URL
    var version: RelayReleaseVersion? { RelayReleaseVersion(tag) }
}

nonisolated struct ReleaseCheckResponse: Sendable {
    let statusCode: Int
    let data: Data
    var retryAt: Date?
}

nonisolated enum RelayReleaseSource {
    static let releasesPage = URL(string: "https://github.com/SEAbdulbasit/Relay/releases")!
    static let latest = URL(string: "https://api.github.com/repos/SEAbdulbasit/Relay/releases/latest")!
    static let listing = URL(string: "https://api.github.com/repos/SEAbdulbasit/Relay/releases?per_page=1")!
    static let maximumResponseBytes = 262_144

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Relay-Update-Check", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    static func fetch(_ request: URLRequest) async throws -> ReleaseCheckResponse {
        guard request.url == latest || request.url == listing, request.httpMethod == "GET" else {
            throw ReleaseCheckFailure.invalidResponse
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: ReleaseRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == request.url,
              response.expectedContentLength <= maximumResponseBytes else { throw ReleaseCheckFailure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw ReleaseCheckFailure.invalidResponse }
            data.append(byte)
        }
        let retryAt = retryDate(response, now: Date())
        return ReleaseCheckResponse(statusCode: response.statusCode, data: data, retryAt: retryAt)
    }

    static func release(from data: Data) throws -> PublishedRelayRelease {
        let release = try JSONDecoder().decode(ReleasePayload.self, from: data)
        guard !release.draft, !release.prerelease, let published = release.publishedAt,
              ISO8601DateFormatter().date(from: published) != nil,
              !release.tag.isEmpty, release.tag.utf8.count <= 128,
              release.tag != ".", release.tag != "..",
              !release.tag.contains("/"), !release.tag.contains("\\"),
              !release.tag.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URL(string: release.url), isTrustedReleasePage(url, tag: release.tag) else {
            throw ReleaseCheckFailure.invalidResponse
        }
        return PublishedRelayRelease(tag: release.tag, url: url)
    }

    static func isTrustedReleasePage(_ url: URL, tag: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return false }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 6 && parts[0].isEmpty && parts[1].lowercased() == "seabdulbasit" &&
            parts[2].lowercased() == "relay" && parts[3] == "releases" && parts[4] == "tag" &&
            parts[5].utf8.elementsEqual(tag.utf8)
    }

    private static func retryDate(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard response.statusCode == 429 || response.statusCode == 403 &&
                (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
                 response.value(forHTTPHeaderField: "Retry-After") != nil) else { return nil }
        if let raw = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(max(60, min(seconds, 86_400)))
        }
        if let raw = response.value(forHTTPHeaderField: "X-RateLimit-Reset"), let seconds = Double(raw), seconds.isFinite,
           seconds > now.timeIntervalSince1970, seconds <= now.timeIntervalSince1970 + 86_400 {
            return Date(timeIntervalSince1970: seconds)
        }
        return now.addingTimeInterval(60)
    }

    private struct ReleasePayload: Decodable {
        let tag: String
        let url: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: String?
        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", url = "html_url", draft, prerelease, publishedAt = "published_at"
        }
    }
}

/// A repository move needs a new trusted source rather than following a redirect silently.
nonisolated private final class ReleaseRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated private enum ReleaseCheckFailure: Error {
    case invalidResponse
    case unavailable
    case rateLimited(Date)
}

@Observable @MainActor
final class ReleaseUpdateChecker {
    enum State: Equatable {
        case idle, checking, noPublishedRelease
        case available(PublishedRelayRelease)
        case current(PublishedRelayRelease)
        case ahead(PublishedRelayRelease)
        case incomparable(PublishedRelayRelease)
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var lastCheckedAt: Date?
    let installedVersion: String?
    let installedBuild: String?
    @ObservationIgnored private let fetch: (URLRequest) async throws -> ReleaseCheckResponse
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var nextAllowedCheck: Date?

    init(
        installedVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        installedBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        clock: @escaping () -> Date = Date.init,
        fetch: @escaping (URLRequest) async throws -> ReleaseCheckResponse = RelayReleaseSource.fetch
    ) {
        self.installedVersion = installedVersion
        self.installedBuild = installedBuild
        self.clock = clock
        self.fetch = fetch
    }

    var release: PublishedRelayRelease? {
        switch state {
        case .available(let release), .current(let release), .ahead(let release), .incomparable(let release): release
        default: nil
        }
    }

    func check() async {
        guard state != .checking else { return }
        if let nextAllowedCheck, clock() < nextAllowedCheck {
            state = .failed("GitHub is limiting update checks. Try again after \(nextAllowedCheck.formatted(date: .omitted, time: .shortened)).")
            return
        }
        let previous = state
        state = .checking
        do {
            try Task.checkCancellation()
            let latest = try await response(from: RelayReleaseSource.latest)
            let published: PublishedRelayRelease?
            if latest.statusCode == 404 {
                // A 404 can also mean an unavailable/private repository. Confirm that the
                // public release listing is readable before calling this a no-release state.
                let listing = try await response(from: RelayReleaseSource.listing)
                guard listing.statusCode == 200,
                      let rows = try JSONSerialization.jsonObject(with: listing.data) as? [[String: Any]], rows.count <= 1 else {
                    throw ReleaseCheckFailure.unavailable
                }
                if let row = rows.first {
                    guard let draft = row["draft"] as? Bool, let prerelease = row["prerelease"] as? Bool else {
                        throw ReleaseCheckFailure.invalidResponse
                    }
                    published = !draft && !prerelease ? try RelayReleaseSource.release(from: JSONSerialization.data(withJSONObject: row)) : nil
                } else { published = nil }
            } else {
                guard latest.statusCode == 200 else { throw ReleaseCheckFailure.unavailable }
                published = try RelayReleaseSource.release(from: latest.data)
            }
            try Task.checkCancellation()
            lastCheckedAt = clock()
            nextAllowedCheck = nil
            guard let published else { state = .noPublishedRelease; return }
            guard let installedVersion, let installed = RelayReleaseVersion(installedVersion), let remote = published.version else {
                state = .incomparable(published)
                return
            }
            if installed < remote { state = .available(published) }
            else if remote < installed { state = .ahead(published) }
            else { state = .current(published) }
        } catch is CancellationError {
            state = previous
        } catch ReleaseCheckFailure.rateLimited(let retryAt) {
            nextAllowedCheck = retryAt
            state = .failed("GitHub is limiting update checks. Try again after \(retryAt.formatted(date: .omitted, time: .shortened)).")
        } catch let error as URLError where error.code == .cancelled {
            state = previous
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(error.code) {
            state = .failed("Relay couldn’t reach GitHub. Check your connection and try again.")
        } catch {
            state = .failed("Relay couldn’t verify the public release information. Open the GitHub releases page to check manually.")
        }
    }

    private func response(from url: URL) async throws -> ReleaseCheckResponse {
        try Task.checkCancellation()
        let response = try await fetch(RelayReleaseSource.request(url))
        try Task.checkCancellation()
        guard response.data.count <= RelayReleaseSource.maximumResponseBytes else { throw ReleaseCheckFailure.invalidResponse }
        if response.statusCode == 429 || response.statusCode == 403 && response.retryAt != nil {
            throw ReleaseCheckFailure.rateLimited(response.retryAt ?? clock().addingTimeInterval(60))
        }
        return response
    }
}
