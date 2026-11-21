import AppKit
import Foundation
import Observation
import SwiftUI

@Observable @MainActor
final class OCRReadinessSettings {
    static let visibilityRefreshInterval: Duration = .milliseconds(500)

    enum Status: Sendable, Equatable {
        case preparing
        case ready
        case failed
    }

    private(set) var status: Status
    private(set) var isRetrying = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let execution: LocalOCRExecution
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryTaskID: UUID?

    init(
        execution: LocalOCRExecution = .shared,
        timeout: Duration = DocumentOCRPreparation.defaultTimeout
    ) {
        self.execution = execution
        self.timeout = timeout
        self.status = Self.deriveStatus(from: execution, isRetrying: false)
    }

    var canRetry: Bool {
        status == .failed && !isRetrying
    }

    var statusDescription: String {
        switch status {
        case .ready:
            "Ready"
        case .preparing:
            "Preparing on this Mac…"
        case .failed:
            "Unavailable. Initial preparation did not complete."
        }
    }

    static func deriveStatus(from execution: LocalOCRExecution, isRetrying: Bool = false) -> Status {
        do {
            try execution.checkAvailability(for: .document)
            if case .ready = execution.documentReadinessState {
                return .ready
            }
            return .preparing
        } catch LocalOCRExecution.Failure.documentRecognitionPreparing {
            return .preparing
        } catch {
            if isRetrying {
                return .preparing
            }
            if case .failed = execution.documentReadinessState {
                return .failed
            }
            return .preparing
        }
    }

    func refresh() {
        let current = Self.deriveStatus(from: execution, isRetrying: isRetrying)
        if status != current {
            status = current
        }
        if current == .ready, errorMessage != nil {
            errorMessage = nil
        }
    }

    func observeWhileVisible(pollInterval: Duration = OCRReadinessSettings.visibilityRefreshInterval) async {
        refresh()
        let interval = max(.milliseconds(10), pollInterval)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                break
            }
            guard !Task.isCancelled else { break }
            refresh()
        }
    }

    @discardableResult
    func retry() -> Task<Void, Never>? {
        if let existing = retryTask {
            return existing
        }
        refresh()
        guard status == .failed else {
            return nil
        }

        let id = UUID()
        retryTaskID = id
        isRetrying = true
        errorMessage = nil
        status = .preparing

        let execution = self.execution
        let timeout = self.timeout
        let task = Task { @MainActor [weak self] in
            do {
                try await execution.prepareDocumentReadiness(timeout: timeout)
                guard let self, self.finishRetryTaskIfCurrent(id) else { return }
                self.refresh()
            } catch is CancellationError {
                guard let self, self.finishRetryTaskIfCurrent(id) else { return }
                self.refresh()
            } catch let failure as LocalOCRExecution.Failure {
                guard let self, self.finishRetryTaskIfCurrent(id) else { return }
                self.refresh()
                if self.status != .ready {
                    self.errorMessage = failure.localizedDescription
                }
            } catch {
                guard let self, self.finishRetryTaskIfCurrent(id) else { return }
                self.refresh()
                if self.status != .ready {
                    self.errorMessage = LocalOCRExecution.Failure.documentRecognitionUnavailable.localizedDescription
                }
            }
        }
        retryTask = task
        return task
    }

    func cancelWaiter() {
        let task = retryTask
        retryTask = nil
        retryTaskID = nil
        isRetrying = false
        task?.cancel()
        refresh()
    }

    private func finishRetryTaskIfCurrent(_ id: UUID) -> Bool {
        guard retryTaskID == id else { return false }
        retryTask = nil
        retryTaskID = nil
        isRetrying = false
        return true
    }

    isolated deinit {
        retryTask?.cancel()
    }
}

struct OCRReadinessSettingsView: View {
    @State private var settings = OCRReadinessSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text.viewfinder")
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Text Recognition (OCR)")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Prepares on-device Apple Vision text recognition in the background for images, scanned PDFs, and window reads.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                RelayHealthDot(color: statusColor)
                Text(settings.statusDescription)
                    .font(.relayCaptionStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.ocrReadinessStatus")
                if settings.status == .preparing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }

            if settings.status == .failed {
                HStack(spacing: 10) {
                    Button("Retry preparation") {
                        settings.retry()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(!settings.canRetry)
                    .accessibilityIdentifier("settings.ocrReadinessRetry")
                }

                if let errorMessage = settings.errorMessage {
                    Text(errorMessage)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.accentCoral)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            await settings.observeWhileVisible()
        }
        .onAppear { settings.refresh() }
        .onDisappear { settings.cancelWaiter() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }

    private var statusColor: Color {
        switch settings.status {
        case .ready:
            RelayColors.accentEmerald
        case .preparing:
            RelayColors.accentAmber
        case .failed:
            RelayColors.accentCoral
        }
    }
}
