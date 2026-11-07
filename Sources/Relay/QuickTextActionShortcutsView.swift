import SwiftUI

struct QuickTextActionShortcutsView: View {
    let shortcuts: QuickTextActionShortcutsController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Text action shortcuts").font(.relayHeadline.weight(.semibold))
            Text("Shortcuts are optional. Settings (⌘,) and Stop (⌘.) keep their existing behavior. No text is captured until you invoke an enabled action.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
            ForEach(QuickTextActionShortcutsController.Action.allCases) { action in
                HStack(spacing: 12) {
                    Toggle(action.title, isOn: Binding(get: { shortcuts.isEnabled(action) }, set: { shortcuts.setEnabled($0, for: action) }))
                        .toggleStyle(.switch)
                    Spacer(minLength: 8)
                    Picker("Shortcut", selection: Binding(get: { shortcuts.shortcut(for: action) }, set: { shortcuts.setShortcut($0, for: action) })) {
                        ForEach(QuickTextActionShortcutsController.Shortcut.choices) { shortcut in Text(shortcut.title).tag(shortcut) }
                    }.labelsHidden().frame(width: 120).disabled(shortcuts.isEnabled(action))
                }
            }
            if let error = shortcuts.errorMessage { Text(error).font(.relayCaption).foregroundStyle(RelayColors.accentAmber) }
        }
        .padding(20).relayGlassCard(cornerRadius: RelayTheme.radius)
    }
}
