import SwiftUI

/// The first-run workspace uses the real local calculator, never a staged response.
struct OnboardingWorkbenchCalculator: View {
    @Binding var expression: String
    let state: OnboardingCoordinator.CalculatorTrialState
    let run: @MainActor () -> Void

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "function")
                    .foregroundStyle(RelayColors.workbenchAccent)
                Text("A REAL LOCAL ACTION")
                    .font(.relayEyebrow)
                    .tracking(1.4)
                    .foregroundStyle(RelayColors.textSecondary)
                Spacer()
                Text("No account needed")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
            }
            .padding(.bottom, 20)

            Text("Start with something real.")
                .font(.system(size: 21, weight: .medium))
                .tracking(-0.5)
                .foregroundStyle(RelayColors.textPrimary)
            Text("Edit the expression, run it on this Mac, and inspect the result.")
                .font(.relayBody)
                .foregroundStyle(RelayColors.textSecondary)
                .padding(.top, 6)
                .padding(.bottom, 18)

            inputRow
            Rectangle().fill(RelayColors.borderDefault).frame(height: 1)
                .padding(.vertical, 20)
            result
        }
        .padding(24)
        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
                .fill(RelayColors.workbenchAccent)
                .frame(width: 3)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RelayColors.borderDefault, lineWidth: 1)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("=").foregroundStyle(RelayColors.workbenchAccent)
                TextField("Arithmetic expression", text: $expression)
                    .textFieldStyle(.plain)
                    .disabled(isRunning)
                    .onSubmit {
                        guard !isRunning, !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        run()
                    }
                    .accessibilityIdentifier("onboarding.calculator.expression")
            }
            .font(.system(size: 17, weight: .medium, design: .monospaced))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            }
            Button(action: run) {
                HStack(spacing: 8) {
                    Text(isRunning ? "Calculating…" : "Calculate locally")
                    if !isRunning { Image(systemName: "arrow.right") }
                }
                .font(.relayBodyStrong)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 28)
            }
            .buttonStyle(RelayPrimaryButtonStyle())
            .disabled(isRunning || expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("onboarding.calculator.run")
        }
    }

    @ViewBuilder
    private var result: some View {
        switch state {
        case .idle:
            VStack(alignment: .leading, spacing: 7) {
                Text("YOUR RESULT")
                    .font(.relayEyebrow).tracking(1.3)
                    .foregroundStyle(RelayColors.textMuted)
                Text("A small first step. A result you can check.")
                    .font(.relayBody)
                    .foregroundStyle(RelayColors.textSecondary)
            }
        case .running:
            ProgressView("Calculating on this Mac…")
                .controlSize(.small)
                .font(.relayBody)
                .padding(.vertical, 8)
        case .checked(let expression, let output):
            VStack(alignment: .leading, spacing: 10) {
                Label("CHECKED LOCAL RESULT", systemImage: "checkmark.circle.fill")
                    .font(.relayEyebrow).tracking(1.1)
                    .foregroundStyle(RelayColors.success)
                Text(output.summary)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayColors.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("onboarding.calculator.checkedResult")
                Text("Expression: \(expression)")
                    .font(.relayMonoSmall)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
                DisclosureGroup("How this was checked") {
                    Text(output.evidence)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .font(.relayCaptionStrong)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Needs another try", systemImage: "exclamationmark.circle")
                    .font(.relayBodyStrong).foregroundStyle(RelayColors.warning)
                Text(message)
                    .font(.relayBody).foregroundStyle(RelayColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.calculator.error")
                Text("Edit the expression above, then calculate again.")
                    .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
            }
        }
    }
}
