import SwiftUI

/// Explanatory artwork, deliberately separate from live task and permission state.
struct OnboardingIllustration: View {
    enum Scene { case conversation, privacy, access }
    let scene: Scene
    private let blue = RelayColors.accentBlue

    var body: some View {
        VStack(spacing: 16) {
            switch scene {
            case .conversation: conversation
            case .privacy: privacy
            case .access: access
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RelayTheme.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("A conversation, with actions")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(RelayColors.textSecondary)
                Spacer()
                Text("Example").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RelayColors.textSecondary)
            }
            HStack {
                Spacer(minLength: 24)
                Text("Open Calculator")
                    .font(.system(size: 15))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.18)).frame(width: 7, height: 7) }
                    Spacer()
                    Label("Calculator", systemImage: "macwindow")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(RelayColors.textSecondary)
                    Spacer()
                    Image(systemName: "checkmark.circle").foregroundStyle(blue)
                    Text("Active").font(.system(size: 13))
                }.padding(.horizontal, 16).padding(.vertical, 12)
                Divider().overlay(.white.opacity(0.08))
                HStack(spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Search in the app you already use")
                            .font(.system(size: 15, weight: .medium))
                        Text("Relay enters the search. Finder shows the matches.")
                            .font(.system(size: 13)).foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(18)
            }
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.10)))
            Label("Follow each action in Activity", systemImage: "list.bullet.rectangle")
                .font(.system(size: 13)).foregroundStyle(RelayColors.textSecondary)
        }
    }

    private var privacy: some View {
        HStack(spacing: 24) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 36, weight: .light)).foregroundStyle(blue)
                .frame(width: 64, height: 64)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 12) {
                Label("Your conversation", systemImage: "bubble.left")
                Label("Your local model", systemImage: "cpu")
                Label("Together on this Mac", systemImage: "lock.shield")
            }.font(.system(size: 14, weight: .regular))
            Spacer(minLength: 0)
        }
    }

    private var access: some View {
        HStack(spacing: 24) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 48, weight: .light)).foregroundStyle(blue)
                .frame(width: 64, height: 64)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 10) {
                Text("A little help across your apps.")
                    .font(.system(size: 18, weight: .medium))
                Text("Read a control. Enter text. Check the result.")
                    .font(.system(size: 16)).foregroundStyle(RelayColors.textSecondary)
                Text("You choose when to enable app control.")
                    .font(.system(size: 15)).foregroundStyle(RelayColors.textSecondary)
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
