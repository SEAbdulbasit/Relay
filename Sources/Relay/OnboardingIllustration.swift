import SwiftUI

/// Explanatory artwork, deliberately separate from live task and permission state.
struct OnboardingIllustration: View {
    enum Scene { case conversation, privacy, access }
    let scene: Scene
    private let blue = RelayColors.accentBlue

    var body: some View {
        VStack(spacing: RelaySpace.md) {
            switch scene {
            case .conversation: conversation
            case .privacy: privacy
            case .access: access
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: RelayRadius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.sm, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("A conversation, with actions")
                    .font(.relayBodyStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                Spacer()
                Text("Example")
                    .font(.relayMicro)
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RelayColors.surface, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 1))
            }
            HStack {
                Spacer(minLength: 24)
                Text("Open Calculator")
                    .font(.relayBodyStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(RelayColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(RelayColors.borderStrong)
                            .frame(width: 7, height: 7)
                    }
                    Spacer()
                    Label("Calculator", systemImage: "macwindow")
                        .font(.relayMicro)
                        .foregroundStyle(RelayColors.textSecondary)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(blue)
                    Text("Active")
                        .font(.relayMicro)
                        .foregroundStyle(RelayColors.textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().overlay(RelayColors.borderSubtle)

                HStack(spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Search in the app you already use")
                            .font(.relayBodyStrong)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Relay enters the search. Finder shows the matches.")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )
            Label("Follow each action in Activity", systemImage: "list.bullet.rectangle")
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textSecondary)
        }
    }

    private var privacy: some View {
        HStack(spacing: RelaySpace.lg) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(blue)
                .frame(width: 64, height: 64)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 10) {
                Label("Your conversation", systemImage: "bubble.left")
                    .font(.relayBodyStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                Label("Your local model", systemImage: "cpu")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                Label("Together on this Mac", systemImage: "lock.shield")
                    .font(.relayMicro)
                    .foregroundStyle(RelayColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var access: some View {
        HStack(spacing: RelaySpace.lg) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(blue)
                .frame(width: 64, height: 64)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 8) {
                Text("A little help across your apps.")
                    .font(.relayBodyStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                Text("Read a control. Enter text. Check the result.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                Text("You choose when to enable app control.")
                    .font(.relayMicro)
                    .foregroundStyle(RelayColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var accessibilityDescription: String {
        switch scene {
        case .conversation: "Illustrative example: ask Relay to find sf.webm in Finder, open Finder, enter the search, then inspect Activity. No task is running."
        case .privacy: "Your conversation and local model run together on this Mac."
        case .access: "App control can read controls, enter text and inspect results after you enable access."
        }
    }
}
