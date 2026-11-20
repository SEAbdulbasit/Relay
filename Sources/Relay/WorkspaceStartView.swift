import SwiftUI

/// The empty work surface offers real draft starts, never illustrative execution.
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
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 9) {
                RelayMark(size: 18)
                Text("YOUR WORKBENCH")
                    .font(.relayEyebrow)
                    .tracking(1.8)
                    .foregroundStyle(RelayColors.workbenchAccent)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Make space\nfor good work.")
                    .font(.relayWorkbenchHero)
                    .tracking(-1.5)
                    .lineSpacing(-2)
                    .foregroundStyle(RelayColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("An idea to shape. A document to understand.\nSomething on your Mac to move forward.")
                    .font(.system(size: 15))
                    .lineSpacing(5)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                startRow(number: "01", title: "Write something", detail: "Find the words. Make them yours.", icon: "pencil.line", identifier: "home.start.write") {
                    onStartDraft("Help me turn a rough idea into a clear draft. Ask what I want to write and who it’s for.")
                }
                startRow(number: "02", title: "Understand something", detail: "Work through a document or a question.", icon: "doc.text.magnifyingglass", identifier: "home.start.understand") {
                    onStartDraft("Help me understand a document. Ask me to attach the file before you analyze it.")
                }
                startRow(number: "03", title: "Work across apps", detail: "Turn a task into a considered next step.", icon: "cursorarrow.motionlines", identifier: "home.start.apps") {
                    onStartDraft("Help me plan a task across apps on my Mac. Ask which app and what result I want before taking action.")
                }
            }
            .accessibilityIdentifier("home.welcome.starterPrompts")

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: modelReady ? "circle.inset.filled" : "circle.dashed")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(modelReady ? RelayColors.workbenchAccent : RelayColors.textSecondary)
                        .accessibilityHidden(true)
                    Text(modelReady ? modelName : "Choose a model to start")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(2)
                    Button(modelReady ? "Change" : "Set up model", action: onChooseModel)
                        .font(.relayCaptionStrong)
                        .foregroundStyle(RelayColors.workbenchAccent)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.readiness.model")
                }
                if modelReady && !computerAccessReady {
                    Button(action: onChooseAccess) {
                        Label("Set up Mac control when you’re ready", systemImage: "cursorarrow")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.readiness.control")
                }
                Text("These starts fill a draft. Review it, then send when you’re ready.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 22) {
                quietLink("Your knowledge", icon: "books.vertical", action: onOpenKnowledge)
                quietLink("Morning Brief", icon: "sun.horizon", action: onOpenBrief)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 610, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func startRow(number: String, title: String, detail: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        WorkspaceStartRow(number: number, title: title, detail: detail, icon: icon, action: action)
            .accessibilityIdentifier(identifier)
    }

    private func quietLink(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.relayCaptionStrong)
                .foregroundStyle(RelayColors.textSecondary)
        }
        .buttonStyle(RelayPressStyle())
    }
}

private struct WorkspaceStartRow: View {
    let number: String
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Rectangle().fill(RelayColors.borderSubtle).frame(height: 1)
                HStack(spacing: 15) {
                    Text(number)
                        .font(.relayEyebrow)
                        .foregroundStyle(RelayColors.workbenchAccent)
                        .frame(width: 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(RelayColors.textPrimary)
                        Text(detail)
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: hovered ? "arrow.up.right" : icon)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(hovered ? RelayColors.workbenchAccent : RelayColors.textMuted)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 8)
            }
            .background(hovered ? RelayColors.workbenchTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
    }
}

/// Phase and step wording comes from actual store state. No inferred goal completion.
struct WorkspaceTaskStrip: View {
    let status: String
    let detail: String?
    let isWorking: Bool
    let inspect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if isWorking {
                RelayActivityMark(size: 17, fast: true)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(RelayColors.textSecondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(status)
                    .font(.relayCallout.weight(.medium))
                    .foregroundStyle(RelayColors.textPrimary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(action: inspect) {
                Label("Activity", systemImage: "arrow.up.right")
                    .font(.relayCaptionStrong)
                    .foregroundStyle(RelayColors.workbenchAccent)
            }
            .buttonStyle(RelayPressStyle())
            .accessibilityLabel("Inspect activity")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(RelayColors.borderSubtle).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.taskStatus")
    }
}
