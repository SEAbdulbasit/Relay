import AppKit
import SwiftUI
import RelayJournal

struct ConversationReplyChip: View {
    let title: String
    let preview: String
    var clear: (() -> Void)? = nil
    var obsidianStyle: Bool = false

    var body: some View {
        Group {
            if clear != nil {
                chipBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    chipBody
                        .fixedSize(horizontal: true, vertical: true)
                    chipBody
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var chipBody: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.relayCaptionStrong)
                    .foregroundStyle(obsidianStyle ? Color.white.opacity(0.92) : RelayColors.textPrimary)
                Text(preview)
                    .font(.relayCaption)
                    .foregroundStyle(obsidianStyle ? Color.white.opacity(0.68) : RelayColors.textSecondary)
                    .lineLimit(clear == nil ? 1 : 2)
            }
            if let clear {
                Spacer(minLength: 0)
                RelayIconButton(
                    icon: "xmark",
                    label: "Cancel reply",
                    size: 24,
                    iconSize: 9.5,
                    tint: obsidianStyle ? Color.white.opacity(0.75) : RelayColors.textBright,
                    action: clear
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(obsidianStyle ? Color.white.opacity(0.08) : RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(obsidianStyle ? Color.white.opacity(0.14) : RelayColors.borderSubtle, lineWidth: 0.75)
        )
    }
}

/// Own read-only message selection, with an exact UTF-16 range. It reads no
/// other application, pasteboard, focused field or private source capability.
struct ConversationQuoteSheet: View {
    let message: ChatMessage
    let onQuote: @MainActor (NSRange) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = RelayThemeManager.shared
    @State private var selection = NSRange(location: NSNotFound, length: 0)
    @State private var saving = false
    @State private var failed = false
    private var hasQuote: Bool { (try? ConversationReplySelection.quote(message.text, range: selection)) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Quote a message").font(RelayPageStyle.dialogTitle).foregroundStyle(RelayColors.textPrimary)
                Spacer()
                RelayIconButton(icon: "xmark", label: "Close quote selection", size: 32) { dismiss() }
            }
            Text("Select the exact passage to reply to. This is historical conversation text, not current app state.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
            ConversationQuoteText(text: message.text, selection: $selection)
                .frame(minHeight: 180, idealHeight: 300, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            if failed { Text("The original message is no longer available. Choose it again.").font(.relayCaption).foregroundStyle(RelayColors.accentAmber) }
            HStack {
                Text("Up to 16,000 UTF-8 bytes.").font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                Spacer()
                Button("Reply to quote") {
                    let range = selection
                    saving = true
                    Task { @MainActor in
                        let accepted = await onQuote(range)
                        saving = false
                        if accepted { dismiss() } else { failed = true }
                    }
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(!hasQuote || saving)
            }
        }
        .padding(24)
        .frame(width: 560)
        .relayPageBackground()
        .foregroundStyle(RelayColors.textPrimary)
        .preferredColorScheme(themeManager.appearanceMode.colorScheme)
        .relayPreferredAppearance()
    }
}

private struct ConversationQuoteText: NSViewRepresentable {
    let text: String
    @Binding var selection: NSRange
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ConversationQuoteScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(RelayColors.cardBG)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.font = .systemFont(ofSize: 13.5)
        view.textColor = NSColor(RelayColors.textPrimary)
        view.backgroundColor = NSColor(RelayColors.cardBG)
        view.insertionPointColor = NSColor(RelayColors.accentBlue)
        view.delegate = context.coordinator
        view.string = text
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        scroll.backgroundColor = NSColor(RelayColors.cardBG)
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.backgroundColor = NSColor(RelayColors.cardBG)
        textView.textColor = NSColor(RelayColors.textPrimary)
        textView.insertionPointColor = NSColor(RelayColors.accentBlue)
        if Data(textView.string.utf8) != Data(text.utf8) { textView.string = text; textView.setSelectedRange(NSRange(location: 0, length: 0)) }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var selection: Binding<NSRange>
        init(selection: Binding<NSRange>) { self.selection = selection }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            selection.wrappedValue = view.selectedRange()
        }
    }
}

/// The enclosing SwiftUI sheet assigns the scroll view its width after creation.
/// Keep the actual selectable document inside that viewport, including insets.
private final class ConversationQuoteScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, contentSize.width > 0 else { return }
        let width = contentSize.width
        if text.frame.width != width {
            text.setFrameSize(NSSize(width: width, height: max(text.frame.height, contentSize.height)))
        }
        text.textContainer?.containerSize = NSSize(
            width: max(0, width - 2 * text.textContainerInset.width),
            height: CGFloat.greatestFiniteMagnitude)
    }
}
