import SwiftUI

/// A quiet starting point for real drafts. Suggestions never execute a task.
struct WorkspaceStartView: View {
    let modelReady: Bool
    let modelName: String
    let computerAccessReady: Bool
    let onChooseModel: () -> Void
    let onChooseAccess: () -> Void
    let onStartDraft: (String) -> Void
    let onOpenKnowledge: () -> Void
    let onOpenBrief: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                RelayMark(size: 32)
                VStack(alignment: .leading, spacing: 7) {
                    Text("What are we working on?")
                        .font(RelayPageStyle.title)
                        .tracking(-0.45)
                        .foregroundStyle(RelayColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Ask a question, shape a draft, or put Relay to work.")
                        .font(RelayPageStyle.body)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !modelReady {
                Button("Choose a model to get started", systemImage: "cpu", action: onChooseModel)
                    .font(RelayPageStyle.body)
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayColors.workbenchAccent)
                    .accessibilityIdentifier("home.readiness.model")
            } else if !computerAccessReady {
                Button("Set up Mac control", systemImage: "cursorarrow", action: onChooseAccess)
                    .font(RelayPageStyle.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayColors.textSecondary)
                    .accessibilityIdentifier("home.readiness.control")
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

/// Optional starts sit below the input and fill a draft without sending it.
struct WorkspaceDraftSuggestions: View {
    let onStartDraft: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { suggestions }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) { suggestions }
        }
        .accessibilityIdentifier("home.welcome.starterPrompts")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var suggestions: some View {
        WorkspaceDraftSuggestion(title: "Write a draft", icon: "pencil.line") {
            onStartDraft("Help me turn a rough idea into a clear draft. Ask what I want to write and who it’s for.")
        }
        .accessibilityIdentifier("home.start.write")
        WorkspaceDraftSuggestion(title: "Explore a document", icon: "doc.text.magnifyingglass") {
            onStartDraft("Help me understand a document. Ask me to attach the file before you analyze it.")
        }
        .accessibilityIdentifier("home.start.understand")
        WorkspaceDraftSuggestion(title: "Work in an app", icon: "cursorarrow") {
            onStartDraft("Help me plan a task across apps on my Mac. Ask which app and what result I want before taking action.")
        }
        .accessibilityIdentifier("home.start.apps")
    }
}

private struct WorkspaceDraftSuggestion: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textMuted)
                    .frame(width: 15)
                    .accessibilityHidden(true)
                Text(title)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(hovered ? RelayColors.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Start a draft: \(title.lowercased())")
    }
}

/// Phase and step wording comes from actual store state. No inferred completion.
struct WorkspaceTaskStrip: View {
    let status: String
    let detail: String?
    let isWorking: Bool
    let inspect: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }

            Text(status)
                .font(.system(size: 12.5))
                .foregroundStyle(RelayColors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(RelayColors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detail)
            }

            Spacer(minLength: 6)

            Button(action: inspect) {
                HStack(spacing: 4) {
                    Text("Activity")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(RelayColors.textSecondary)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspect activity")
            .fixedSize()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.taskStatus")
    }
}
