import Foundation
import Testing
@testable import Relay

@MainActor
struct ReleaseUpdateCheckerTests {
    private func payload(tag: String = "v0.2.0", url: String? = nil, draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": url ?? "https://github.com/SEAbdulbasit/Relay/releases/tag/\(tag)",
            "draft": draft, "prerelease": prerelease, "published_at": "2026-11-06T12:00:00Z",
        ])
    }

    @Test func numericVersionsCompareAsNumbersAndUnsupportedTagsStayUncomparable() throws {
        #expect(try #require(RelayReleaseVersion("0.9.0")) < #require(RelayReleaseVersion("v0.10.0")))
        #expect(RelayReleaseVersion("1.2") == RelayReleaseVersion("1.2.0"))
        for invalid in ["", "1", "v1.2.3-beta.1", "1.2.3.4", "1.2.-3", " 1.2.0", String(repeating: "9", count: 32) + ".0"] {
            #expect(RelayReleaseVersion(invalid) == nil)
        }
    }

    @Test func checkIsExplicitAndUsesOnlyThePublicRepositoryRequest() async throws {
        var requests: [URLRequest] = []
        let latest = try payload()
        let checker = ReleaseUpdateChecker(installedVersion: "0.1.0", installedBuild: "1", fetch: { request in
            requests.append(request)
            return .init(statusCode: 200, data: latest)
        })
        #expect(requests.isEmpty)
        #expect(checker.state == .idle)
        await checker.check()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url == RelayReleaseSource.latest)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
        guard case .available(let release) = checker.state else { Issue.record("Expected a newer release"); return }
        #expect(release.tag == "v0.2.0")
        #expect(release.url == URL(string: "https://github.com/SEAbdulbasit/Relay/releases/tag/v0.2.0"))
        #expect(checker.lastCheckedAt != nil)
    }

    @Test(arguments: ["0.2.0", "0.3.0", "development"])
    func distinguishesMatchingNewerLocalAndUnknownVersions(installed: String) async throws {
        let latest = try payload()
        let checker = ReleaseUpdateChecker(installedVersion: installed, fetch: { _ in .init(statusCode: 200, data: latest) })
        await checker.check()
        let release = try #require(checker.release)
        switch installed {
        case "0.2.0": #expect(checker.state == .current(release))
        case "0.3.0": #expect(checker.state == .ahead(release))
        default: #expect(checker.state == .incomparable(release))
        }
    }

    @Test func missingLatestConfirmsTheListingBeforeReportingNoPublishedRelease() async {
        var requests: [URL] = []
        let checker = ReleaseUpdateChecker(installedVersion: "0.1.0", fetch: { request in
            requests.append(try #require(request.url))
            return request.url == RelayReleaseSource.latest
                ? .init(statusCode: 404, data: Data()) : .init(statusCode: 200, data: Data("[]".utf8))
        })
        await checker.check()
        #expect(requests == [RelayReleaseSource.latest, RelayReleaseSource.listing])
        #expect(checker.state == .noPublishedRelease)
        #expect(checker.lastCheckedAt != nil)

        let unavailable = ReleaseUpdateChecker(fetch: { _ in .init(statusCode: 404, data: Data()) })
        await unavailable.check()
        guard case .failed = unavailable.state else { Issue.record("An unavailable repository was treated as an empty release list"); return }
        #expect(unavailable.lastCheckedAt == nil)
    }

    @Test func fallbackListingRejectsMalformedRowsAndCanReadAPublishedRelease() async throws {
        for row in [Data("[{}]".utf8), try JSONSerialization.data(withJSONObject: [JSONSerialization.jsonObject(with: payload())])] {
            let checker = ReleaseUpdateChecker(installedVersion: "0.1.0", fetch: { request in
                request.url == RelayReleaseSource.latest ? .init(statusCode: 404, data: Data()) : .init(statusCode: 200, data: row)
            })
            await checker.check()
            if row == Data("[{}]".utf8) {
                guard case .failed = checker.state else { Issue.record("Malformed release row was accepted"); continue }
            } else {
                #expect(checker.release?.tag == "v0.2.0")
            }
        }
    }

    @Test func rejectsUntrustedReleaseLinksPreviewsAndMalformedResponses() async throws {
        let rejected = [
            try payload(url: "https://github.com/another-owner/Relay/releases/tag/v0.2.0"),
            try payload(url: "https://github.com.evil.example/SEAbdulbasit/Relay/releases/tag/v0.2.0"),
            try payload(url: "https://user@github.com/SEAbdulbasit/Relay/releases/tag/v0.2.0"),
            try payload(url: "http://github.com/SEAbdulbasit/Relay/releases/tag/v0.2.0"),
            try payload(url: "https://github.com/SEAbdulbasit/Relay/releases/tag/v0.3.0"),
            try payload(url: "https://github.com/SEAbdulbasit/Relay/releases/tag/v0.2.0?redirect=https://example.com"),
            try payload(draft: true), try payload(prerelease: true), Data("invalid".utf8),
            Data(repeating: 32, count: RelayReleaseSource.maximumResponseBytes + 1),
        ]
        for data in rejected {
            let checker = ReleaseUpdateChecker(fetch: { _ in .init(statusCode: 200, data: data) })
            await checker.check()
            guard case .failed = checker.state else { Issue.record("Invalid release metadata was accepted"); continue }
            #expect(checker.release == nil)
            #expect(checker.lastCheckedAt == nil)
        }
    }

    @Test func rateLimitsDelayFurtherNetworkCallsAndOfflineIsAVisibleFailure() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var calls = 0
        let latest = try payload()
        let checker = ReleaseUpdateChecker(installedVersion: "0.1.0", clock: { now }, fetch: { _ in
            calls += 1
            return calls == 1 ? .init(statusCode: 429, data: Data(), retryAt: now.addingTimeInterval(120)) : .init(statusCode: 200, data: latest)
        })
        await checker.check()
        await checker.check()
        #expect(calls == 1)
        guard case .failed(let limit) = checker.state else { Issue.record("Expected rate-limit guidance"); return }
        #expect(limit.contains("limiting"))
        now = now.addingTimeInterval(121)
        await checker.check()
        #expect(calls == 2)
        #expect(checker.release != nil)

        let offline = ReleaseUpdateChecker(fetch: { _ in throw URLError(.notConnectedToInternet) })
        await offline.check()
        guard case .failed(let message) = offline.state else { Issue.record("Offline check looked successful"); return }
        #expect(message.contains("connection"))
        #expect(offline.lastCheckedAt == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationAndConcurrentCheckPreserveThePreviousResult() async throws {
        let latest = try payload()
        var calls = 0
        let checker = ReleaseUpdateChecker(installedVersion: "0.2.0", fetch: { _ in
            calls += 1
            if calls > 1 { try await Task.sleep(for: .seconds(30)) }
            return .init(statusCode: 200, data: latest)
        })
        await checker.check()
        let original = checker.state
        let repeated = Task { await checker.check() }
        while calls < 2 { await Task.yield() }
        await checker.check()
        #expect(calls == 2)
        repeated.cancel()
        await repeated.value
        #expect(checker.state == original)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_PUBLIC_UPDATE_CHECK"] == "1"), .timeLimit(.minutes(1)))
    func publicReleaseSourceIsReadableWithoutAnAccount() async {
        let checker = ReleaseUpdateChecker(installedVersion: "0.1.0", installedBuild: "1")
        await checker.check()
        if case .failed(let reason) = checker.state { Issue.record(Comment(rawValue: reason)) }
        #expect(checker.lastCheckedAt != nil)
    }
}
