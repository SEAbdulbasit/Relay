import AppKit
import SwiftUI

struct AppUpdateView: View {
    @State private var checker = ReleaseUpdateChecker()
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Relay updates").font(.relayHeadline.weight(.semibold))
                Text(installedDescription).font(.relayBody)
                Text("Checks the public GitHub releases when you ask. Download and install updates from the release page.")
                    .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Check for updates") {
                    guard checkTask == nil else { return }
                    checkTask = Task {
                        await checker.check()
                        checkTask = nil
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(checker.state == .checking)
                .accessibilityIdentifier("updates.check")
                if checker.state == .checking { ProgressView().controlSize(.small).accessibilityHidden(true) }
            }
            Text(statusDescription).font(.relayBody).textSelection(.enabled)
                .accessibilityIdentifier("updates.status")
            if let release = checker.release {
                Button("View release and downloads") { NSWorkspace.shared.open(release.url) }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("updates.release")
            }
            Button("GitHub · SEAbdulbasit/Relay", systemImage: "arrow.up.right") {
                NSWorkspace.shared.open(RelayReleaseSource.releasesPage)
            }
            .buttonStyle(RelayGhostButtonStyle())
            .accessibilityIdentifier("updates.source")
            if let checked = checker.lastCheckedAt {
                Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
            }
        }
        .onDisappear { checkTask?.cancel() }
    }

    private var installedDescription: String {
        guard let version = checker.installedVersion else { return "Installed version unavailable" }
        return "Installed Relay \(version)" + (checker.installedBuild.map { " · build \($0)" } ?? "")
    }

    private var statusDescription: String {
        switch checker.state {
        case .idle: "Ready to check the latest stable release."
        case .checking: "Checking GitHub…"
        case .noPublishedRelease: "A stable Relay release has not been published yet."
        case .available(let release): "Relay \(release.tag) is available. Review its release notes before downloading."
        case .current(let release): "Your installed version matches the latest stable version, \(release.tag). Build details are available in the release notes."
        case .ahead(let release): "Your installed version is newer than the latest stable release, \(release.tag)."
        case .incomparable(let release): "GitHub lists stable release \(release.tag). Review the release notes to compare it with this build."
        case .failed(let message): message
        }
    }
}
