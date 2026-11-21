import SwiftUI

struct QuickTextActionShortcutsView: View {
    let shortcuts: QuickTextActionShortcutsController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "keyboard")
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text Action Shortcuts")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Shortcuts are optional. Settings (⌘,) and Stop (⌘.) keep their existing behavior. No text is captured until you invoke an enabled action.")
                        .font(RelayPageStyle.caption)
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
            .padding(.vertical, 4)
            if let error = shortcuts.errorMessage {
                Text(error)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentAmber)
            }
        }
        .relayFormSection()
    }
}
