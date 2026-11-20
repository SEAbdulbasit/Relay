import SwiftUI

/// Step 1 interactive product stage for Relay onboarding.
/// Features a self-animating and user-playable Autopilot desktop simulator with a live Relay cursor,
/// an interactive Tactile Keycap & Live Tone Studio, and a 5-node living Memory Graph with clickable wikilinks.
struct OnboardingWelcomePreview: View {
    private var externalSelection: Binding<Int>?
    private let initialSelection: Int
    var compact = false
    var onSelect: ((Int) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var internalSelection: Int = 0

    // MARK: - Mode 01 (Autopilot) Interactive State
    enum AutopilotScenario: Int, CaseIterable, Identifiable {
        case juniper = 0
        case designSync = 1
        case receipt = 2

        var id: Int { rawValue }

        var pillTitle: String {
            switch self {
            case .juniper: "Book Table"
            case .designSync: "Move Meeting"
            case .receipt: "File Receipt"
            }
        }

        var icon: String {
            switch self {
            case .juniper: "fork.knife"
            case .designSync: "calendar.badge.clock"
            case .receipt: "doc.text.viewfinder"
            }
        }

        var sourceAppTitle: String {
            switch self {
            case .juniper: "Messages · James Chen"
            case .designSync: "Slack · #product-design"
            case .receipt: "Mail · Finance Ops"
            }
        }

        var sourceAppIcon: String {
            switch self {
            case .juniper: "message.fill"
            case .designSync: "number.square.fill"
            case .receipt: "envelope.fill"
            }
        }

        var senderInitials: String {
            switch self {
            case .juniper: "JC"
            case .designSync: "ML"
            case .receipt: "FO"
            }
        }

        var senderName: String {
            switch self {
            case .juniper: "James Chen"
            case .designSync: "Maya Lin"
            case .receipt: "Finance Ops"
            }
        }

        var incomingPrompt: String {
            switch self {
            case .juniper:
                "“Can you book Juniper for 4 this Saturday night and add a calendar hold?”"
            case .designSync:
                "“Conflict at 10 AM — can we move Thursday’s Design Sync to the afternoon?”"
            case .receipt:
                "“Attached Delta receipt ($418.00 SFO→JFK). Can you log this under Q4 Travel?”"
            }
        }

        var targetAppTitle: String {
            switch self {
            case .juniper: "juniper-sf.com/book"
            case .designSync: "Calendar · Thursday"
            case .receipt: "Expenses · Q4 Travel"
            }
        }

        var options: [String] {
            switch self {
            case .juniper: ["7:00 PM", "7:30 PM", "8:15 PM"]
            case .designSync: ["1:30 PM", "3:00 PM", "4:15 PM"]
            case .receipt: ["Airfare", "Lodging", "Client"]
            }
        }

        func draftedReply(for optionIndex: Int) -> String {
            let opt = options[min(max(0, optionIndex), options.count - 1)]
            switch self {
            case .juniper:
                return "Booked Juniper for 4 at \(opt) Saturday (Patio) + added calendar hold."
            case .designSync:
                return "Moved Design Sync to Thu \(opt) — all 4 attendees are free."
            case .receipt:
                return "Filed $418.00 Delta receipt under Q4 \(opt) — ready for 1-click sign-off."
            }
        }
    }

    @State private var autopilotScenario: AutopilotScenario = .juniper
    @State private var autopilotOptionIndex: Int = 1
    @State private var autopilotStep: Int = 2 // 0: reading chat, 1: clicking option, 2: confirmed & reply staged
    @State private var cursorRipple: Bool = false

    // MARK: - Mode 02 (Instant Draft) Interactive State
    enum DraftTone: String, CaseIterable, Identifiable {
        case concise = "Concise"
        case warm = "Warm"
        case executive = "Executive"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .concise: "bolt.fill"
            case .warm: "hand.wave.fill"
            case .executive: "checkmark.seal.fill"
            }
        }
    }

    @State private var selectedDraftTone: DraftTone = .concise
    @State private var includeCalendarContext: Bool = true
    @State private var includeMetricsContext: Bool = true
    @State private var keycapPressed: Bool = false
    @State private var streamedDraftChars: Int = 200
    @State private var draftStreamTask: Task<Void, Never>?

    // MARK: - Mode 03 (Memory Graph) Interactive State
    @State private var selectedStarIndex: Int = 0
    @State private var autoPlayTask: Task<Void, Never>?

    init(selection: Int = 0, compact: Bool = false, onSelect: ((Int) -> Void)? = nil) {
        self.externalSelection = nil
        self.initialSelection = selection
        self.compact = compact
        self.onSelect = onSelect
        self._internalSelection = State(initialValue: selection)
    }

    init(selection: Binding<Int>, compact: Bool = false, onSelect: ((Int) -> Void)? = nil) {
        self.externalSelection = selection
        self.initialSelection = selection.wrappedValue
        self.compact = compact
        self.onSelect = onSelect
        self._internalSelection = State(initialValue: selection.wrappedValue)
    }

    private var activeSelection: Int {
        externalSelection?.wrappedValue ?? internalSelection
    }

    private func selectMode(_ index: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            internalSelection = index
            externalSelection?.wrappedValue = index
            onSelect?(index)
        }
    }

    private var stageBodyHeight: CGFloat {
        compact ? 242 : 268
    }

    private var footerModeCode: String {
        switch activeSelection {
        case 1: "MODE 02 · LIVE TONE STUDIO"
        case 2: "MODE 03 · MEMORY GRAPH"
        default: "MODE 01 · INTERACTIVE AUTOPILOT"
        }
    }

    private var footerCaption: String {
        switch activeSelection {
        case 1:
            "Click the 3D Right ⌘ keycap, switch tones, or toggle context chips to live-stream replies."
        case 2:
            "Click any constellation node or [[Wikilink]] chip to traverse your local Markdown vault."
        default:
            "Switch scenarios or click any time slot on the right to watch Relay’s agent cursor act live."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("INTERACTIVE EXAMPLES · FICTIONAL DATA")
                .font(.relayCaptionStrong)
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.vertical, 8)
            stageHeaderBar

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            Group {
                switch activeSelection {
                case 1:
                    instantDraftStage
                case 2:
                    memoryGraphStage
                default:
                    autopilotActionStage
                }
            }
            .id(activeSelection)
            .transition(.opacity)
            .padding(compact ? 12 : 15)
            .frame(maxWidth: .infinity)
            .frame(height: stageBodyHeight)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            stageFooterBar
        }
        .background {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.055, green: 0.060, blue: 0.082),
                                Color(red: 0.035, green: 0.038, blue: 0.052)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RadialGradient(
                    colors: [
                        Color(red: 0.37, green: 0.42, blue: 0.92).opacity(0.16),
                        Color(red: 0.14, green: 0.65, blue: 0.92).opacity(0.08),
                        .clear
                    ],
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 10,
                    endRadius: 380
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.42), radius: 24, y: 12)
        .onAppear {
            internalSelection = initialSelection
            startStageChoreography()
        }
        .onChange(of: initialSelection) { _, newValue in
            if externalSelection == nil {
                internalSelection = newValue
            }
            startStageChoreography()
        }
        .onChange(of: activeSelection) { _, _ in
            startStageChoreography()
        }
        .onDisappear {
            autoPlayTask?.cancel()
            draftStreamTask?.cancel()
        }
    }

    // MARK: - Unified Architectural Header & Footer Bars (Mathematically Centered via ZStack)

    private var stageHeaderBar: some View {
        ZStack {
            // Center layer: 3-Mode Segmented Switcher mathematically dead-center on the stage X-axis
            HStack(spacing: 4) {
                modeTabButton(index: 0, number: "01", title: "Autopilot")
                modeTabButton(index: 1, number: "02", title: "Instant Draft")
                modeTabButton(index: 2, number: "03", title: "Memory Graph")
            }
            .padding(3)
            .background(Color.black.opacity(0.42), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)

            // Leading & Trailing accessories on the exact same vertical baseline
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    RelayMark(size: 14)
                    Text("INTERACTIVE STAGE")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 12)

                Button {
                    replayCurrentMode()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color(red: 0.38, green: 0.75, blue: 1.0))
                        Text(activeSelection == 0 ? "Replay Cursor" : (activeSelection == 1 ? "Stream Draft" : "Cycle Graph"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.90))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.black.opacity(0.28))
    }

    private func modeTabButton(index: Int, number: String, title: String) -> some View {
        let isSelected = activeSelection == index
        return Button {
            selectMode(index)
        } label: {
            HStack(spacing: 5.5) {
                Text(number)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        isSelected
                            ? Color(red: 0.38, green: 0.72, blue: 1.0)
                            : .white.opacity(0.42)
                    )
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.65))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                isSelected ? Color.white.opacity(0.11) : Color.clear,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.18) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var stageFooterBar: some View {
        HStack(spacing: 10) {
            Text(footerModeCode)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 0.98))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(red: 0.32, green: 0.56, blue: 0.96).opacity(0.14), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)

            Text(footerCaption)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color.black.opacity(0.24))
    }

    // MARK: - Mode 01: Interactive Dual-Window Autopilot Simulator with Live Relay Cursor

    private var autopilotActionStage: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                HStack(alignment: .top, spacing: 14) {
                    // Left Window: Interactive Scenario Switcher + Live Chat Thread with Pop-In Reply Bubble
                    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                        // Top Header with 3 Clickable Live Scenario Pills
                        HStack(spacing: 6) {
                            Image(systemName: autopilotScenario.sourceAppIcon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(RelayColors.accentBlue)
                            Text(autopilotScenario.sourceAppTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            HStack(spacing: 4) {
                                ForEach(AutopilotScenario.allCases) { scenario in
                                    let isCurrent = autopilotScenario == scenario
                                    Button {
                                        runAutopilotScenario(scenario, optionIndex: 1)
                                    } label: {
                                        HStack(spacing: 3.5) {
                                            Image(systemName: scenario.icon)
                                                .font(.system(size: 8.5, weight: .semibold))
                                            Text(scenario.pillTitle)
                                                .font(.system(size: 9.5, weight: isCurrent ? .semibold : .medium))
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(.white.opacity(isCurrent ? 0.98 : 0.62))
                                        .padding(.horizontal, 7)
                                        .frame(height: 20)
                                        .background(
                                            isCurrent ? RelayColors.accentBlue.opacity(0.28) : Color.white.opacity(0.05),
                                            in: Capsule()
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(
                                                isCurrent ? RelayColors.accentBlue.opacity(0.65) : Color.white.opacity(0.09),
                                                lineWidth: 0.75
                                            )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                        .frame(height: 22)

                        Rectangle().fill(Color.white.opacity(0.065)).frame(height: 1)

                        // Incoming Message Bubble
                        HStack(alignment: .top, spacing: 8) {
                            Text(autopilotScenario.senderInitials)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(RelayColors.accentBlue.opacity(0.32), in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.75))

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(autopilotScenario.senderName)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.92))
                                    Spacer()
                                    Text("9:41 AM")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.42))
                                }
                                Text(autopilotScenario.incomingPrompt)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.84))
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    autopilotStep == 0 ? RelayColors.accentBlue.opacity(0.55) : Color.white.opacity(0.07),
                                    lineWidth: 1
                                )
                        )

                        // Outgoing Staged Reply Bubble (Animates in when Relay finishes clicking the right app!)
                        HStack(alignment: .top, spacing: 8) {
                            Spacer(minLength: 16)

                            VStack(alignment: .trailing, spacing: 3) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(autopilotStep >= 2 ? RelayColors.accentEmerald : Color(red: 0.38, green: 0.72, blue: 1.0))
                                        .frame(width: 5.5, height: 5.5)
                                    Text(
                                        autopilotStep == 0
                                            ? "Relay inspecting request…"
                                            : (autopilotStep == 1 ? "Relay selecting \(autopilotScenario.options[autopilotOptionIndex])…" : "Unsent reply staged by Relay")
                                    )
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(autopilotStep >= 2 ? RelayColors.accentEmerald : Color(red: 0.45, green: 0.75, blue: 1.0))
                                }

                                Text(autopilotScenario.draftedReply(for: autopilotOptionIndex))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(autopilotStep >= 2 ? 0.95 : 0.48))
                                    .lineLimit(2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        autopilotStep >= 2
                                            ? RelayColors.accentBlue.opacity(0.22)
                                            : Color.white.opacity(0.03),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(
                                                autopilotStep >= 2
                                                    ? RelayColors.accentBlue.opacity(0.55)
                                                    : Color.white.opacity(0.08),
                                                lineWidth: 1
                                            )
                                    )
                            }
                        }

                        Spacer(minLength: 0)

                        // Aligned Footer Row
                        HStack(spacing: 6) {
                            stageSourceChip(icon: "cursorarrow.motionlines", text: "Live UI Control")
                            stageSourceChip(icon: "hand.raised.fill", text: "⌘. Instant Stop")
                            Spacer()
                            Text("Click any option →")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(height: 20)
                    }
                    .padding(compact ? 11 : 13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(red: 0.035, green: 0.038, blue: 0.048), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
                    )

                    // Right Window: Interactive Visual App Target (Clickable Time Slots / Categories + Live Confirmation)
                    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.48))
                            Text(autopilotScenario.targetAppTitle)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                            Spacer()
                            HStack(spacing: 3.5) {
                                Image(systemName: autopilotStep >= 2 ? "checkmark.circle.fill" : "sparkles")
                                    .font(.system(size: 9.5))
                                Text(autopilotStep >= 2 ? "Verified" : "Acting…")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            .foregroundStyle(autopilotStep >= 2 ? RelayColors.accentEmerald : Color(red: 0.45, green: 0.75, blue: 1.0))
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(height: 22)

                        Rectangle().fill(Color.white.opacity(0.065)).frame(height: 1)

                        // Visual Header Card for the Target App
                        HStack(spacing: 9) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(RelayColors.accentBlue.opacity(0.18))
                                    .frame(width: 32, height: 32)
                                Image(systemName: autopilotScenario.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                            }

                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(
                                    autopilotScenario == .juniper
                                        ? "Juniper · San Francisco"
                                        : (autopilotScenario == .designSync ? "Design Sync · 4 Attendees" : "Delta Air Lines · SFO→JFK")
                                )
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                                Text(
                                    autopilotScenario == .juniper
                                        ? "Table for 4 · Outdoor Patio"
                                        : (autopilotScenario == .designSync ? "Moving from Thu 10:00 AM" : "Amount: $418.00 · PDF OCR")
                                )
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }

                        // Interactive Option Buttons (User or Relay Cursor can click any of the 3 pills!)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                autopilotScenario == .juniper
                                    ? "SELECT SATURDAY TIME SLOT"
                                    : (autopilotScenario == .designSync ? "SELECT NEW THURSDAY SLOT" : "SELECT EXPENSE CATEGORY")
                            )
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(.white.opacity(0.45))

                            HStack(spacing: 6) {
                                ForEach(Array(autopilotScenario.options.enumerated()), id: \.offset) { idx, label in
                                    let isPicked = autopilotOptionIndex == idx
                                    Button {
                                        runAutopilotScenario(autopilotScenario, optionIndex: idx)
                                    } label: {
                                        HStack(spacing: 4) {
                                            if isPicked {
                                                Circle()
                                                    .fill(autopilotStep >= 2 ? RelayColors.accentEmerald : Color(red: 0.45, green: 0.75, blue: 1.0))
                                                    .frame(width: 5.5, height: 5.5)
                                            }
                                            Text(label)
                                                .font(.system(size: 10.5, weight: isPicked ? .bold : .medium, design: .monospaced))
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(.white.opacity(isPicked ? 1.0 : 0.68))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 26)
                                        .background(
                                            isPicked
                                                ? (autopilotStep >= 2 ? RelayColors.accentEmerald.opacity(0.22) : RelayColors.accentBlue.opacity(0.28))
                                                : Color.white.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .strokeBorder(
                                                    isPicked
                                                        ? (autopilotStep >= 2 ? RelayColors.accentEmerald.opacity(0.75) : Color(red: 0.45, green: 0.75, blue: 1.0))
                                                        : Color.white.opacity(0.10),
                                                    lineWidth: isPicked ? 1.2 : 0.75
                                                )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Visual Confirmation Banner inside Target App
                        HStack(spacing: 7) {
                            Image(systemName: autopilotStep >= 2 ? "checkmark.shield.fill" : "clock.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(autopilotStep >= 2 ? RelayColors.accentEmerald : Color(red: 0.45, green: 0.75, blue: 1.0))
                            Text(
                                autopilotStep >= 2
                                    ? "Staged at \(autopilotScenario.options[autopilotOptionIndex]) · Held for review"
                                    : "Relay clicking \(autopilotScenario.options[autopilotOptionIndex])…"
                            )
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.86))
                            .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            autopilotStep >= 2 ? RelayColors.accentEmerald.opacity(0.11) : Color.white.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    autopilotStep >= 2 ? RelayColors.accentEmerald.opacity(0.35) : Color.white.opacity(0.07),
                                    lineWidth: 0.75
                                )
                        )

                        Spacer(minLength: 0)

                        // Aligned Footer Row
                        HStack(spacing: 6) {
                            stageSourceChip(icon: "checkmark.shield.fill", text: "1-Click Review")
                            Spacer()
                            Button {
                                let nextOption = (autopilotOptionIndex + 1) % autopilotScenario.options.count
                                runAutopilotScenario(autopilotScenario, optionIndex: nextOption)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "cursorarrow.click.2")
                                        .font(.system(size: 8.5, weight: .semibold))
                                    Text("Try Next Slot")
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .foregroundStyle(.white.opacity(0.90))
                                .padding(.horizontal, 8.5)
                                .frame(height: 20)
                                .background(Color.white.opacity(0.09), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(height: 20)
                    }
                    .padding(compact ? 11 : 13)
                    .frame(width: compact ? 276 : 296)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(red: 0.042, green: 0.045, blue: 0.058), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        (autopilotStep >= 2 ? RelayColors.accentEmerald : RelayColors.accentBlue).opacity(0.42),
                                        Color.white.opacity(0.09)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                }

                // Live Animated Relay Agent Cursor Overlay (Glides from Left Chat -> Right Interactive Option Pill)
                relayAnimatedCursorOverlay(in: size)
            }
        }
    }

    private func relayAnimatedCursorOverlay(in size: CGSize) -> some View {
        // Compute target coordinate based on current autopilotStep and autopilotOptionIndex
        let rightPanelWidth: CGFloat = compact ? 276 : 296
        let rightPanelOriginX = size.width - rightPanelWidth
        let optionSlotWidth = (rightPanelWidth - 26) / 3.0
        let optionCenterX = rightPanelOriginX + 13 + optionSlotWidth * (CGFloat(autopilotOptionIndex) + 0.5)

        let targetPoint: CGPoint = {
            switch autopilotStep {
            case 0:
                // Hovering over the incoming message on the left
                return CGPoint(x: size.width * 0.28, y: size.height * 0.36)
            case 1:
                // Clicking the target option button on the right
                return CGPoint(x: optionCenterX, y: size.height * 0.56)
            default:
                // Resting near the verified confirmation badge on the right
                return CGPoint(x: optionCenterX + 12, y: size.height * 0.62)
            }
        }()

        return ZStack {
            if cursorRipple {
                Circle()
                    .strokeBorder(Color(red: 0.38, green: 0.78, blue: 1.0).opacity(0.75), lineWidth: 1.8)
                    .frame(width: 28, height: 28)
                    .scaleEffect(cursorRipple ? 1.35 : 0.5)
            }

            HStack(spacing: 4) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: Color(red: 0.22, green: 0.65, blue: 1.0), radius: 5)

                Text("Relay")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.35, green: 0.42, blue: 0.95),
                                Color(red: 0.12, green: 0.64, blue: 0.92)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.55), radius: 4, y: 2)
            }
        }
        .position(targetPoint)
        .allowsHitTesting(false)
    }

    private func runAutopilotScenario(_ scenario: AutopilotScenario, optionIndex: Int) {
        autoPlayTask?.cancel()
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.80)) {
            autopilotScenario = scenario
            autopilotOptionIndex = optionIndex
            autopilotStep = reduceMotion ? 2 : 0
            cursorRipple = false
        }
        guard !reduceMotion else { return }
        autoPlayTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) {
                autopilotStep = 1
                cursorRipple = true
            }
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.80)) {
                autopilotStep = 2
                cursorRipple = false
            }
        }
    }

    // MARK: - Mode 02: Interactive Tactile Keycap & Live Tone Studio

    private var currentConstructedDraft: String {
        let calBit = includeCalendarContext ? " for Thursday’s 2:30 PM review" : ""
        let metricBit = includeMetricsContext ? " (20→80 seat checklist complete)" : ""
        switch selectedDraftTone {
        case .concise:
            return "“Hi Alex — Friday is on track\(metricBit). We just need final SSO sign-off\(calBit).”"
        case .warm:
            return "“Hey Alex! Everything looks great for Friday’s rollout\(metricBit) — let’s lock in final SSO sign-off\(calBit).”"
        case .executive:
            return "“Alex — Friday release readiness is confirmed\(metricBit). Pending final Okta SSO sign-off\(calBit).”"
        }
    }

    private var instantDraftStage: some View {
        let fullText = currentConstructedDraft
        let visibleText = String(fullText.prefix(min(fullText.count, streamedDraftChars)))

        return HStack(alignment: .top, spacing: 14) {
            // Left Panel: Live Streaming Reply Editor
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack(spacing: 7) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.38, green: 0.72, blue: 1.0))
                    Text("Mail · Northstar Rollout Thread")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text("UNSENT · LIVE PREVIEW")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RelayColors.accentEmerald)
                }
                .frame(height: 22)

                Rectangle().fill(Color.white.opacity(0.065)).frame(height: 1)

                HStack(alignment: .top, spacing: 9) {
                    Text("AC")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color(red: 0.38, green: 0.45, blue: 0.95).opacity(0.35), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.75))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Alex Chen")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                            Text("· VP Engineering")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.50))
                            Spacer()
                            Text("Just now")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.42))
                        }
                        Text("“Are we still on track for Friday’s rollout, or waiting on the SSO security review?”")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.80))
                            .lineLimit(2)
                    }
                }

                // Live Streaming Reply Box
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.42, green: 0.78, blue: 1.0))
                        Text("Instant Draft · \(selectedDraftTone.rawValue) Voice")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                        Spacer()
                        Text("48 ms TTFT")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RelayColors.accentEmerald)
                    }

                    Text(visibleText)
                        .font(.system(size: compact ? 11.5 : 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineSpacing(2)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.25, green: 0.38, blue: 0.88).opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(red: 0.38, green: 0.65, blue: 0.98).opacity(0.35), lineWidth: 1)
                )

                Spacer(minLength: 0)

                // Aligned Footer Row showing active grounded sources
                HStack(spacing: 6) {
                    stageSourceChip(icon: "person.text.rectangle", text: "\(selectedDraftTone.rawValue) Tone")
                    if includeMetricsContext {
                        stageSourceChip(icon: "doc.text.fill", text: "northstar.md")
                    }
                    if includeCalendarContext {
                        stageSourceChip(icon: "calendar", text: "Thu 2:30 PM")
                    }
                    Spacer()
                }
                .frame(height: 20)
            }
            .padding(compact ? 11 : 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.035, green: 0.038, blue: 0.048), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
            )

            // Right Panel: Interactive 3D Tactile Keycap + Live Tone & Context Toggles
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0.38, green: 0.72, blue: 1.0))
                    Text("Live Tone Studio")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                    Spacer()
                    Text("CLICK TO REMIX")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(height: 22)

                Rectangle().fill(Color.white.opacity(0.065)).frame(height: 1)

                // Clickable 3D Tactile Right Command Keycap Button
                Button {
                    triggerInstantDraftStream()
                } label: {
                    HStack(spacing: 10) {
                        welcomeKeycap(symbol: "⌘", label: "right cmd")
                            .scaleEffect(keycapPressed ? 0.92 : 1.0)

                        Text("× 2")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.45, green: 0.78, blue: 1.0))
                            .fixedSize(horizontal: true, vertical: false)

                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("Click Keycap to Draft")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.96))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Text("Or pick a tone below")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.32), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Interactive Tone Pills (Concise / Warm / Executive)
                HStack(spacing: 5) {
                    ForEach(DraftTone.allCases) { tone in
                        let isSelected = selectedDraftTone == tone
                        Button {
                            selectedDraftTone = tone
                            triggerInstantDraftStream()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tone.icon)
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text(tone.rawValue)
                                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white.opacity(isSelected ? 1.0 : 0.65))
                            .frame(maxWidth: .infinity)
                            .frame(height: 25)
                            .background(
                                isSelected ? RelayColors.accentBlue.opacity(0.28) : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Color(red: 0.45, green: 0.75, blue: 1.0) : Color.white.opacity(0.09),
                                        lineWidth: isSelected ? 1.1 : 0.75
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Interactive Context Toggle Chips
                HStack(spacing: 6) {
                    contextToggleButton(
                        title: "Thu 2:30 Slot",
                        icon: "calendar",
                        isOn: includeCalendarContext
                    ) {
                        includeCalendarContext.toggle()
                        triggerInstantDraftStream()
                    }

                    contextToggleButton(
                        title: "80-Seat Metrics",
                        icon: "chart.bar.fill",
                        isOn: includeMetricsContext
                    ) {
                        includeMetricsContext.toggle()
                        triggerInstantDraftStream()
                    }
                }

                Spacer(minLength: 0)

                // Aligned Footer Row
                HStack(spacing: 6) {
                    stageSourceChip(icon: "lock.fill", text: "Clipboard Safe")
                    Spacer()
                    Text("⌘Z Undo Ready")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(height: 20)
            }
            .padding(compact ? 11 : 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(width: compact ? 276 : 296)
            .background(Color(red: 0.042, green: 0.045, blue: 0.058), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
            )
        }
    }

    private func contextToggleButton(title: String, icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isOn ? RelayColors.accentEmerald : .white.opacity(0.45))
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isOn ? 0.94 : 0.58))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(
                isOn ? RelayColors.accentEmerald.opacity(0.14) : Color.white.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isOn ? RelayColors.accentEmerald.opacity(0.45) : Color.white.opacity(0.08),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func triggerInstantDraftStream() {
        draftStreamTask?.cancel()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.65)) {
            keycapPressed = true
        }
        let targetCount = currentConstructedDraft.count
        if reduceMotion {
            streamedDraftChars = targetCount
            keycapPressed = false
            return
        }
        streamedDraftChars = 0
        draftStreamTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                keycapPressed = false
            }
            var c = 0
            while c < targetCount {
                guard !Task.isCancelled else { return }
                c = min(targetCount, c + 8)
                streamedDraftChars = c
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func welcomeKeycap(symbol: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.31, green: 0.38, blue: 0.90).opacity(0.85),
                    Color(red: 0.14, green: 0.58, blue: 0.88).opacity(0.70)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.65), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.25, green: 0.55, blue: 0.98).opacity(0.40), radius: 6, y: 2)
    }

    // MARK: - Mode 03: Living 5-Node Memory Graph with Animated Pulse Packets & Clickable Wikilinks

    private struct MemoryGraphNodeSpec {
        let index: Int
        let title: String
        let domain: String
        let subtitle: String
        let detail: String
        let linkedIndices: [Int]
        let sourceSummary: String
        let color: Color
        let point: CGPoint
    }

    private static let graphNodes: [MemoryGraphNodeSpec] = [
        MemoryGraphNodeSpec(
            index: 0,
            title: "Northstar",
            domain: "PROJECT",
            subtitle: "Vault/projects/northstar.md",
            detail: "Expanding from 20 to 80 seats. Friday rollout checklist linked to Thursday’s 2:30 PM SSO security review.",
            linkedIndices: [1, 2],
            sourceSummary: "Indexed from Apple Notes, Mail & Calendar",
            color: Color(red: 0.96, green: 0.68, blue: 0.28), // Amber
            point: CGPoint(x: 0.23, y: 0.23)
        ),
        MemoryGraphNodeSpec(
            index: 1,
            title: "Alex Chen",
            domain: "PERSON",
            subtitle: "Vault/people/alex-chen.md",
            detail: "VP Engineering at Northstar. Prefers concise bullet updates and benchmark diffs ahead of Thursday’s review.",
            linkedIndices: [0, 2],
            sourceSummary: "Indexed from Apple Mail & iMessage threads",
            color: Color(red: 0.22, green: 0.78, blue: 0.88), // Cyan
            point: CGPoint(x: 0.77, y: 0.23)
        ),
        MemoryGraphNodeSpec(
            index: 2,
            title: "Thu Sync",
            domain: "EVENT",
            subtitle: "Vault/events/thu-sync.md",
            detail: "Thursday 2:30 PM Architecture Review with Alex Chen & Maya Lin. Agenda covers SSO sign-off and Gemma 4 latency.",
            linkedIndices: [0, 3],
            sourceSummary: "Indexed from Apple Calendar & meeting notes",
            color: Color(red: 0.38, green: 0.72, blue: 1.00), // Sky Blue
            point: CGPoint(x: 0.50, y: 0.50)
        ),
        MemoryGraphNodeSpec(
            index: 3,
            title: "SSO Spec",
            domain: "SECURITY",
            subtitle: "Vault/topics/sso-review.md",
            detail: "Okta SAML + SCIM provisioning verified; final security sign-off scheduled during Thursday’s 2:30 PM sync.",
            linkedIndices: [0, 4],
            sourceSummary: "Indexed from Calendar & security checklist MD",
            color: Color(red: 0.58, green: 0.55, blue: 0.98), // Indigo
            point: CGPoint(x: 0.23, y: 0.77)
        ),
        MemoryGraphNodeSpec(
            index: 4,
            title: "Benchmarks",
            domain: "DATA",
            subtitle: "Vault/topics/benchmarks.md",
            detail: "On-device Gemma 4 E4B achieves 48 ms warm TTFT on Apple Silicon Unified Memory with 100% local privacy.",
            linkedIndices: [1, 2],
            sourceSummary: "Indexed from local PDF report & Markdown notes",
            color: Color(red: 0.18, green: 0.82, blue: 0.58), // Emerald
            point: CGPoint(x: 0.77, y: 0.77)
        )
    ]

    private var memoryGraphStage: some View {
        let nodes = Self.graphNodes
        let safeIdx = min(max(0, selectedStarIndex), nodes.count - 1)
        let activeNode = nodes[safeIdx]

        return HStack(alignment: .top, spacing: 14) {
            // Left Panel: Living 5-Node Constellation Canvas with Animated Edge Light Pulses
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.51, green: 0.55, blue: 0.97))
                    Text("Local Memory Graph · 57 Markdown Notes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text("Click any node")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                }
                .frame(height: 22)

                Rectangle().fill(Color.white.opacity(0.065)).frame(height: 1)

                GeometryReader { geo in
                    ZStack {
                        // Layer 1 (Background): Center-to-center edges + animated light packets
                        Canvas { context, size in
                            let pulsePhase: CGFloat = 0.52

                                let dustPoints: [(CGFloat, CGFloat, CGFloat, Double)] = [
                                    (0.08, 0.14, 1.4, 0.16), (0.92, 0.14, 1.4, 0.16),
                                    (0.50, 0.12, 1.3, 0.14), (0.50, 0.88, 1.3, 0.14),
                                    (0.10, 0.50, 1.2, 0.14), (0.90, 0.50, 1.2, 0.14)
                                ]
                                for (dx, dy, r, alpha) in dustPoints {
                                    let rect = CGRect(x: dx * size.width, y: dy * size.height, width: r, height: r)
                                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
                                }

                                // Non-crossing perimeter + center-hub edges
                                let edgePairs: [(Int, Int)] = [
                                    (0, 1), (3, 4), (0, 3), (1, 4),
                                    (2, 0), (2, 1), (2, 3), (2, 4)
                                ]

                                for (iA, iB) in edgePairs {
                                    let a = CGPoint(x: nodes[iA].point.x * size.width, y: nodes[iA].point.y * size.height)
                                    let b = CGPoint(x: nodes[iB].point.x * size.width, y: nodes[iB].point.y * size.height)
                                    var path = Path()
                                    path.move(to: a)
                                    path.addLine(to: b)

                                    let isIgnited = safeIdx == iA || safeIdx == iB
                                    if isIgnited {
                                        let shading = GraphicsContext.Shading.linearGradient(
                                            Gradient(colors: [
                                                nodes[iA].color.opacity(0.85),
                                                nodes[iB].color.opacity(0.85)
                                            ]),
                                            startPoint: a,
                                            endPoint: b
                                        )
                                        var glowCtx = context
                                        glowCtx.opacity = 0.22
                                        glowCtx.stroke(path, with: shading, lineWidth: 3.4)
                                        context.stroke(path, with: shading, lineWidth: 1.35)

                                        // Draw travelling light packet along ignited edge
                                        let fromPt = (safeIdx == iA) ? a : b
                                        let toPt = (safeIdx == iA) ? b : a
                                        let px = fromPt.x + (toPt.x - fromPt.x) * pulsePhase
                                        let py = fromPt.y + (toPt.y - fromPt.y) * pulsePhase
                                        let packetRect = CGRect(x: px - 2.5, y: py - 2.5, width: 5, height: 5)
                                        context.fill(Path(ellipseIn: packetRect), with: .color(.white.opacity(0.92)))
                                    } else {
                                        context.stroke(path, with: .color(.white.opacity(0.11)), lineWidth: 0.9)
                                    }
                                }
                            }

                        // Layer 2 (Foreground): 100% Opaque Interactive Node Capsules
                        ForEach(nodes, id: \.index) { node in
                            let isSelected = node.index == safeIdx
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                    selectedStarIndex = node.index
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(node.color)
                                        .frame(width: 6, height: 6)
                                        .shadow(color: node.color.opacity(0.8), radius: 3)

                                    Text(node.domain)
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(node.color)

                                    Text("·")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.32))

                                    Text(node.title)
                                        .font(.system(size: 10.5, weight: isSelected ? .bold : .medium))
                                        .foregroundStyle(.white.opacity(isSelected ? 1.0 : 0.84))
                                        .lineLimit(1)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 9.5)
                                .padding(.vertical, 5)
                                .background {
                                    Capsule()
                                        .fill(Color(red: 0.055, green: 0.060, blue: 0.080))
                                        .overlay {
                                            Capsule()
                                                .fill(node.color.opacity(isSelected ? 0.20 : 0.06))
                                        }
                                }
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            isSelected ? node.color.opacity(0.92) : Color.white.opacity(0.18),
                                            lineWidth: isSelected ? 1.3 : 1
                                        )
                                )
                                .scaleEffect(isSelected ? 1.05 : 1.0)
                                .shadow(color: .black.opacity(0.55), radius: 5, y: 2)
                            }
                            .buttonStyle(.plain)
                            .position(
                                x: node.point.x * geo.size.width,
                                y: node.point.y * geo.size.height
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.024, green: 0.027, blue: 0.038), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.75)
                )

                // Aligned Footer Row
                HStack(spacing: 6) {
                    stageSourceChip(icon: "folder.fill", text: "Local Vault")
                    stageSourceChip(icon: "arrow.triangle.branch", text: "5 Linked Notes")
                    Spacer()
                    Text("Plain Markdown")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.46))
                }
                .frame(height: 20)
            }
            .padding(compact ? 11 : 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.035, green: 0.038, blue: 0.048), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
            )

            // Right Panel: Interactive Note Inspector with Clickable Wikilink Navigation
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack(spacing: 5.5) {
                    Circle()
                        .fill(activeNode.color)
                        .frame(width: 6, height: 6)
                    Text(activeNode.domain)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(activeNode.color)
                    Spacer()
                    Text(activeNode.subtitle)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
                .frame(height: 22)

                Rectangle().fill(Color.white.opacity(0.065)).frame(height: 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(activeNode.title)
                        .font(.system(size: compact ? 15.5 : 17, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(.white)

                    Text(activeNode.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineSpacing(1.5)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Interactive Clickable Wikilink Navigation Box (Clicking a pill navigates the graph!)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text("LINKS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.9)
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 4)

                        ForEach(activeNode.linkedIndices, id: \.self) { targetIdx in
                            let targetNode = nodes[targetIdx]
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                    selectedStarIndex = targetIdx
                                }
                            } label: {
                                Text("[[\(targetNode.title)]]")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(targetNode.color)
                                    .padding(.horizontal, 6.5)
                                    .padding(.vertical, 2)
                                    .background(targetNode.color.opacity(0.16), in: Capsule())
                                    .overlay(Capsule().strokeBorder(targetNode.color.opacity(0.42), lineWidth: 0.75))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(activeNode.color)
                        Text(activeNode.sourceSummary)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.032), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.75)
                )

                Spacer(minLength: 0)

                // Aligned Footer Row with Interactive Jump-to-Draft button
                HStack(spacing: 6) {
                    stageSourceChip(icon: "lock.fill", text: "On-Device MD")
                    Spacer()
                    Button {
                        selectMode(1)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text("Use in Draft →")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(RelayColors.accentBlue.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .frame(height: 20)
            }
            .padding(compact ? 11 : 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(width: compact ? 276 : 296)
            .background(Color(red: 0.042, green: 0.045, blue: 0.058), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [activeNode.color.opacity(0.38), Color.white.opacity(0.09)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
    }

    // MARK: - Shared Helpers & Choreography

    private func stageSourceChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.white.opacity(0.78))
        .padding(.horizontal, 7.5)
        .frame(height: 20)
        .background(Color.white.opacity(0.065), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.11), lineWidth: 0.75))
    }

    private func replayCurrentMode() {
        switch activeSelection {
        case 1:
            triggerInstantDraftStream()
        case 2:
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                selectedStarIndex = (selectedStarIndex + 1) % Self.graphNodes.count
            }
        default:
            let nextOption = (autopilotOptionIndex + 1) % autopilotScenario.options.count
            runAutopilotScenario(autopilotScenario, optionIndex: nextOption)
        }
    }

    private func startStageChoreography() {
        autoPlayTask?.cancel()
        draftStreamTask?.cancel()
        streamedDraftChars = currentConstructedDraft.count

        if activeSelection == 0 {
            runAutopilotScenario(autopilotScenario, optionIndex: autopilotOptionIndex)
        } else if activeSelection == 1 {
            triggerInstantDraftStream()
        }
    }
}
