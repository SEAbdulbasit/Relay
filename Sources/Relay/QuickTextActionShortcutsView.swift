import SwiftUI

struct QuickTextActionShortcutsView: View {
    let shortcuts: QuickTextActionShortcutsController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "keyboard.fill", color: RelayColors.accentAmethyst, size: 38, iconSize: 17)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text Action Shortcuts")
                        .font(.relayHeadline)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Shortcuts are optional. Settings (⌘,) and Stop (⌘.) keep their existing behavior. No text is captured until you invoke an enabled action.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
            }
            VStack(spacing: 10) {
                ForEach(QuickTextActionShortcutsController.Action.allCases) { action in
                    HStack(spacing: 12) {
                        Toggle(action.title, isOn: Binding(get: { shortcuts.isEnabled(action) }, set: { shortcuts.setEnabled($0, for: action) }))
                            .toggleStyle(.switch)
                            .font(.relayBodyStrong)
                            .foregroundStyle(RelayColors.textPrimary)
                        Spacer(minLength: 8)
                        Picker("Shortcut", selection: Binding(get: { shortcuts.shortcut(for: action) }, set: { shortcuts.setShortcut($0, for: action) })) {
                            ForEach(QuickTextActionShortcutsController.Shortcut.choices) { shortcut in Text(shortcut.title).tag(shortcut) }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        .disabled(shortcuts.isEnabled(action))
                    }
                }
            }
            .padding(14)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )
            if let error = shortcuts.errorMessage {
                Text(error)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.accentAmber)
            }
        }
        .padding(20)
        .relayGlassCard(cornerRadius: RelayTheme.radius)
    }
}
