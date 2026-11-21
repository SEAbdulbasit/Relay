import SwiftUI

// MARK: - Inline Home Morning Card Deck (`PRO-05..10`, `PRO-11`)

/// Swipeable/pageable Morning Cards + Welcome Keepsake deck designed to sit inline on `MainView` Home
/// as well as inside `MorningBriefView`.
struct ProactiveHomeDeckView: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let store: AssistantStore
    @Bindable var engine: ProactiveIntelligenceEngine
    @Bindable var keepsakeGenerator: WelcomeKeepsakeGenerator
    var onOpenFullBrief: (() -> Void)?
    var onLaunched: (() -> Void)?

    @State private var currentIndex = 0
    @State private var showKeepsakeSheet = false
    @State private var launchError: String?

    init(
        store: AssistantStore,
        engine: ProactiveIntelligenceEngine = .shared,
        keepsakeGenerator: WelcomeKeepsakeGenerator = .shared,
        onOpenFullBrief: (() -> Void)? = nil,
        onLaunched: (() -> Void)? = nil
    ) {
        self.store = store
        self.engine = engine
        self.keepsakeGenerator = keepsakeGenerator
        self.onOpenFullBrief = onOpenFullBrief
        self.onLaunched = onLaunched
    }

    private var activeCards: [ProactivePreparedCard] { engine.activeCards }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let keepsake = keepsakeGenerator.activeKeepsake {
                keepsakeBanner(keepsake)
            }

            if !activeCards.isEmpty {
                let clampedIndex = min(max(0, currentIndex), activeCards.count - 1)
                let card = activeCards[clampedIndex]

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "sun.horizon")
                                .font(RelayPageStyle.symbol)
                                .foregroundStyle(RelayColors.textSecondary)
                                .frame(width: 20, height: 24)
                                .accessibilityHidden(true)
                            Text("Morning Cards")
                                .font(RelayPageStyle.sectionTitle)
                                .foregroundStyle(RelayColors.textPrimary)
                            Text("· \(clampedIndex + 1) of \(activeCards.count)")
                                .font(RelayPageStyle.caption)
                                .foregroundStyle(RelayColors.textMuted)
                        }

                        Spacer()

                        if activeCards.count > 1 {
                            HStack(spacing: RelaySpace.xxs) {
                                Button {
                                    withAnimation(reducedMotion ? nil : .easeOut(duration: 0.16)) {
                                        currentIndex = max(0, clampedIndex - 1)
                                    }
                                } label: {
                                    Image(systemName: "chevron.left")
                                        .font(RelayPageStyle.symbol)
                                        .foregroundStyle(clampedIndex == 0 ? RelayColors.textDim : RelayColors.textBright)
                                        .frame(width: 32, height: 32)
                                        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 0.75))
                                }
                                .buttonStyle(RelayPressStyle())
                                .disabled(clampedIndex == 0)
                                .accessibilityLabel("Previous morning card")
                                .help("Previous morning card")
                                .accessibilityIdentifier("proactiveDeck.previous")

                                Button {
                                    withAnimation(reducedMotion ? nil : .easeOut(duration: 0.16)) {
                                        currentIndex = min(activeCards.count - 1, clampedIndex + 1)
                                    }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(RelayPageStyle.symbol)
                                        .foregroundStyle(clampedIndex >= activeCards.count - 1 ? RelayColors.textDim : RelayColors.textBright)
                                        .frame(width: 32, height: 32)
                                        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 0.75))
                                }
                                .buttonStyle(RelayPressStyle())
                                .disabled(clampedIndex >= activeCards.count - 1)
                                .accessibilityLabel("Next morning card")
                                .help("Next morning card")
                                .accessibilityIdentifier("proactiveDeck.next")
                            }
                        }

                        if let onOpenFullBrief {
                            Button("All Cards", action: onOpenFullBrief)
                                .buttonStyle(RelayGhostButtonStyle())
                        }
                    }

                    ProactiveMorningCardView(
                        card: card,
                        isStoreBusy: store.isRunning || store.isAuxiliaryBusy,
                        canLaunch: store.workspaceActionsReady,
                        availableCalendars: store.calendarSource.calendars,
                        onUpdate: { title, artifact in
                            engine.updateCard(id: card.id, title: title, artifact: artifact)
                        },
                        onSnooze: { durationSeconds in
                            engine.snoozeCard(card.id, hours: durationSeconds / 3600)
                            adjustIndexAfterRemoval()
                        },
                        onDismiss: {
                            engine.dismissCard(card.id)
                            adjustIndexAfterRemoval()
                        },
                        onLaunch: {
                            launchCard(card)
                        }
                    )
                    .id(card.id)
                    .gesture(
                        DragGesture(minimumDistance: 32)
                            .onEnded { value in
                                guard activeCards.count > 1 else { return }
                                if value.translation.width < -40, clampedIndex + 1 < activeCards.count {
                                    withAnimation(reducedMotion ? nil : .easeOut(duration: 0.16)) {
                                        currentIndex = clampedIndex + 1
                                    }
                                } else if value.translation.width > 40, clampedIndex > 0 {
                                    withAnimation(reducedMotion ? nil : .easeOut(duration: 0.16)) {
                                        currentIndex = clampedIndex - 1
                                    }
                                }
                            }
                    )

                    if let launchError {
                        Text(launchError)
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.accentCoral)
                    }
                }
                .padding(16)
                .relayPagePanel(cornerRadius: 12)
            } else if engine.isPreparing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(engine.status)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                    Spacer()
                }
                .padding(14)
                .relayPagePanel(cornerRadius: 12)
            }
        }
        .sheet(isPresented: $showKeepsakeSheet) {
            WelcomeLetterSheetView(generator: keepsakeGenerator)
                .relayPreferredAppearance()
        }
        .onChange(of: activeCards.count) { _, newCount in
            if currentIndex >= newCount {
                currentIndex = max(0, newCount - 1)
            }
        }
    }

    private func keepsakeBanner(_ keepsake: WelcomeKeepsake) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(RelayColors.workbenchAccent)
                .frame(width: 28, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(keepsake.kicker)
                        .font(RelayPageStyle.caption.weight(.medium))
                        .foregroundStyle(RelayColors.textSecondary)
                    if !keepsake.groundedNoteTitles.isEmpty {
                        Text("· \(keepsake.groundedNoteTitles.count) \(keepsake.groundedNoteTitles.count == 1 ? "source" : "sources")")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textMuted)
                    }
                }
                Text(keepsake.title)
                    .font(RelayPageStyle.sectionTitle)
                    .foregroundStyle(RelayColors.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button {
                showKeepsakeSheet = true
            } label: {
                HStack(spacing: 5) {
                    Text("Read Note")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .regular))
                }
            }
            .buttonStyle(RelaySecondaryButtonStyle())
            .accessibilityIdentifier("welcome-keepsake-open")

            RelayIconButton(
                icon: "xmark",
                label: "Dismiss welcome note",
                size: 30,
                iconSize: 11,
                tint: RelayColors.textSecondary
            ) {
                keepsakeGenerator.retire()
            }
            .help("Dismiss welcome note")
            .accessibilityIdentifier("welcome-keepsake-dismiss")
        }
        .padding(16)
        .relayPagePanel(cornerRadius: 12)
    }

    private func adjustIndexAfterRemoval() {
        let remaining = engine.activeCards.count
        if currentIndex >= remaining {
            currentIndex = max(0, remaining - 1)
        }
    }

    private func launchCard(_ card: ProactivePreparedCard) {
        launchError = nil
        guard store.workspaceActionsReady else {
            launchError = "Choose and check a model in Settings before launching this card."
            return
        }
        guard !store.isRunning && !store.isAuxiliaryBusy else {
            launchError = "Wait for Relay’s current work to finish before launching this card."
            return
        }
        do {
            let handoff = try engine.prepareFrozenHandoff(
                id: card.id,
                isSourceCurrent: { sourceID in
                    MorningBriefCorpusBridge.isSourceCurrent(sourceID, store: store)
                },
                currentAccountGenerations: MorningBriefCorpusBridge.currentAccountGenerations(from: store)
            )
            store.draft = handoff.userPrompt
            guard store.send(useWorkspaceProvider: true) != nil else {
                let note = store.errorMessage ?? "Could not start task — your edited card was kept ready."
                engine.recordTaskCompletion(
                    cardID: card.id,
                    verified: false,
                    failureNote: note
                )
                launchError = note
                return
            }
            let launchedCardID = card.id
            Task { @MainActor [weak store, weak engine] in
                try? await Task.sleep(for: .milliseconds(250))
                while let store, store.isRunning || store.phase == .awaitingReview || store.phase == .needsInput {
                    try? await Task.sleep(for: .milliseconds(400))
                }
                guard let store, let engine else { return }
                let verified = (store.phase == .completed)
                engine.recordTaskCompletion(
                    cardID: launchedCardID,
                    verified: verified,
                    failureNote: verified ? nil : store.errorMessage
                )
            }
            onLaunched?()
        } catch {
            launchError = error.localizedDescription
        }
    }
}

// MARK: - Rich Editable Single Morning Card (`PRO-05`, `PRO-06`)

struct ProactiveMorningCardView: View {
    let card: ProactivePreparedCard
    let isStoreBusy: Bool
    let canLaunch: Bool
    var availableCalendars: [CalendarSource.CalendarInfo] = []
    let onUpdate: (String, ProactiveArtifact) -> Void
    let onSnooze: (TimeInterval) -> Void
    let onDismiss: () -> Void
    let onLaunch: () -> Void

    @State private var editedTitle: String
    @State private var editedArtifact: ProactiveArtifact

    init(
        card: ProactivePreparedCard,
        isStoreBusy: Bool,
        canLaunch: Bool,
        availableCalendars: [CalendarSource.CalendarInfo] = [],
        onUpdate: @escaping (String, ProactiveArtifact) -> Void,
        onSnooze: @escaping (TimeInterval) -> Void,
        onDismiss: @escaping () -> Void,
        onLaunch: @escaping () -> Void
    ) {
        self.card = card
        self.isStoreBusy = isStoreBusy
        self.canLaunch = canLaunch
        self.availableCalendars = availableCalendars
        self.onUpdate = onUpdate
        self.onSnooze = onSnooze
        self.onDismiss = onDismiss
        self.onLaunch = onLaunch
        self._editedTitle = State(initialValue: card.title)
        self._editedArtifact = State(initialValue: card.artifact)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RelayBadge(
                    editedArtifact.kind.displayTitle,
                    icon: editedArtifact.kind.systemImage,
                    tint: RelayColors.workbenchAccent,
                    prominent: true
                )

                RelayBadge(
                    card.verificationStatus.badgeLabel,
                    icon: card.verificationStatus == .verifiedReadOnly ? "checkmark.shield.fill" : "clock.badge.exclamationmark",
                    tint: card.verificationStatus == .verifiedReadOnly ? RelayColors.accentEmerald : RelayColors.accentAmber,
                    prominent: false
                )
                .help(card.verificationDetail)

                if case .launched = card.lifecycle {
                    RelayBadge("In progress", icon: "bolt.fill", tint: RelayColors.workbenchAccent, prominent: true)
                }

                Spacer()

                if !card.sourceTitles.isEmpty {
                    Text(card.sourceTitles.prefix(2).joined(separator: " · "))
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textMuted)
                        .lineLimit(1)
                }
            }

            TextField("Card title", text: $editedTitle)
                .textFieldStyle(.plain)
                .font(RelayPageStyle.sectionTitle)
                .foregroundStyle(RelayColors.textPrimary)
                .onChange(of: editedTitle) { _, newValue in
                    onUpdate(newValue, editedArtifact)
                }

            Text(card.whyNow)
                .font(RelayPageStyle.body)
                .foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ProactiveArtifactFieldsEditor(
                artifact: $editedArtifact,
                availableCalendars: availableCalendars
            )
            .onChange(of: editedArtifact) { _, newValue in
                onUpdate(editedTitle, newValue)
            }

            if let note = card.lastLaunchNote {
                Text(note)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentAmber)
            }

            HStack(spacing: 8) {
                Menu("Snooze") {
                    Button("1 Hour") { onSnooze(3600) }
                    Button("Later Today (4h)") { onSnooze(14400) }
                    Button("Tomorrow (24h)") { onSnooze(86400) }
                }
                .font(RelayPageStyle.body.weight(.medium))
                .fixedSize()
                .accessibilityIdentifier("proactiveCard.snooze")

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("proactiveCard.dismiss")

                Spacer()

                Button {
                    onUpdate(editedTitle, editedArtifact)
                    onLaunch()
                } label: {
                    HStack(spacing: 5) {
                        Text(editedArtifact.kind.primaryActionLabel)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .regular))
                    }
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(isStoreBusy || !canLaunch)
                .accessibilityIdentifier("proactiveCard.launch")
            }
        }
    }
}

// MARK: - Structured In-Place Artifact Editor (`PRO-05`, `PRO-06`)

struct ProactiveArtifactFieldsEditor: View {
    @Binding var artifact: ProactiveArtifact
    var availableCalendars: [CalendarSource.CalendarInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch artifact {
            case .draftEmail(let email):
                emailEditor(email)
            case .draftReply(let reply):
                replyEditor(reply)
            case .calendarEvent(let event):
                calendarEditor(event)
            case .actionPlan(let plan):
                actionPlanEditor(plan)
            case .researchShortlist(let list):
                shortlistEditor(list)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func emailEditor(_ email: ProactiveArtifact.DraftEmail) -> some View {
        HStack(spacing: 8) {
            labeledField("To", text: Binding(
                get: { email.to },
                set: { var copy = email; copy.to = $0; artifact = .draftEmail(copy) }
            ))
            labeledField("Cc", text: Binding(
                get: { email.cc },
                set: { var copy = email; copy.cc = $0; artifact = .draftEmail(copy) }
            ))
        }
        labeledField("Subject", text: Binding(
            get: { email.subject },
            set: { var copy = email; copy.subject = $0; artifact = .draftEmail(copy) }
        ))
        multilineEditor(text: Binding(
            get: { email.body },
            set: { var copy = email; copy.body = $0; artifact = .draftEmail(copy) }
        ), minHeight: 84)
    }

    @ViewBuilder
    private func replyEditor(_ reply: ProactiveArtifact.DraftReply) -> some View {
        HStack(spacing: 8) {
            labeledField("To", text: Binding(
                get: { reply.recipient },
                set: { var copy = reply; copy.recipient = $0; artifact = .draftReply(copy) }
            ))
            labeledField("Channel", text: Binding(
                get: { reply.channel },
                set: { var copy = reply; copy.channel = $0; artifact = .draftReply(copy) }
            ))
        }
        if !reply.threadContext.isEmpty {
            Text("Context: \(reply.threadContext)")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textMuted)
                .lineLimit(2)
        }
        multilineEditor(text: Binding(
            get: { reply.body },
            set: { var copy = reply; copy.body = $0; artifact = .draftReply(copy) }
        ), minHeight: 80)
    }

    @ViewBuilder
    private func calendarEditor(_ event: ProactiveArtifact.CalendarEventDraft) -> some View {
        let fallbackStart = Date()
        let parsedStart = Self.parseISODate(event.startISO, fallback: fallbackStart)
        let parsedEnd = Self.parseISODate(event.endISO, fallback: parsedStart.addingTimeInterval(3600))
        let calendarNames: [String] = {
            var names = Array(Set(availableCalendars.map(\.title))).sorted()
            if !event.calendarName.isEmpty && !names.contains(event.calendarName) {
                names.insert(event.calendarName, at: 0)
            }
            return names
        }()

        labeledField("Event", text: Binding(
            get: { event.title },
            set: { var copy = event; copy.title = $0; artifact = .calendarEvent(copy) }
        ))
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Start")
                    .font(RelayPageStyle.caption.weight(.medium))
                    .foregroundStyle(RelayColors.textMuted)
                    .frame(minWidth: 44, alignment: .leading)
                DatePicker(
                    "Start",
                    selection: Binding(
                        get: { parsedStart },
                        set: { newDate in
                            var copy = event
                            copy.startISO = Self.formatISODate(newDate)
                            if newDate >= parsedEnd {
                                copy.endISO = Self.formatISODate(newDate.addingTimeInterval(1800))
                            }
                            artifact = .calendarEvent(copy)
                        }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .accessibilityIdentifier("proactiveCard.calendarStart")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text("End")
                    .font(RelayPageStyle.caption.weight(.medium))
                    .foregroundStyle(RelayColors.textMuted)
                    .frame(minWidth: 32, alignment: .leading)
                DatePicker(
                    "End",
                    selection: Binding(
                        get: { parsedEnd },
                        set: { newDate in
                            var copy = event
                            copy.endISO = Self.formatISODate(newDate)
                            artifact = .calendarEvent(copy)
                        }
                    ),
                    in: parsedStart...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .accessibilityIdentifier("proactiveCard.calendarEnd")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 8) {
            labeledField("Location", text: Binding(
                get: { event.location },
                set: { var copy = event; copy.location = $0; artifact = .calendarEvent(copy) }
            ))
            if !calendarNames.isEmpty {
                HStack(spacing: 6) {
                    Text("Calendar")
                        .font(RelayPageStyle.caption.weight(.medium))
                        .foregroundStyle(RelayColors.textMuted)
                        .frame(minWidth: 44, alignment: .leading)
                    Picker("Calendar", selection: Binding(
                        get: { event.calendarName },
                        set: { var copy = event; copy.calendarName = $0; artifact = .calendarEvent(copy) }
                    )) {
                        if event.calendarName.isEmpty {
                            Text("Default").tag("")
                        }
                        ForEach(calendarNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("proactiveCard.calendarPicker")
                }
            } else {
                labeledField("Calendar", text: Binding(
                    get: { event.calendarName },
                    set: { var copy = event; copy.calendarName = $0; artifact = .calendarEvent(copy) }
                ))
            }
        }
        multilineEditor(text: Binding(
            get: { event.notes },
            set: { var copy = event; copy.notes = $0; artifact = .calendarEvent(copy) }
        ), minHeight: 54)
    }

    private static func parseISODate(_ raw: String, fallback: Date) -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: trimmed) { return date }
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            localFormatter.dateFormat = fmt
            if let date = localFormatter.date(from: trimmed) { return date }
        }
        return fallback
    }

    private static func formatISODate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func actionPlanEditor(_ plan: ProactiveArtifact.ActionPlanDraft) -> some View {
        HStack(alignment: .top, spacing: 8) {
            labeledField("Goal", text: Binding(
                get: { plan.goal },
                set: { var copy = plan; copy.goal = $0; artifact = .actionPlan(copy) }
            ), multiline: true)
            labeledField("App / Site", text: Binding(
                get: { plan.targetAppOrSite },
                set: { var copy = plan; copy.targetAppOrSite = $0; artifact = .actionPlan(copy) }
            ))
        }
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { idx, step in
                HStack(spacing: 6) {
                    Text("\(idx + 1).")
                        .font(.relayMono)
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 20, alignment: .trailing)
                    TextField("Step \(idx + 1)", text: Binding(
                        get: { step },
                        set: { newText in
                            var copy = plan
                            if copy.steps.indices.contains(idx) {
                                copy.steps[idx] = newText
                                artifact = .actionPlan(copy)
                            }
                        }
                    ), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(RelayPageStyle.body)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )

                    if plan.steps.count > 1 {
                        Button {
                            var copy = plan
                            copy.steps.remove(at: idx)
                            artifact = .actionPlan(copy)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(RelayPageStyle.caption)
                                .foregroundStyle(RelayColors.textMuted)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("+ Add Step") {
                var copy = plan
                copy.steps.append("")
                artifact = .actionPlan(copy)
            }
            .font(RelayPageStyle.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(RelayColors.workbenchAccent)
        }
    }

    @ViewBuilder
    private func shortlistEditor(_ list: ProactiveArtifact.ResearchShortlistDraft) -> some View {
        labeledField("Topic", text: Binding(
            get: { list.headline },
            set: { var copy = list; copy.headline = $0; artifact = .researchShortlist(copy) }
        ))
        ForEach(Array(list.options.enumerated()), id: \.element.id) { idx, option in
            VStack(alignment: .leading, spacing: 4) {
                TextField("Option", text: Binding(
                    get: { option.name },
                    set: { val in
                        var copy = list
                        if copy.options.indices.contains(idx) {
                            copy.options[idx].name = val
                            artifact = .researchShortlist(copy)
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .font(RelayPageStyle.body.weight(.semibold))

                TextField("Summary", text: Binding(
                    get: { option.summary },
                    set: { val in
                        var copy = list
                        if copy.options.indices.contains(idx) {
                            copy.options[idx].summary = val
                            artifact = .researchShortlist(copy)
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
            }
            .padding(7)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )
        }
        labeledField("Recommendation", text: Binding(
            get: { list.recommendation },
            set: { var copy = list; copy.recommendation = $0; artifact = .researchShortlist(copy) }
        ))
    }

    private func labeledField(_ label: String, text: Binding<String>, multiline: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(RelayPageStyle.caption.weight(.medium))
                .foregroundStyle(RelayColors.textMuted)
                .frame(minWidth: 44, alignment: .leading)
            TextField(label, text: text, axis: multiline ? .vertical : .horizontal)
                .lineLimit(1...(multiline ? 4 : 1))
                .textFieldStyle(.plain)
                .font(RelayPageStyle.body)
                .foregroundStyle(RelayTheme.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
        }
    }

    private func multilineEditor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(RelayPageStyle.body)
            .foregroundStyle(RelayTheme.ink)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight, maxHeight: 150)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )
    }
}

// MARK: - Store <-> Proactive Corpus Bridge

enum MorningBriefCorpusBridge {
    @MainActor
    static func buildCorpus(from store: AssistantStore) -> [CorpusItem] {
        let combinedRecords = store.knowledge.records + store.nativeSources.liveSources.knowledgeRecords()
        return SemanticVaultBuilder.makeCorpusItems(
            records: combinedRecords,
            nativeSources: store.nativeSources
        )
    }

    @MainActor
    static func buildCalendarOccurrences(from store: AssistantStore) -> [CalendarOccurrence] {
        store.preparation.agenda.map { ev in
            CalendarOccurrence(
                calendarID: ev.calendarName,
                calendarName: ev.calendarName,
                itemID: ev.id,
                title: ev.title,
                start: ev.start,
                end: ev.end,
                allDay: false,
                timeZone: TimeZone.current.identifier,
                location: "",
                notes: "",
                scheduleStatus: "confirmed",
                availability: "busy",
                participantResponse: "accepted"
            )
        }
    }

    @MainActor
    static func currentAccountGenerations(from store: AssistantStore) -> [String: String] {
        Dictionary(
            store.directMCP.oauthManager.connections
                .filter { $0.state == .connected }
                .map { ($0.id, $0.generation.uuidString) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @MainActor
    static func fetchConnectedCloudItems(from store: AssistantStore) async -> [CloudIngestedItem] {
        let connected = store.directMCP.oauthManager.connections.filter { $0.state == .connected }
        guard !connected.isEmpty else { return [] }
        var cloudItems: [CloudIngestedItem] = []
        for conn in connected {
            if Task.isCancelled { break }
            if let items = try? await store.directMCP.oauthManager.fetchCuratedCloudWindow(connectionID: conn.id) {
                cloudItems.append(contentsOf: items)
            }
        }
        return cloudItems
    }

    @MainActor
    static func fetchConnectedCloudCorpus(from store: AssistantStore) async -> [CorpusItem] {
        let items = await fetchConnectedCloudItems(from: store)
        return SemanticVaultBuilder.makeCorpusItems(records: items.map { $0.toKnowledgeRecord() })
    }

    @MainActor
    static func isSourceCurrent(_ sourceID: String, store: AssistantStore) -> Bool {
        if sourceID == "calendar" { return true }
        if sourceID.hasPrefix("native:") {
            let parts = sourceID.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3,
                  let kind = NativePersonalSourceKind(rawValue: parts[1]) else { return false }
            return store.nativeSources.items(for: kind).contains { $0.id == parts[2] }
        }
        let hadRecordPrefix = sourceID.hasPrefix("record:")
        let resolved = hadRecordPrefix ? String(sourceID.dropFirst("record:".count)) : sourceID
        if resolved.hasPrefix("relay-cloud://") {
            return store.directMCP.oauthManager.connections.contains {
                $0.state == .connected && resolved.contains("/\($0.id)/")
            }
        }
        if resolved.hasPrefix("relay-live://") {
            return store.nativeSources.liveSources.knowledgeRecords().contains { $0.sourcePath == resolved }
        }
        if resolved.hasPrefix("/") || hadRecordPrefix {
            guard let record = store.knowledge.records.first(where: { $0.sourcePath == resolved }) else {
                return false
            }
            return store.knowledge.revalidate(record, grants: store.grants)
        }
        return true
    }

    @MainActor
    static func makeReadOnlyVaultGate(
        vaultRoot: URL,
        corpus: [CorpusItem] = [],
        calendar: [CalendarOccurrence] = [],
        connectorItems: [CloudIngestedItem] = []
    ) -> ProactiveReadOnlyToolGate {
        ProactiveReadOnlyToolGate(
            lookupSource: { sourceID in
                let needle = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else { return nil }
                let exact = corpus.first {
                    $0.id == needle || $0.sourceID == needle
                }
                let matched = exact ?? corpus.first {
                    $0.id.localizedCaseInsensitiveContains(needle)
                        || ($0.sourceID?.localizedCaseInsensitiveContains(needle) == true)
                }
                guard let item = matched else { return nil }
                return GeneratedKnowledgeVault.boundedUTF8("\(item.title)\n\(item.text)", limit: 1_600)
            },
            searchVault: { query in
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !trimmed.isEmpty,
                      let files = try? FileManager.default.subpathsOfDirectory(atPath: vaultRoot.path) else {
                    return ""
                }
                var hits: [String] = []
                for rel in files where rel.hasSuffix(".md") && rel != WritingStyleCollector.fileName {
                    let url = vaultRoot.appendingPathComponent(rel)
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    if rel.lowercased().contains(trimmed) || text.lowercased().contains(trimmed) {
                        hits.append("[\(rel)]\n" + GeneratedKnowledgeVault.boundedUTF8(text, limit: 800))
                        if hits.count >= 3 { break }
                    }
                }
                return hits.joined(separator: "\n\n")
            },
            checkCalendar: {
                guard !calendar.isEmpty else { return "" }
                let sorted = calendar.sorted { $0.start < $1.start }
                let iso = ISO8601DateFormatter()
                let lines: [String] = sorted.map { ev in
                    let timeRange = ev.allDay
                        ? "\(iso.string(from: ev.start)) (all-day)"
                        : "\(iso.string(from: ev.start)) → \(iso.string(from: ev.end))"
                    var parts = ["- \(ev.title) | \(timeRange) | \(ev.calendarName)"]
                    let loc = ev.location.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !loc.isEmpty {
                        parts.append("Location: \(loc)")
                    }
                    let notes = ev.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !notes.isEmpty {
                        parts.append("Notes: \(GeneratedKnowledgeVault.boundedUTF8(notes, limit: 240))")
                    }
                    return parts.joined(separator: " · ")
                }
                return GeneratedKnowledgeVault.boundedUTF8(lines.joined(separator: "\n"), limit: 1_600)
            },
            readConnector: { rawQuery in
                guard !connectorItems.isEmpty else { return nil }
                let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                let filtered = Self.filterConnectorItems(connectorItems, rawQuery: trimmed)
                guard !filtered.isEmpty else { return nil }
                let formatted = filtered.prefix(5).map { item -> String in
                    var header = "[\(item.provider.displayName)] \(item.title)"
                    let sub = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sub.isEmpty {
                        header += "\n\(sub)"
                    }
                    let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        header += "\n\(body)"
                    }
                    return header
                }.joined(separator: "\n\n")
                return GeneratedKnowledgeVault.boundedUTF8(formatted, limit: 1_600)
            }
        )
    }

    @MainActor
    static func makeLiveOutgoingCheck(
        from store: AssistantStore
    ) async -> (@Sendable (CorpusItem) async -> Bool) {
        let outgoing = await store.nativeSources.liveSources.collectWritingSamples()
        return makeLiveOutgoingCheck(samples: outgoing)
    }

    nonisolated static func makeLiveOutgoingCheck(
        samples outgoing: [LiveWritingSample]
    ) -> (@Sendable (CorpusItem) async -> Bool) {
        { @Sendable candidate in
            Self.hasOutgoingReply(to: candidate, in: outgoing)
        }
    }

    @MainActor
    static func makeCandidateOutgoingCheck(
        corpus: [CorpusItem],
        enabledLiveSources: Set<LiveLocalSourceKind>,
        itemCheck: @escaping @Sendable (CorpusItem) async -> Bool
    ) -> ((ProactiveCandidate) async -> ProactiveIntelligenceEngine.OutgoingCheckResult) {
        let byID = Dictionary(corpus.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveTokens: Set<String> = Set(enabledLiveSources.compactMap { kind in
            switch kind {
            case .imessage, .whatsapp, .appleMail: return kind.rawValue
            case .notes: return nil
            }
        })
        return { candidate in
            var matchedItems: [CorpusItem] = []
            for sid in candidate.sourceIDs where sid != "calendar" {
                if let item = byID[sid] {
                    matchedItems.append(item)
                } else if let fuzzy = corpus.first(where: { $0.id == sid || $0.sourceID == sid }) {
                    matchedItems.append(fuzzy)
                }
            }
            for item in matchedItems {
                var enriched = item
                if let counterparty = candidate.counterparty, !counterparty.isEmpty {
                    enriched.text = "\(counterparty)\n\(item.text)"
                }
                if await itemCheck(enriched) {
                    return .alreadyAnsweredOrCompleted("Outgoing reply sent after this message arrived.")
                }
            }
            if candidate.sourceIDs.allSatisfy({ $0 == "calendar" }) {
                return .verifiedOpen("Calendar schedule verified read-only.")
            }
            let allCoveredLocally = !matchedItems.isEmpty && matchedItems.allSatisfy { item in
                let token = (item.sourceID ?? item.id).lowercased()
                return liveTokens.contains { token.contains($0.lowercased()) }
            }
            if allCoveredLocally {
                return .verifiedOpen("Checked local sent messages read-only; no outgoing reply found after arrival.")
            }
            return .unverified("Checked local outgoing samples; external sent state not conclusively verified.")
        }
    }

    nonisolated private static func filterConnectorItems(
        _ items: [CloudIngestedItem],
        rawQuery: String
    ) -> [CloudIngestedItem] {
        if rawQuery.isEmpty {
            return Array(items.sorted { $0.timestamp > $1.timestamp }.prefix(5))
        }

        var connectorHint = ""
        var keywordText = rawQuery
        if let colonIndex = rawQuery.firstIndex(of: ":") {
            connectorHint = String(rawQuery[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            keywordText = String(rawQuery[rawQuery.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let lowered = rawQuery.lowercased()
            let knownDescriptors: [String] = Array(
                Set(
                    items.flatMap { [$0.connectionID.lowercased(), $0.provider.rawValue.lowercased(), $0.provider.displayName.lowercased()] }
                        + OAuthMCPProvider.allCases.flatMap { [$0.rawValue.lowercased(), $0.displayName.lowercased()] }
                )
            ).sorted { $0.count > $1.count }

            for descriptor in knownDescriptors where !descriptor.isEmpty {
                if lowered == descriptor {
                    connectorHint = descriptor
                    keywordText = ""
                    break
                } else if lowered.hasPrefix(descriptor + " ") {
                    connectorHint = descriptor
                    keywordText = String(rawQuery.dropFirst(descriptor.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        var candidates = items
        if !connectorHint.isEmpty {
            let needle = connectorHint.lowercased()
            candidates = candidates.filter { item in
                item.provider.rawValue.lowercased() == needle
                    || item.provider.displayName.lowercased() == needle
                    || item.connectionID.lowercased() == needle
                    || item.provider.rawValue.localizedCaseInsensitiveContains(needle)
                    || item.provider.displayName.localizedCaseInsensitiveContains(needle)
                    || item.connectionID.localizedCaseInsensitiveContains(needle)
            }
            if candidates.isEmpty {
                return []
            }
        }

        let keywords = keywordText
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }

        if !keywords.isEmpty {
            candidates = candidates.filter { item in
                let combined = "\(item.title)\n\(item.subtitle)\n\(item.body)".lowercased()
                return keywords.allSatisfy { combined.contains($0) }
            }
        }

        return Array(candidates.sorted { $0.timestamp > $1.timestamp }.prefix(5))
    }

    nonisolated private static func hasOutgoingReply(
        to candidate: CorpusItem,
        in outgoing: [LiveWritingSample]
    ) -> Bool {
        guard let itemDate = candidate.itemDate, !outgoing.isEmpty else { return false }
        let combinedLower = "\(candidate.title)\n\(candidate.text)".lowercased()
        let haystackWords = Set(
            combinedLower
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
        )
        let haystackDigits = combinedLower.filter(\.isNumber)
        let ignoredRecipientTokens: Set<String> = [
            "com", "org", "net", "edu", "gov", "icloud", "gmail", "outlook",
            "hotmail", "yahoo", "proton", "mail", "email", "message", "imessage",
            "whatsapp", "from", "with", "chat", "thread", "team", "the", "and"
        ]

        for sample in outgoing {
            guard let sentAt = sample.sentAt, sentAt > itemDate else { continue }
            let rawRecipient = sample.recipient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !rawRecipient.isEmpty else { continue }

            // 1. Exact email match
            if let email = extractEmail(from: rawRecipient), combinedLower.contains(email) {
                return true
            }

            // 2. Phone number suffix match (>= 7 digits)
            let recipientDigits = rawRecipient.filter(\.isNumber)
            if recipientDigits.count >= 7, haystackDigits.count >= 7 {
                let tail = String(recipientDigits.suffix(min(10, recipientDigits.count)))
                if haystackDigits.contains(tail) {
                    return true
                }
            }

            // 3. Display-name / handle word-boundary token match
            let namePart: String
            if let angleIdx = rawRecipient.firstIndex(of: "<") {
                namePart = String(rawRecipient[..<angleIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let atIdx = rawRecipient.firstIndex(of: "@") {
                namePart = String(rawRecipient[..<atIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                namePart = rawRecipient
            }

            let tokens = namePart
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 && !ignoredRecipientTokens.contains($0) && !$0.allSatisfy(\.isNumber) }

            if tokens.count >= 2 {
                let fullPhrase = tokens.joined(separator: " ")
                if combinedLower.contains(fullPhrase)
                    || tokens.allSatisfy({ haystackWords.contains($0) })
                    || (tokens[0].count >= 4 && haystackWords.contains(tokens[0])) {
                    return true
                }
            } else if let single = tokens.first, haystackWords.contains(single) {
                return true
            }
        }
        return false
    }

    nonisolated private static func extractEmail(from text: String) -> String? {
        if let open = text.firstIndex(of: "<"),
           let close = text[open...].firstIndex(of: ">"),
           open < close {
            let inside = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            if inside.contains("@") { return inside }
        }
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let cleaned = piece.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'(),;[]"))
            if cleaned.contains("@"), cleaned.count >= 5 {
                return cleaned
            }
        }
        return nil
    }
}

// MARK: - Full Morning Brief Sheet / Workspace (`MorningBriefView`)

struct MorningBriefView: View {
    let store: AssistantStore
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var proactiveEngine = ProactiveIntelligenceEngine.shared
    @Bindable private var keepsakeGenerator = WelcomeKeepsakeGenerator.shared

    @State private var selectedTab: BriefTab = .morningCards
    @State private var showStandingInstructions = false
    @State private var standingDraft = ""
    @State private var selectedID: Suggestion.ID?
    @State private var request = ""
    @State private var status: String?
    @State private var drafting: Task<Void, Never>?
    @State private var showAgenda = false
    @State private var showDroppedLog = false

    private enum BriefTab: String, CaseIterable {
        case morningCards = "Morning Cards"
        case quickTodos = "Source TODOs"
    }

    init(store: AssistantStore, onStart: @escaping () -> Void = {}) {
        self.store = store
        self.onStart = onStart
    }

    private var legacyCards: [Suggestion] { store.suggestions.suggestions.filter { !$0.dismissed } }
    private var selectedLegacy: Suggestion? { legacyCards.first { $0.id == selectedID } }
    private var taskBusy: Bool {
        store.isRunning || store.voice.isBusy || store.knowledge.isIndexing || drafting != nil || proactiveEngine.isPreparing
    }

    private var feedAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if showStandingInstructions {
                standingInstructionsBar
            }
            if !store.preparation.agenda.isEmpty { agenda }

            if selectedTab == .morningCards {
                proactiveCardsBody
            } else {
                legacyFeed
                    .animation(feedAnimation, value: legacyCards.isEmpty)
            }

            if let status {
                Text(status)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 820, idealWidth: 880, minHeight: 580, idealHeight: 640)
        .relayPageBackground()
        .foregroundStyle(RelayTheme.ink)
        .font(RelayPageStyle.body)
        .tint(RelayColors.workbenchAccent)
        .relayPreferredAppearance()
        .disclosureGroupStyle(RelayDisclosureGroupStyle())
        .onAppear {
            standingDraft = proactiveEngine.standingInstructions
            store.suggestions.purge(records: store.knowledge.records)
            if let first = legacyCards.first {
                open(first.id)
                if proactiveEngine.activeCards.isEmpty {
                    selectedTab = .quickTodos
                }
            }
        }
        .onChange(of: legacyCards.map(\.id)) { _, ids in
            guard let selectedID, !ids.contains(selectedID) else { return }
            drafting?.cancel()
            self.selectedID = nil
            request = ""
        }
        .onDisappear { drafting?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Morning Brief")
                    .font(RelayPageStyle.title)
                    .accessibilityIdentifier("morningBrief.heading")
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }

            Text("Follow-ups and editable drafts, prepared read-only from your sources and calendar.")
                .font(RelayPageStyle.body)
                .foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if !legacyCards.isEmpty {
                    Picker("Brief view", selection: $selectedTab) {
                        ForEach(BriefTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                Spacer(minLength: 12)

                Button {
                    showStandingInstructions.toggle()
                } label: {
                    Label {
                        Text("Instructions")
                    } icon: {
                        Image(systemName: "slider.horizontal.3").font(RelayPageStyle.symbol)
                    }
                }
                .buttonStyle(RelayGhostButtonStyle())

                Button(proactiveEngine.isPreparing ? "Stop" : "Prepare Cards") {
                    if proactiveEngine.isPreparing {
                        Task { await proactiveEngine.cancelAndDrain() }
                    } else {
                        runProactivePreparation()
                    }
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(!proactiveEngine.isPreparing && (store.isRunning || !store.workspaceActionsReady))
                .accessibilityIdentifier("morningBrief.prepareProactive")
            }
            .font(RelayPageStyle.body)
        }
        .padding(.bottom, 6)
    }

    private var standingInstructionsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Standing instructions")
                .font(RelayPageStyle.sectionTitle)
            Text("Prioritizes Morning Card selection; never overrides factual accuracy.")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
            HStack(spacing: 8) {
                TextField("e.g. Prioritize unanswered investor emails and upcoming engineering deadlines", text: $standingDraft)
                    .textFieldStyle(.plain)
                    .font(RelayPageStyle.body)
                    .relayTextField()
                Button("Save") {
                    proactiveEngine.setStandingInstructions(standingDraft)
                    showStandingInstructions = false
                    status = "Saved standing instructions for Morning Cards."
                }
                .buttonStyle(RelayPrimaryButtonStyle())
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RelayColors.borderSubtle).frame(height: 0.7)
        }
    }

    @ViewBuilder
    private var proactiveCardsBody: some View {
        if proactiveEngine.activeCards.isEmpty && keepsakeGenerator.activeKeepsake == nil {
            VStack(spacing: 12) {
                Image(systemName: "sun.horizon")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(RelayColors.textSecondary)
                    .accessibilityHidden(true)
                Text(proactiveEngine.isPreparing ? "Preparing Morning Cards…" : "No Morning Cards waiting")
                    .font(RelayPageStyle.sectionTitle)
                Text(proactiveEngine.status)
                    .font(RelayPageStyle.body)
                    .foregroundStyle(RelayColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                HStack(spacing: 10) {
                    if store.suggestions.enabled {
                        Button("Scan Quick TODOs") {
                            store.knowledge.purgeStale(grants: store.grants)
                            store.suggestions.prepare(records: store.knowledge.records)
                            if let first = legacyCards.first {
                                open(first.id)
                                selectedTab = .quickTodos
                            } else {
                                status = store.suggestions.status
                            }
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(taskBusy)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ProactiveHomeDeckView(
                        store: store,
                        engine: proactiveEngine,
                        keepsakeGenerator: keepsakeGenerator,
                        onOpenFullBrief: nil,
                        onLaunched: {
                            dismiss()
                            onStart()
                        }
                    )

                    if !proactiveEngine.droppedCandidates.isEmpty {
                        DisclosureGroup(
                            "Filtered out during read-only verification · \(proactiveEngine.droppedCandidates.count)",
                            isExpanded: $showDroppedLog
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(proactiveEngine.droppedCandidates) { item in
                                    Text("• \(item.title) — \(item.reason)")
                                        .font(RelayPageStyle.caption)
                                        .foregroundStyle(RelayColors.textSecondary)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(RelayPageStyle.caption.weight(.medium))
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func runProactivePreparation() {
        status = nil
        store.knowledge.purgeStale(grants: store.grants)
        let localCorpus = MorningBriefCorpusBridge.buildCorpus(from: store)
        let calendar = MorningBriefCorpusBridge.buildCalendarOccurrences(from: store)

        Task { @MainActor in
            do {
                let cloudItems = await MorningBriefCorpusBridge.fetchConnectedCloudItems(from: store)
                let cloudCorpus = SemanticVaultBuilder.makeCorpusItems(
                    records: cloudItems.map { $0.toKnowledgeRecord() }
                )
                let combinedCorpus = localCorpus + cloudCorpus
                let gate = MorningBriefCorpusBridge.makeReadOnlyVaultGate(
                    vaultRoot: proactiveEngine.vaultRoot,
                    corpus: combinedCorpus,
                    calendar: calendar,
                    connectorItems: cloudItems
                )
                let itemOutgoingCheck = await MorningBriefCorpusBridge.makeLiveOutgoingCheck(from: store)
                let liveOutgoingCheck = MorningBriefCorpusBridge.makeCandidateOutgoingCheck(
                    corpus: combinedCorpus,
                    enabledLiveSources: store.nativeSources.liveSources.enabledSources,
                    itemCheck: itemOutgoingCheck
                )
                let generations = MorningBriefCorpusBridge.currentAccountGenerations(from: store)
                let cards = try await proactiveEngine.prepareCards(
                    corpus: combinedCorpus,
                    calendarOccurrences: calendar,
                    accountGenerations: generations,
                    isSourceCurrent: { [weak store] sid in
                        guard let store else { return false }
                        return MorningBriefCorpusBridge.isSourceCurrent(sid, store: store)
                    },
                    liveOutgoingCheck: liveOutgoingCheck,
                    readOnlyGate: gate,
                    complete: { messages in
                        try await store.auxiliaryText(messages)
                    }
                )
                _ = try? await keepsakeGenerator.generateOnceIfEligible { messages in
                    try await store.auxiliaryText(messages)
                }
                status = cards.isEmpty
                    ? "All caught up — nothing needed an action card right now."
                    : "Prepared \(cards.count) editable Morning \(cards.count == 1 ? "Card" : "Cards")."
            } catch is CancellationError {
                status = "Preparation stopped."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    // MARK: - Legacy `ProactiveSuggestions` Feed (`MorningBriefHandoffTests` Compatibility)

    @ViewBuilder
    private var legacyFeed: some View {
        if legacyCards.isEmpty {
            emptyLegacyState.transition(.opacity)
        } else {
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(legacyCards) { card in
                            let isSelected = card.id == selectedID
                            Button { open(card.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(card.title)
                                        .font(RelayPageStyle.sectionTitle)
                                        .foregroundStyle(isSelected ? RelayTheme.ink : RelayColors.textBright)
                                        .lineLimit(3)
                                    HStack(spacing: 6) {
                                        if let dueDay = card.dueDay {
                                            Text("Due \(dueDay)")
                                                .foregroundStyle(RelayColors.workbenchAccent)
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                        Text(sourceName(card))
                                            .foregroundStyle(RelayColors.textSecondary)
                                    }
                                    .font(RelayPageStyle.caption)
                                    .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    isSelected ? RelayColors.workbenchTint : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RelayPressStyle())
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .animation(feedAnimation, value: legacyCards.map(\.id))
                }
                .frame(width: 220)

                Divider().overlay(RelayTheme.line)

                ZStack(alignment: .topLeading) {
                    if let selectedLegacy {
                        detail(selectedLegacy)
                            .id(selectedLegacy.id)
                            .transition(.opacity)
                    } else {
                        Text("Choose a suggestion to see its source and review the task.")
                            .font(RelayPageStyle.body)
                            .foregroundStyle(RelayColors.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .animation(feedAnimation, value: selectedID)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var agenda: some View {
        DisclosureGroup("Upcoming calendar · \(store.preparation.agenda.count)", isExpanded: $showAgenda) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.preparation.agenda, id: \.id) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(RelayPageStyle.body.weight(.medium)).lineLimit(2)
                            Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarName)")
                                .font(RelayPageStyle.caption)
                                .foregroundStyle(RelayColors.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 92)
            .padding(.top, 6)
        }
        .font(RelayPageStyle.body.weight(.medium))
    }

    private var emptyLegacyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.horizon")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(RelayColors.textSecondary)
                .accessibilityHidden(true)
            Text("No suggestions ready")
                .font(RelayPageStyle.sectionTitle)
            Text(store.suggestions.enabled
                 ? "Prepare a brief from your current index, or switch to Morning Cards."
                 : "Enable proactive suggestions in Knowledge settings to get started.")
                .font(RelayPageStyle.body)
                .foregroundStyle(RelayColors.textSecondary)
                .multilineTextAlignment(.center)
            if store.suggestions.enabled {
                Button("Prepare from current index") {
                    store.knowledge.purgeStale(grants: store.grants)
                    store.suggestions.prepare(records: store.knowledge.records)
                    if let first = legacyCards.first { open(first.id) }
                    else { status = store.suggestions.status }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(taskBusy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ card: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.title).font(RelayPageStyle.sectionTitle).lineLimit(3)
                    Text(card.sourcePaths.first ?? sourceName(card))
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if !card.matchingSourcePaths.isEmpty {
                        let count = card.matchingSourcePaths.count
                        Text("\(count) identical \(count == 1 ? "source copy" : "source copies") also indexed")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .help(card.matchingSourcePaths.prefix(5).joined(separator: "\n"))
                    }
                    ScrollView {
                        Text(card.excerpt)
                            .font(RelayPageStyle.body)
                            .foregroundStyle(RelayColors.textBright)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .frame(height: 58)
                    .background(RelayTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RelayTheme.line, lineWidth: 1))

                    Text("Task request").font(RelayPageStyle.body.weight(.medium))
                    TextEditor(text: $request)
                        .font(RelayPageStyle.body)
                        .foregroundStyle(RelayTheme.ink)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 64)
                        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RelayColors.borderDefault, lineWidth: 1))
                        .accessibilityLabel("Task request")
                        .disabled(drafting != nil)
                    Text(!store.actionsReady ? "Load a local model in Settings to draft or start a task."
                         : (store.workspaceUsesCodex || store.workspaceUsesCodexCLI) ? "Starting this task switches the workspace to the local model."
                         : "Relay runs the request locally and shows any action that needs review.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            }
            .accessibilityIdentifier("morningBrief.detail")

            HStack(spacing: 8) {
                if let drafting {
                    Button("Stop draft") { drafting.cancel() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button("Improve draft") { improve(card.id) }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(taskBusy || !store.actionsReady || !validRequest)
                }
                Menu("More") {
                    Button("Snooze until tomorrow") { hide(card.id, snooze: true) }
                    Button("Dismiss suggestion") { hide(card.id, snooze: false) }
                }
                .font(RelayPageStyle.caption.weight(.medium))
                .fixedSize()
                .disabled(drafting != nil)
                Spacer()
                Button("Start Local Task") { start(card.id) }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(taskBusy || !validRequest || !store.actionsReady)
            }
            .accessibilityIdentifier("morningBrief.footer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var validRequest: Bool {
        !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.utf8.count <= 2_000
    }

    private func sourceName(_ card: Suggestion) -> String {
        card.sourcePaths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Local source"
    }

    private func open(_ id: Suggestion.ID) {
        drafting?.cancel()
        selectedID = nil
        request = ""
        do {
            let card = try store.reviewBriefSuggestion(id)
            selectedID = id
            request = store.suggestions.preparedDrafts[id] ?? card.title
            status = store.suggestions.preparedDrafts[id] == nil ? nil : "Draft prepared on this Mac. Review and edit before starting."
        } catch { status = error.localizedDescription }
    }

    private func improve(_ id: Suggestion.ID) {
        guard drafting == nil else { return }
        let currentRequest = request
        status = "Preparing an editable draft on this Mac…"
        drafting = Task { @MainActor in
            defer { drafting = nil }
            do {
                let updated = try await store.draftBriefTask(id, request: currentRequest)
                guard !Task.isCancelled, selectedID == id else { return }
                request = updated
                status = "Review and edit the draft before starting."
            } catch is CancellationError {
                if selectedID == id { status = "Draft preparation stopped." }
            } catch {
                if !Task.isCancelled, selectedID == id { status = error.localizedDescription }
            }
        }
    }

    private func hide(_ id: Suggestion.ID, snooze: Bool) {
        do {
            _ = try store.reviewBriefSuggestion(id)
            if snooze {
                guard store.suggestions.snooze(id, days: 1) else {
                    status = store.suggestions.errorMessage
                    return
                }
            } else { store.suggestions.dismiss(id) }
            selectedID = nil
            request = ""
            status = nil
            if let first = legacyCards.first { open(first.id) }
        } catch { status = error.localizedDescription }
    }

    private func start(_ id: Suggestion.ID) {
        do {
            try store.startBriefTask(id, request: request)
            dismiss()
            onStart()
        } catch { status = error.localizedDescription }
    }
}
