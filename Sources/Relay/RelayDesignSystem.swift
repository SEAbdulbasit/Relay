import SwiftUI
import AppKit
import Combine

// MARK: - Appearance Mode (Night / Light / System)

public enum RelayAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case system

    public static let storageKey = "relay.appearance.mode"
    public static let didChangeNotification = Notification.Name("RelayAppearanceModeDidChange")

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: return "Night"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    public var label: String { displayName }

    public var subtitle: String {
        switch self {
        case .dark: return "Dark appearance"
        case .light: return "Light appearance"
        case .system: return "Follow macOS"
        }
    }

    public var iconName: String {
        switch self {
        case .dark: return "moon.stars.fill"
        case .light: return "sun.max.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    public var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }

    public var next: RelayAppearanceMode {
        switch self {
        case .dark: return .light
        case .light: return .system
        case .system: return .dark
        }
    }

    public var toggledLightDark: RelayAppearanceMode {
        switch self {
        case .dark: return .light
        case .light: return .dark
        case .system:
            let isSystemLight = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
            return isSystemLight ? .dark : .light
        }
    }

    public static func fromStored(_ rawValue: String?) -> RelayAppearanceMode {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .dark
        }
        switch raw {
        case "dark", "night", "obsidian":
            return .dark
        case "light", "day", "daylight":
            return .light
        case "system", "auto":
            return .system
        default:
            return RelayAppearanceMode(rawValue: raw) ?? .dark
        }
    }

    public static var current: RelayAppearanceMode {
        get {
            fromStored(UserDefaults.standard.string(forKey: storageKey))
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
            NotificationCenter.default.post(name: didChangeNotification, object: newValue)
        }
    }

    @MainActor
    public static func applyAppearance(_ mode: RelayAppearanceMode? = nil) {
        let resolved = mode ?? current
        if let mode {
            if UserDefaults.standard.string(forKey: storageKey) != mode.rawValue {
                UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
            }
        }
        if NSApp != nil {
            NSApplication.shared.appearance = resolved.nsAppearance
        }
    }
}

@MainActor
public final class RelayThemeManager: ObservableObject {
    public static let shared = RelayThemeManager()

    @Published public var appearanceMode: RelayAppearanceMode {
        didSet {
            guard oldValue != appearanceMode else { return }
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: RelayAppearanceMode.storageKey)
            RelayAppearanceMode.applyAppearance(appearanceMode)
            NotificationCenter.default.post(name: RelayAppearanceMode.didChangeNotification, object: appearanceMode)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    public init() {
        let initial = RelayAppearanceMode.current
        self.appearanceMode = initial
        RelayAppearanceMode.applyAppearance(initial)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let latest = RelayAppearanceMode.current
                if self.appearanceMode != latest {
                    self.appearanceMode = latest
                }
                RelayAppearanceMode.applyAppearance(latest)
            }
            .store(in: &cancellables)
    }

    public var colorScheme: ColorScheme? {
        appearanceMode.colorScheme
    }

    public func setMode(_ mode: RelayAppearanceMode) {
        appearanceMode = mode
    }

    public func toggleLightDark() {
        appearanceMode = appearanceMode.toggledLightDark
    }

    public func cycleMode() {
        appearanceMode = appearanceMode.next
    }
}

struct RelayPreferredAppearanceModifier: ViewModifier {
    @AppStorage(RelayAppearanceMode.storageKey) private var rawMode: String = RelayAppearanceMode.dark.rawValue

    private var mode: RelayAppearanceMode {
        RelayAppearanceMode.fromStored(rawMode)
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(mode.colorScheme)
            .onChange(of: rawMode, initial: true) { _, newValue in
                let resolved = RelayAppearanceMode.fromStored(newValue)
                RelayAppearanceMode.applyAppearance(resolved)
            }
    }
}

extension View {
    /// Applies the user's selected RelayAppearanceMode (.dark, .light, or .system) and keeps AppKit/SwiftUI synced.
    func relayPreferredAppearance() -> some View {
        modifier(RelayPreferredAppearanceModifier())
    }

    /// Plain macOS text fields dim native placeholders even when a prompt supplies
    /// a color. Draw the empty-state prompt once at the shared readable contrast.
    func relayTextFieldPrompt(_ prompt: String, when isEmpty: Bool, font: Font = .relayBody) -> some View {
        overlay(alignment: .leading) {
            if isEmpty {
                Text(prompt)
                    .font(font)
                    .foregroundStyle(RelayColors.textMuted)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Canonical Spacing, Corner Radii & Control Scale
enum RelaySpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

enum RelayRadius {
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let pill: CGFloat = 999
}

enum RelayControlHeight {
    static let compact: CGFloat = 28
    static let pill: CGFloat = 30
    static let bar: CGFloat = 34
    static let composer: CGFloat = 38
    static let header: CGFloat = 56
}

// MARK: - Adaptive palette
enum RelayColors {
    private static let appearanceOverrideThreadKey = "relay.appearance.drawingOverride"

    private static func isLightAppearance(_ appearance: NSAppearance) -> Bool {
        if let overrideRaw = Thread.current.threadDictionary[appearanceOverrideThreadKey] as? String,
           let overrideMode = RelayAppearanceMode(rawValue: overrideRaw) {
            switch overrideMode {
            case .light:
                return true
            case .dark:
                return false
            case .system:
                return appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
            }
        }
        switch RelayAppearanceMode.current {
        case .light:
            return true
        case .dark:
            return false
        case .system:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
        }
    }

    static func adaptive(
        dark: (CGFloat, CGFloat, CGFloat, CGFloat),
        light: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgba = isLightAppearance(appearance) ? light : dark
            return NSColor(srgbRed: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
        })
    }

    static func resolvedNSColor(_ color: Color, for mode: RelayAppearanceMode) -> NSColor {
        let targetAppearance = mode.nsAppearance ?? NSApp?.effectiveAppearance ?? NSAppearance(named: .darkAqua)
        let threadDict = Thread.current.threadDictionary
        let previousOverride = threadDict[appearanceOverrideThreadKey]
        threadDict[appearanceOverrideThreadKey] = mode.rawValue
        defer {
            if let previousOverride {
                threadDict[appearanceOverrideThreadKey] = previousOverride
            } else {
                threadDict.removeObject(forKey: appearanceOverrideThreadKey)
            }
        }
        var resolved: NSColor = NSColor(color)
        targetAppearance?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return resolved.usingColorSpace(.sRGB) ?? resolved
    }

    static var accentNSColor: NSColor {
        resolvedNSColor(accentBlue, for: RelayAppearanceMode.current)
    }

    // Relay's ink and porcelain surfaces are shared by the workspace and utilities.
    static let pitch = adaptive(
        dark: (13/255, 18/255, 20/255, 1), light: (241/255, 245/255, 243/255, 1)
    )
    static let canvas = adaptive(
        dark: (16/255, 21/255, 24/255, 1), light: (247/255, 249/255, 248/255, 1)
    )
    static let background = canvas
    static let cardBG = adaptive(
        dark: (22/255, 28/255, 31/255, 1), light: (1, 1, 1, 1)
    )
    static let surface = adaptive(
        dark: (28/255, 35/255, 38/255, 1), light: (241/255, 245/255, 243/255, 1)
    )
    static let surfaceElevated = adaptive(
        dark: (35/255, 43/255, 46/255, 1), light: (1, 1, 1, 1)
    )
    static let glassBackdrop = adaptive(
        dark: (22/255, 28/255, 31/255, 0.96), light: (1, 1, 1, 0.96)
    )

    // Interactive Fills
    static let subtleFill = adaptive(
        dark: (1.0, 1.0, 1.0, 0.04),
        light: (15/255, 23/255, 42/255, 0.03)
    )
    static let hoverFill = adaptive(
        dark: (1.0, 1.0, 1.0, 0.065),
        light: (15/255, 23/255, 42/255, 0.045)
    )
    static let activeFill = adaptive(
        dark: (1.0, 1.0, 1.0, 0.11),
        light: (15/255, 23/255, 42/255, 0.075)
    )
    static let badgeFill = adaptive(
        dark: (1.0, 1.0, 1.0, 0.07),
        light: (15/255, 23/255, 42/255, 0.05)
    )

    // Crisp 1px Hairline Borders & Card Elevation Highlights
    static let borderSubtle = adaptive(
        dark: (1.0, 1.0, 1.0, 0.075),
        light: (15/255, 23/255, 42/255, 0.07)
    )
    static let borderDefault = adaptive(
        dark: (1.0, 1.0, 1.0, 0.12),
        light: (15/255, 23/255, 42/255, 0.11)
    )
    static let borderStrong = adaptive(
        dark: (1.0, 1.0, 1.0, 0.25),
        light: (17/255, 19/255, 24/255, 0.20)
    )
    static let borderFocus = adaptive(
        dark: (1.0, 1.0, 1.0, 0.24),
        light: (17/255, 19/255, 24/255, 0.22)
    )
    static let cardTopHighlight = adaptive(
        dark: (1.0, 1.0, 1.0, 0.038),
        light: (1.0, 1.0, 1.0, 0.70)
    )
    static let cardRimHighlight = adaptive(
        dark: (1.0, 1.0, 1.0, 0.16),
        light: (17/255, 19/255, 24/255, 0.04)
    )
    static let cardShadow = adaptive(
        dark: (0.0, 0.0, 0.0, 0.28),
        light: (15/255, 23/255, 42/255, 0.05)
    )

    static let paper = adaptive(
        dark: (245/255, 247/255, 250/255, 1.0),
        light: (17/255, 19/255, 24/255, 1.0)
    )
    static let moss = adaptive(
        dark: (0.45, 0.65, 1.0, 1.0),
        light: (37/255, 99/255, 235/255, 1.0)
    )

    // Typography Ink Hierarchy
    static let textPrimary = adaptive(
        dark: (245/255, 247/255, 250/255, 1.0),
        light: (17/255, 19/255, 24/255, 1.0)
    )
    static let textBright = adaptive(
        dark: (234/255, 238/255, 245/255, 1.0),
        light: (24/255, 27/255, 34/255, 1.0)
    )
    static let textStatus = adaptive(
        dark: (220/255, 226/255, 236/255, 1.0),
        light: (37/255, 42/255, 52/255, 1.0)
    )
    static let textSecondary = adaptive(
        dark: (196/255, 198/255, 205/255, 1.0),
        light: (69/255, 73/255, 82/255, 1.0)
    )
    static let textMuted = adaptive(
        dark: (166/255, 170/255, 182/255, 1.0),
        light: (89/255, 95/255, 107/255, 1.0)
    )
    static let textDim = adaptive(
        dark: (151/255, 158/255, 173/255, 1.0),
        light: (103/255, 111/255, 125/255, 1.0)
    )
    static let textFaint = adaptive(
        dark: (151/255, 158/255, 173/255, 1.0),
        light: (103/255, 111/255, 125/255, 1.0)
    )

    // Identity accent denotes a place or affordance, never a verified result.
    static let workbenchAccent = adaptive(
        dark: (130/255, 205/255, 184/255, 1),
        light: (27/255, 91/255, 78/255, 1)
    )
    static let workbenchTint = adaptive(
        dark: (130/255, 205/255, 184/255, 0.08),
        light: (27/255, 91/255, 78/255, 0.055)
    )

    // Restrained Semantic & Spectrum Accents (Balanced for Night & Day)
    static let accentEmerald = adaptive(
        dark: (52/255, 211/255, 153/255, 1.0),
        light: (4/255, 119/255, 83/255, 1.0)
    )
    static let accentAmethyst = adaptive(
        dark: (192/255, 168/255, 250/255, 1.0),
        light: (124/255, 58/255, 237/255, 1.0)
    )
    static let accentPeriwinkle = adaptive(
        dark: (156/255, 163/255, 219/255, 1.0),
        light: (79/255, 70/255, 229/255, 1.0)
    )
    static let accentBlue = adaptive(
        dark: (132/255, 184/255, 255/255, 1.0),
        light: (37/255, 99/255, 235/255, 1.0)
    )
    static let accentCoral = adaptive(
        dark: (248/255, 113/255, 113/255, 1.0),
        light: (205/255, 33/255, 33/255, 1.0)
    )
    static let accentAmber = adaptive(
        dark: (251/255, 191/255, 36/255, 1.0),
        light: (166/255, 84/255, 4/255, 1.0)
    )
    static let accentGold = adaptive(
        dark: (244/255, 214/255, 154/255, 1.0),
        light: (180/255, 83/255, 9/255, 1.0)
    )
    static let accentCyan = adaptive(
        dark: (165/255, 243/255, 252/255, 1.0),
        light: (7/255, 112/255, 138/255, 1.0)
    )
    static let knowledgeLink = adaptive(
        dark: (228/255, 232/255, 240/255, 1.0),
        light: (30/255, 41/255, 59/255, 1.0)
    )

    // Semantic roles for messages and state indicators. Pair with a label or icon.
    static let success = accentEmerald
    static let warning = accentAmber
    static let error = accentCoral
    static let information = accentBlue
    static let focusRing = accentBlue

    // Button Tokens
    static let buttonFace = adaptive(
        dark: (245/255, 247/255, 250/255, 1.0),
        light: (17/255, 19/255, 24/255, 1.0)
    )
    static let buttonInk = adaptive(
        dark: (16/255, 19/255, 25/255, 1.0),
        light: (1.0, 1.0, 1.0, 1.0)
    )
}

// MARK: - Subtle Matte Gradients
enum RelayGradients {
    static let glowStops: [Color] = RelayTheme.prismStops

    static let ambientTopGlow = RadialGradient(
        colors: [
            RelayColors.accentBlue.opacity(0.06),
            RelayColors.accentAmethyst.opacity(0.03),
            Color.clear
        ],
        center: .top,
        startRadius: 20,
        endRadius: 560
    )

    enum Linear {
        static let spectrum = RelayTheme.prismGradient
    }

    enum Radial {
        static let onboardingGlow = RelayGradients.ambientTopGlow
    }
}

// MARK: - Relay Theme Foundations
enum RelayTheme {
    static let canvas = RelayColors.canvas
    static let background = RelayColors.canvas
    static let surface = RelayColors.surface
    static let surfaceElevated = RelayColors.surfaceElevated
    static let cardBG = RelayColors.cardBG
    static let accent = RelayColors.accentBlue
    static let ink = RelayColors.textPrimary
    static let muted = RelayColors.textMuted
    static let line = RelayColors.borderSubtle
    static let sidebar = RelayColors.pitch
    static let contentWidth: CGFloat = 1080
    static let readingMaxWidth: CGFloat = 780
    static let composerMaxWidth: CGFloat = 900
    static let wideContentWidth: CGFloat = 1240
    static let inset: CGFloat = RelaySpace.lg
    static let radius: CGFloat = RelayRadius.md
    static let messageLineSpacing: CGFloat = 4


    // These color swatches are also used by the Relay website.
    static let prismStops: [Color] = [
        0x4A90E2, // #4a90e2
        0x6C5CE5, // #6c5ce5
        0x9B48D4, // #9b48d4
        0xE8388F, // #e8388f
        0xFF4646, // #ff4646
        0xFF8E3C, // #ff8e3c
        0xFDE2A3, // #fde2a3
    ].map { swatch in
        Color(
            red: Double((swatch >> 16) & 255) / 255,
            green: Double((swatch >> 8) & 255) / 255,
            blue: Double(swatch & 255) / 255
        )
    }

    static let prismGradient = LinearGradient(colors: prismStops, startPoint: .leading, endPoint: .trailing)
    static let prismAngularGradient = AngularGradient(colors: prismStops + Array(prismStops.prefix(1)), center: .center)

    // Agent Role Color Mapping
    static func agentColor(for role: String) -> Color {
        let normalized = role.lowercased()
        if normalized.contains("plan") { return RelayColors.accentAmethyst }
        if normalized.contains("nav") { return RelayColors.accentBlue }
        if normalized.contains("exec") { return RelayColors.accentAmber }
        if normalized.contains("crit") || normalized.contains("verif") { return RelayColors.accentEmerald }
        return RelayColors.textSecondary
    }

    static func agentColor(for role: AgentRole) -> Color {
        agentColor(for: role.rawValue)
    }

    // Agent Role Icon Mapping
    static func agentIcon(for role: String) -> String {
        let normalized = role.lowercased()
        if normalized.contains("plan") { return "brain.head.profile" }
        if normalized.contains("nav") { return "safari" }
        if normalized.contains("exec") { return "bolt.fill" }
        if normalized.contains("crit") || normalized.contains("verif") { return "checkmark.shield.fill" }
        return "sparkle"
    }

    static func agentIcon(for role: AgentRole) -> String {
        agentIcon(for: role.rawValue)
    }

    static func agentBadge(for role: AgentRole) -> (color: Color, icon: String) {
        (agentColor(for: role), agentIcon(for: role))
    }
}

// MARK: - Antigravity Optical Typography

enum RelayTypography {
    static func font(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        Font.system(size: size, weight: weight, design: design)
    }
}

extension View {
    func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight, design: .default))
    }
}

extension Font {
    // Larger editorial type is reserved for introductions; working content stays compact.
    static let relayWorkbenchHero = Font.system(size: 40, weight: .semibold)
    static let relayWorkbenchTitle = Font.system(size: 28, weight: .semibold)
    static let relayEyebrow = Font.system(size: 10.5, weight: .medium, design: .monospaced)

    // Working typography
    static let relayDisplay = Font.system(size: 22, weight: .semibold, design: .default)
    static let relayLargeTitle = Font.system(size: 19, weight: .semibold, design: .default)
    static let relayTitle = Font.system(size: 16, weight: .semibold, design: .default)
    static let relayHeadline = Font.system(size: 14.5, weight: .semibold, design: .default)
    static let relaySubheadline = Font.system(size: 13, weight: .medium, design: .default)
    static let relayConversation = Font.system(size: 15, weight: .regular, design: .default)
    static let relayBody = Font.system(size: 13.5, weight: .regular, design: .default)
    static let relayBodyStrong = Font.system(size: 13.5, weight: .medium, design: .default)
    static let relayCallout = Font.system(size: 12.5, weight: .regular, design: .default)
    static let relayCaption = Font.system(size: 11.5, weight: .regular, design: .default)
    static let relayCaptionStrong = Font.system(size: 11.5, weight: .medium, design: .default)
    static let relayMicro = Font.system(size: 10.5, weight: .medium, design: .default)
    static let relayMono = Font.system(size: 12, weight: .regular, design: .monospaced).monospacedDigit()
    static let relayMonoSmall = Font.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit()

    // Display & Hero Aliases (Crisp Geometric Sans — No jarring serif mixing)
    static let relayDisplayHero = Font.system(size: 24, weight: .semibold, design: .default)
    static let relayDisplayTitle = Font.system(size: 19, weight: .semibold, design: .default)
    static let relayEditorialHero = Font.system(size: 26, weight: .semibold, design: .default)
    static let relayEditorialTitle = Font.system(size: 20, weight: .semibold, design: .default)
    static let relayEditorialSubtitle = Font.system(size: 13.5, weight: .regular, design: .default)
}


struct OnboardingWhisper: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.relayMonoSmall)
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(RelayColors.textSecondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RelayColors.badgeFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )
    }
}

struct RelayMonoCaps: View {
    let text: String
    var size: CGFloat = 10.5
    var tracking: CGFloat = 1.2
    var color: Color = RelayColors.textMuted

    init(_ text: String, size: CGFloat = 10.5, tracking: CGFloat = 1.2, color: Color = RelayColors.textMuted) {
        self.text = text
        self.size = size
        self.tracking = tracking
        self.color = color
    }

    init(text: String, color: Color = RelayColors.textMuted, size: CGFloat = 10.5, tracking: CGFloat = 1.2) {
        self.text = text
        self.size = size
        self.tracking = tracking
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: max(9.5, size), weight: .semibold, design: .monospaced))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}


// MARK: - Status Indicator & Antigravity Components

struct RelayHealthDot: View {
    static let warnAmber = RelayColors.accentAmber
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16)).frame(width: 14, height: 14)
            Circle().strokeBorder(color.opacity(0.32), lineWidth: 0.75).frame(width: 11, height: 11)
            Circle().fill(color).frame(width: 5, height: 5)
        }
        .accessibilityHidden(true)
    }
}

/// Crisp Antigravity pill badge for statuses, tags, and metadata.
struct RelayBadge: View {
    let text: String
    var icon: String? = nil
    var tint: Color = RelayColors.textSecondary
    var prominent: Bool = false

    init(_ text: String, icon: String? = nil, tint: Color = RelayColors.textSecondary, prominent: Bool = false) {
        self.text = text
        self.icon = icon
        self.tint = tint
        self.prominent = prominent
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.relayMicro)
                .lineLimit(1)
        }
        .foregroundStyle(prominent ? tint : RelayColors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            prominent ? tint.opacity(0.12) : RelayColors.badgeFill,
            in: Capsule(style: .continuous)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(prominent ? tint.opacity(0.28) : RelayColors.borderSubtle, lineWidth: 1)
        )
    }
}

/// Antigravity surface card with crisp 1px border, subtle top-edge highlight, and adaptive Night/Day elevation.
struct RelaySurfaceCard<Content: View>: View {
    var padding: CGFloat = RelaySpace.md
    var cornerRadius: CGFloat = RelayRadius.md
    var elevated: Bool = false
    var strokeColor: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content()
            .padding(padding)
            .background(elevated ? RelayColors.surface : RelayColors.cardBG, in: shape)
            .overlay(shape.strokeBorder(strokeColor ?? RelayColors.borderSubtle, lineWidth: 0.7))
    }
}

/// Crisp Antigravity text field container modifier with focus border and adaptive surface fill.
struct RelayTextFieldModifier: ViewModifier {
    var focused: Bool = false
    var cornerRadius: CGFloat = 10
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 8

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .font(.relayBody)
            .foregroundStyle(RelayColors.textPrimary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(RelayColors.surface, in: shape)
            .overlay(
                shape.strokeBorder(
                    focused ? RelayColors.borderFocus : RelayColors.borderDefault,
                    lineWidth: 1
                )
            )
    }
}

extension View {
    func relayTextField(
        focused: Bool = false,
        cornerRadius: CGFloat = 10,
        horizontalPadding: CGFloat = 12,
        verticalPadding: CGFloat = 8
    ) -> some View {
        modifier(
            RelayTextFieldModifier(
                focused: focused,
                cornerRadius: cornerRadius,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding
            )
        )
    }
}

/// Compact one-click Night / Light / System mode switcher button for headers & toolbars.
struct RelayAppearanceToggleButton: View {
    @AppStorage(RelayAppearanceMode.storageKey) private var rawMode: String = RelayAppearanceMode.dark.rawValue
    var showsLabel: Bool = false
    @State private var hovered = false

    private var mode: RelayAppearanceMode {
        RelayAppearanceMode.fromStored(rawMode)
    }

    var body: some View {
        Button {
            let next = mode.toggledLightDark
            rawMode = next.rawValue
            RelayThemeManager.shared.setMode(next)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 12.5, weight: .medium))
                if showsLabel {
                    Text(mode.displayName)
                        .font(.relayCaptionStrong)
                }
            }
            .foregroundStyle(hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
            .padding(.horizontal, showsLabel ? 10 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .background(
                hovered ? RelayColors.hoverFill : RelayColors.subtleFill,
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(hovered ? RelayColors.borderDefault : RelayColors.borderSubtle, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .help("Appearance: \(mode.displayName) (Click to switch Night / Light mode)")
        .accessibilityLabel("Switch appearance mode, current mode \(mode.displayName)")
    }
}

/// Segmented Night / Light / System appearance picker for Settings & preferences.
struct RelayAppearancePicker: View {
    @AppStorage(RelayAppearanceMode.storageKey) private var rawMode: String = RelayAppearanceMode.dark.rawValue

    private var selectedMode: RelayAppearanceMode {
        RelayAppearanceMode.fromStored(rawMode)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RelayAppearanceMode.allCases) { option in
                let isSelected = selectedMode == option
                Button {
                    rawMode = option.rawValue
                    RelayThemeManager.shared.setMode(option)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: option.iconName)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(option.displayName)
                            .font(.relayCaptionStrong)
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? RelayColors.surfaceElevated : Color.clear)
                            .shadow(
                                color: isSelected ? RelayColors.cardShadow.opacity(0.45) : .clear,
                                radius: 2,
                                x: 0,
                                y: 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(RelayPressStyle())
            }
        }
        .padding(3)
        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Frosted Glass & Editorial Card Modifiers
struct RelayGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var strokeColor: Color = RelayColors.borderSubtle
    var fillOpacity: Double = 0.05

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(RelayColors.cardBG, in: shape)
            .overlay(shape.strokeBorder(strokeColor, lineWidth: 0.7))
    }
}

extension View {
    func relayGlassCard(cornerRadius: CGFloat = 14, strokeColor: Color = RelayColors.borderSubtle) -> some View {
        modifier(RelayGlassCardModifier(cornerRadius: cornerRadius, strokeColor: strokeColor))
    }

    func relaySurfaceCard(
        cornerRadius: CGFloat = RelayRadius.md,
        strokeColor: Color = RelayColors.borderSubtle
    ) -> some View {
        modifier(RelayGlassCardModifier(cornerRadius: cornerRadius, strokeColor: strokeColor))
    }
}


// MARK: - Relay Brand

struct RelayShortcutGlyph: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 11 / 28, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 17 / 28, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}

@MainActor
enum RelayBrandMenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let outline = NSBezierPath(
                roundedRect: NSRect(x: 1.75, y: 2.5, width: 14.5, height: 13),
                xRadius: 3.5, yRadius: 3.5
            )
            NSColor.black.setStroke()
            outline.lineWidth = 1.35
            outline.stroke()

            let glyph = NSBezierPath()
            glyph.move(to: NSPoint(x: 4.75, y: 10))
            glyph.line(to: NSPoint(x: 8.1, y: 10))
            glyph.line(to: NSPoint(x: 9.9, y: 8.2))
            glyph.line(to: NSPoint(x: 13.25, y: 8.2))
            glyph.lineWidth = active ? 1.9 : 1.5
            glyph.lineCapStyle = .round
            glyph.lineJoinStyle = .round
            glyph.stroke()

            if active {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.5, y: 11, width: 2.1, height: 2.1)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct RelayMark: View {
    var size: CGFloat = 20
    var press: CGFloat = 0

    var body: some View {
        let cornerRadius = size * 0.24
        let faceOffset = press * (size / 80.46)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 28/255, green: 30/255, blue: 36/255),
                            Color(red: 16/255, green: 18/255, blue: 22/255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RelayShortcutGlyph()
                .stroke(
                    Color.white.opacity(0.94),
                    style: StrokeStyle(
                        lineWidth: max(1.6, size * 0.085),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size * 0.48, height: size * 0.14)
                .offset(y: faceOffset)
        }
        .frame(width: size, height: size)
        .overlay(
            shape
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}

struct RelayPrismOrb: View {
    enum Mode { case idle, processing, attention }

    var mode: Mode = .idle
    var size: CGFloat = 96
    var paused: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let still = paused || reduceMotion || scenePhase != .active || mode == .idle
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: still)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let period = mode == .processing ? 5.0 : 13.0
            let phase = still ? 0.8 : elapsed.truncatingRemainder(dividingBy: period) / period * 2 * .pi
            artwork(phase: phase)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func artwork(phase: Double) -> some View {
        let light = mode == .attention ? RelayColors.accentAmber : RelayColors.accentBlue
        let rim = mode == .attention ? RelayColors.accentCoral : RelayColors.accentAmethyst

        return Canvas { context, dimensions in
            let center = CGPoint(x: dimensions.width / 2, y: dimensions.height / 2)
            let unit = min(dimensions.width, dimensions.height)
            let glowBounds = CGRect(x: center.x - unit / 2, y: center.y - unit / 2, width: unit, height: unit)
            let core = unit * 0.255
            let coreBounds = CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)
            let tilt = -0.40 + 0.12 * sin(phase)

            context.fill(Path(ellipseIn: glowBounds), with: .radialGradient(
                Gradient(colors: [light.opacity(0.24), rim.opacity(0.10), .clear]),
                center: center, startRadius: core * 0.65, endRadius: unit / 2
            ))

            func orbitPoint(_ angle: Double, radius: CGFloat, depth: CGFloat, tilt: Double) -> CGPoint {
                let horizontal = radius * cos(angle)
                let vertical = depth * sin(angle)
                return CGPoint(
                    x: center.x + horizontal * cos(tilt) - vertical * sin(tilt),
                    y: center.y + horizontal * sin(tilt) + vertical * cos(tilt)
                )
            }

            func orbitArc(from start: Double, to end: Double, radius: CGFloat, depth: CGFloat, tilt: Double) -> Path {
                Path { path in
                    path.move(to: orbitPoint(start, radius: radius, depth: depth, tilt: tilt))
                    for index in 1...28 {
                        let angle = start + (end - start) * Double(index) / 28
                        path.addLine(to: orbitPoint(angle, radius: radius, depth: depth, tilt: tilt))
                    }
                }
            }

            let orbitRadius = unit * 0.45
            let orbitDepth = unit * 0.155
            let backArc = orbitArc(from: .pi, to: 2 * .pi, radius: orbitRadius, depth: orbitDepth, tilt: tilt)
            let outerArc = orbitArc(from: 0, to: 2 * .pi, radius: unit * 0.47, depth: unit * 0.20, tilt: tilt + 0.36)
            context.stroke(outerArc, with: .color(rim.opacity(0.24)), lineWidth: 0.65)
            context.stroke(backArc, with: .color(light.opacity(0.32)), lineWidth: 0.8)

            let satellite = orbitPoint(phase, radius: orbitRadius, depth: orbitDepth, tilt: tilt)
            let inFront = sin(phase) >= 0
            let satelliteRadius = unit * (inFront ? 0.022 : 0.013)
            let satelliteBounds = CGRect(x: satellite.x - satelliteRadius, y: satellite.y - satelliteRadius,
                                         width: satelliteRadius * 2, height: satelliteRadius * 2)
            let satelliteShape = Path(ellipseIn: satelliteBounds)
            if !inFront {
                context.fill(satelliteShape, with: .color(light.opacity(0.7)))
            }

            let highlight = CGPoint(x: center.x - core * 0.38, y: center.y - core * 0.47)
            context.fill(Path(ellipseIn: coreBounds), with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: light, location: 0.32),
                    .init(color: rim.opacity(0.82), location: 0.65),
                    .init(color: RelayColors.canvas, location: 1),
                ]),
                center: highlight, startRadius: 0, endRadius: core * 1.58
            ))
            context.stroke(Path(ellipseIn: coreBounds), with: .color(light.opacity(0.52)), lineWidth: 0.65)

            let frontArc = orbitArc(from: 0, to: .pi, radius: orbitRadius, depth: orbitDepth, tilt: tilt)
            let arcStart = orbitPoint(0, radius: orbitRadius, depth: orbitDepth, tilt: tilt)
            let arcEnd = orbitPoint(.pi, radius: orbitRadius, depth: orbitDepth, tilt: tilt)
            context.stroke(frontArc, with: .linearGradient(
                Gradient(colors: [light.opacity(0.62), .white.opacity(0.86), rim.opacity(0.85)]),
                startPoint: arcStart, endPoint: arcEnd
            ), style: StrokeStyle(lineWidth: max(0.9, unit * 0.013), lineCap: .round))

            if inFront {
                context.fill(satelliteShape, with: .color(.white.opacity(0.88)))
            }
        }
    }
}

// MARK: - Agent Role Badge View
struct RelayRoleBadge: View {
    let role: String

    init(role: String) {
        self.role = role
    }

    init(role: AgentRole) {
        self.role = role.displayName
    }

    private var roleColor: Color {
        RelayTheme.agentColor(for: role)
    }

    private var roleIcon: String {
        RelayTheme.agentIcon(for: role)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: roleIcon)
                .font(.system(size: 11, weight: .medium))
            Text(role)
                .font(.system(size: 11, weight: .medium, design: .default))
        }
        .foregroundStyle(roleColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(roleColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(roleColor.opacity(0.32), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role) role")
    }
}

// MARK: - Button Styles
struct RelayPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.isEnabled) private var enabled

    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? RelayColors.focusRing : .clear, lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .scaleEffect(enabled && !reducedMotion && configuration.isPressed ? 0.97 : 1)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Subtle translucent graphite pill for secondary Back navigation buttons (ChatGPT macOS / Antigravity style).

struct RelayBackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.relayCallout.weight(.medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(
                configuration.isPressed ? RelayColors.activeFill : RelayColors.subtleFill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )
            .foregroundStyle(isEnabled ? RelayColors.textPrimary : RelayColors.textMuted)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? RelayColors.focusRing : .clear, lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
    }
}

struct RelayPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? RelayColors.buttonInk : RelayColors.textDim)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minHeight: RelayControlHeight.bar)
            .background(
                enabled
                    ? RelayColors.buttonFace.opacity(configuration.isPressed ? 0.84 : (hovered ? 0.92 : 1.0))
                    : RelayColors.hoverFill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(enabled ? RelayColors.borderDefault : RelayColors.borderSubtle, lineWidth: 0.75)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? RelayColors.focusRing : .clear, lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}

struct RelaySecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? RelayColors.textPrimary : RelayColors.textDim.opacity(0.6))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minHeight: RelayControlHeight.bar)
            .background(
                enabled
                    ? (configuration.isPressed ? RelayColors.surfaceElevated : (hovered ? RelayColors.surfaceElevated : RelayColors.surface))
                    : RelayColors.subtleFill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        enabled ? (hovered ? RelayColors.borderDefault : RelayColors.borderSubtle) : RelayColors.borderSubtle.opacity(0.5),
                        lineWidth: 1
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? RelayColors.focusRing : .clear, lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}

/// Borderless ghost pill button for toolbars and secondary navigation
struct RelayGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? (configuration.isPressed || hovered ? RelayColors.textPrimary : RelayColors.textSecondary) : RelayColors.textDim)
            .padding(.horizontal, RelaySpace.sm)
            .padding(.vertical, 6)
            .frame(minHeight: RelayControlHeight.pill)
            .background(
                configuration.isPressed ? RelayColors.activeFill : (hovered ? RelayColors.hoverFill : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? RelayColors.focusRing : .clear, lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}

/// Shared toolbar pill label styling for compact window and composer action pills (Add context, Proofread, Summarize).
struct RelayToolbarPillLabel: View {
    let title: String
    let icon: String
    var iconOnly = false
    var hovered: Bool = false
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            if !iconOnly {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(disabled ? RelayColors.textDim : hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
        .padding(.horizontal, iconOnly ? 6 : 9)
        .frame(minWidth: RelayControlHeight.pill)
        .frame(height: RelayControlHeight.pill)
        .background(hovered && !disabled ? RelayColors.hoverFill : .clear,
                    in: Capsule(style: .continuous))
        .contentShape(Capsule())
    }
}

// MARK: - Full-Row Clickable DisclosureGroupStyle
struct RelayDisclosureGroupStyle: DisclosureGroupStyle {
    var accent: Color = RelayColors.textBright
    var verticalPadding: CGFloat = 8
    var horizontalPadding: CGFloat = 10
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderButton(
                configuration: configuration,
                accent: accent,
                verticalPadding: verticalPadding,
                horizontalPadding: horizontalPadding,
                cornerRadius: cornerRadius
            )
            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
    }

    private struct HeaderButton: View {
        let configuration: Configuration
        let accent: Color
        let verticalPadding: CGFloat
        let horizontalPadding: CGFloat
        let cornerRadius: CGFloat
        @State private var hovered = false
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    configuration.label
                        .font(RelayPageStyle.body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(RelayColors.textSecondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(hovered ? RelayColors.hoverFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(focused ? RelayColors.focusRing : .clear, lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RelayPressStyle())
            .onHover { hovered = $0 }
        }
    }
}

// MARK: - Clean Matte Graphite Icon Badge & Card Surface
struct RelayIconBadge: View {
    let icon: String
    var color: Color = RelayColors.textBright
    var size: CGFloat = 36
    var iconSize: CGFloat? = nil

    var body: some View {
        let corner = size * 0.28
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.fill(RelayColors.badgeFill)
            shape.strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            Image(systemName: icon)
                .font(.system(size: iconSize ?? (size * 0.44), weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct RelayIconButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 32
    var iconSize: CGFloat = 14
    var tint: Color = RelayColors.textBright
    var circular: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let buttonSize = max(24, size)
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(hovered ? RelayColors.textPrimary : tint)
                .frame(width: buttonSize, height: buttonSize)
                .background {
                    if circular {
                        Circle().fill(hovered ? RelayColors.hoverFill : Color.clear)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(hovered ? RelayColors.hoverFill : Color.clear)
                    }
                }
                .overlay {
                    if circular {
                        Circle().strokeBorder(Color.clear, lineWidth: 0.75)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.clear, lineWidth: 0.75)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

struct RelayLitCardModifier: ViewModifier {
    var accent: Color = RelayColors.textBright
    var isHovered: Bool = false
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(isHovered ? RelayColors.surface : RelayColors.cardBG, in: shape)
            .overlay(shape.strokeBorder(isHovered ? RelayColors.borderDefault : RelayColors.borderSubtle, lineWidth: 0.7))
    }
}

extension View {
    func relayLitCard(accent: Color = RelayColors.textBright, isHovered: Bool = false, cornerRadius: CGFloat = 16) -> some View {
        modifier(RelayLitCardModifier(accent: accent, isHovered: isHovered, cornerRadius: cornerRadius))
    }
}

nonisolated struct RelayResponseText {
    let body: String
    let evidence: String?

    init(_ text: String) {
        let separator = "\n\nChecked by Relay:\n"
        let noActions = "\n\nNo computer actions were executed in this response."
        if let marker = text.range(of: separator, options: .backwards) {
            body = String(text[..<marker.lowerBound])
            evidence = String(text[marker.upperBound...])
        } else {
            body = text.hasSuffix(noActions) ? String(text.dropLast(noActions.count)) : text
            evidence = nil
        }
    }
}

/// Transcript details use one quiet disclosure without a second label or card.
/// Settings retain their own larger controls.
struct RelayTranscriptDisclosureGroupStyle: DisclosureGroupStyle {
    var obsidianStyle: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                    configuration.label
                }
                .font(.relayCaption)
                .foregroundStyle(obsidianStyle ? Color.white.opacity(0.68) : RelayColors.textSecondary)
                .frame(minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content.padding(.leading, 18) }
        }
    }
}

struct RelayActionEvidence: View {
    let text: String
    var obsidianStyle: Bool = false

    var body: some View {
        DisclosureGroup {
            Text(text)
                .font(.relayCaption)
                .foregroundStyle(obsidianStyle ? Color.white.opacity(0.68) : RelayColors.textSecondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label("Action evidence", systemImage: "checkmark.shield")
                .font(.relayCaption.weight(.medium))
                .foregroundStyle(obsidianStyle ? Color.white.opacity(0.88) : RelayColors.textBright)
        }
        .disclosureGroupStyle(RelayTranscriptDisclosureGroupStyle(obsidianStyle: obsidianStyle))
    }
}

// MARK: - Antigravity Slate & Daylight Atmospheric Canvas
struct RelayAtmosphere: View {
    var focused: Bool = false
    var showsContours: Bool = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            RelayColors.canvas

            if !reduceTransparency {
                RadialGradient(
                    colors: [
                        RelayColors.accentBlue.opacity(focused ? 0.12 : 0.075),
                        RelayColors.accentAmethyst.opacity(focused ? 0.065 : 0.035),
                        .clear
                    ],
                    center: UnitPoint(x: 0.50, y: 0.04),
                    startRadius: 16,
                    endRadius: 580
                )

                if showsContours {
                    RadialGradient(
                        colors: [
                            RelayColors.accentAmethyst.opacity(focused ? 0.06 : 0.04),
                            .clear
                        ],
                        center: UnitPoint(x: 0.76, y: 0.22),
                        startRadius: 24,
                        endRadius: 460
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


// MARK: - Primary Action and Progress

struct RelayGlowHalo: View {
    let active: Bool
    var reversed: Bool = false
    var colors: [Color]? = nil
    var intensity: Double = 0.55
    var period: Double = 3.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: !active || reduceMotion)) { tick in
            let span = max(1, period)
            let elapsed = tick.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: span)
            let phase = reduceMotion ? 0.0 : elapsed / span * 2 * .pi
            let drift = 0.18 * sin(reversed ? -phase : phase)
            let light = colors ?? [
                Color(red: 0x38 / 255.0, green: 0xBD / 255.0, blue: 0xF8 / 255.0),
                RelayColors.accentBlue,
                Color(red: 0x2D / 255.0, green: 0xD4 / 255.0, blue: 0xBF / 255.0)
            ]
            Capsule()
                .strokeBorder(LinearGradient(
                    colors: light,
                    startPoint: UnitPoint(x: 0.1 + drift, y: 0.15),
                    endPoint: UnitPoint(x: 0.9 + drift, y: 0.85)
                ), lineWidth: 4)
                .blur(radius: 6)
                .padding(-3)
                .opacity(active ? min(max(intensity, 0), 1) : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct RelayGlowButton: View {
    let title: String
    var icon: String = ""
    var enabled: Bool = true
    var glowOpacity: Double = 0.38
    var minimumLabelWidth: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                }
            }
            .font(.relayCallout.weight(.semibold))
            .frame(minWidth: minimumLabelWidth)
            .padding(.horizontal, 18)
            .frame(minHeight: 38)
            .foregroundStyle(enabled ? RelayColors.buttonInk : RelayColors.textMuted)
            .background(
                Capsule()
                    .fill(enabled ? RelayColors.buttonFace.opacity(hovering ? 0.90 : 1.0) : RelayColors.surfaceElevated)
            )
            .overlay(
                Capsule()
                    .strokeBorder(enabled ? RelayColors.borderDefault : RelayColors.borderSubtle, lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(enabled ? 0.14 : 0.0), radius: 5, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(RelayPressStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

struct RelaySendButton: View {
    let canSend: Bool
    var isRunning: Bool = false
    var size: CGFloat = 30
    var help: String = "Send message"
    var showsHalo: Bool = false
    let action: () -> Void

    @State private var hovering = false

    init(
        canSend: Bool,
        isRunning: Bool = false,
        size: CGFloat = 30,
        help: String = "Send message",
        showsHalo: Bool = false,
        action: @escaping () -> Void
    ) {
        self.canSend = canSend
        self.isRunning = isRunning
        self.size = size
        self.help = help
        self.showsHalo = showsHalo
        self.action = action
    }

    init(
        enabled: Bool,
        isRunning: Bool = false,
        help: String = "Send message",
        diameter: CGFloat = 30,
        showsHalo: Bool = false,
        action: @escaping () -> Void
    ) {
        self.canSend = enabled
        self.isRunning = isRunning
        self.size = diameter
        self.help = help
        self.showsHalo = showsHalo
        self.action = action
    }

    private var isActive: Bool {
        canSend || isRunning
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isActive && showsHalo {
                    RelayGlowHalo(active: true, intensity: hovering ? 0.56 : 0.38, period: 4.5)
                        .frame(width: size, height: size)
                }
                Image(systemName: isRunning && !canSend ? "stop.fill" : "arrow.up")
                    .font(.system(size: size >= 30 ? 13 : (size > 18 ? 11 : 9.5), weight: .bold))
                    .foregroundStyle(isActive ? RelayColors.buttonInk : RelayColors.textDim)
                    .frame(width: size, height: size)
                    .background(
                        Circle()
                            .fill(
                                isActive
                                    ? RelayColors.buttonFace.opacity(hovering ? 0.92 : 1.0)
                                    : RelayColors.subtleFill
                            )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isActive ? RelayColors.borderDefault : Color.clear,
                                lineWidth: 0.75
                            )
                    )
            }
            .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
        .onHover { hovering = $0 }
        .onChange(of: isActive) { _, on in if !on { hovering = false } }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.14), value: isActive)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct RelayGlowProgressBar: View {
    var value: Double

    var body: some View {
        let fraction = value.isFinite ? min(max(value, 0), 1) : 0
        GeometryReader { geometry in
            let fillWidth = geometry.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(RelayColors.surfaceElevated)
                if fillWidth > 0 {
                    Capsule()
                        .fill(LinearGradient(colors: [RelayColors.accentAmethyst, RelayColors.accentBlue, RelayColors.accentCyan],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: fillWidth)
                        .shadow(color: RelayColors.accentBlue.opacity(0.36), radius: 4, y: 1)
                }
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Download progress")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

// MARK: - Adaptive Chips

struct RelayChipFlow: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .center

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ item: Item, spacing: CGFloat) {
            width += (items.isEmpty ? 0 : spacing) + item.size.width
            height = max(height, item.size.height)
            items.append(item)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let gap = max(0, spacing)
        let rows = rows(fitting: proposal.width, subviews: subviews, spacing: gap)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let gap = max(0, spacing)
        var rowY = bounds.minY
        for row in rows(fitting: bounds.width, subviews: subviews, spacing: gap) {
            let slack = max(0, bounds.width - row.width)
            let inset: CGFloat = alignment == .leading ? 0 : alignment == .trailing ? slack : slack / 2
            var itemX = bounds.minX + inset
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: itemX, y: rowY + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                itemX += item.size.width + gap
            }
            rowY += row.height + gap
        }
    }

    private func rows(fitting width: CGFloat?, subviews: Subviews, spacing: CGFloat) -> [Row] {
        let limit = width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? .infinity
        var completed: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let measured = ideal.width > limit
                ? subviews[index].sizeThatFits(ProposedViewSize(width: limit, height: nil))
                : ideal
            let item = Item(index: index, size: CGSize(width: min(measured.width, limit), height: measured.height))
            if !current.items.isEmpty, current.width + spacing + item.size.width > limit + 0.01 {
                completed.append(current)
                current = Row()
            }
            current.append(item, spacing: spacing)
        }
        if !current.items.isEmpty { completed.append(current) }
        return completed
    }
}

struct RelaySourceChip: View {
    let label: String
    var detail: String? = nil
    var systemImage: String? = nil
    let on: Bool
    var isAction: Bool = false
    var trailingSymbol: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let accent = on ? RelayColors.accentEmerald : RelayColors.accentBlue
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(RelayColors.textPrimary)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(RelayColors.textMuted)
                    }
                }
                .lineLimit(1)
                if let symbol = trailingSymbol ?? (on && !isAction ? "xmark" : nil) {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(RelayColors.textMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 32)
            .background(hovering ? RelayColors.surfaceElevated : RelayColors.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(accent.opacity(hovering ? 0.48 : 0.20), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(detail ?? "")
    }
}

struct RelayEngineTab: View {
    let label: String
    var badge: String? = nil
    let selected: Bool
    var active: Bool = false
    var icon = "cpu"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: active ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? RelayColors.accentEmerald : RelayColors.textMuted)
                Text(label)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(RelayColors.textPrimary)
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(selected || hovering ? RelayColors.surfaceElevated : RelayColors.surface,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? RelayColors.borderStrong : RelayColors.borderSubtle, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Unified Semantic Palette Tokens (`RelayPalette`)

enum RelayPalette {
    static let canvas = RelayColors.canvas
    static let card = RelayColors.cardBG
    static let elevated = RelayColors.surfaceElevated
    static let stroke = RelayColors.borderSubtle
    static let ink = RelayColors.textPrimary
    static let inkSecondary = RelayColors.textBright
    static let muted = RelayColors.textSecondary
    static let subtle = RelayColors.textMuted
}

// MARK: - Shared Relay page language

enum RelayPageStyle {
    static let title = Font.system(size: 24, weight: .medium)
    static let dialogTitle = Font.system(size: 17, weight: .medium)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let symbol = Font.system(size: 14, weight: .regular)
}

/// A form section uses alignment and space rather than a second enclosing card.
struct RelaySectionHeading: View {
    let title: String
    var detail: String? = nil
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(RelayPageStyle.sectionTitle)
                    .foregroundStyle(RelayColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RelayFormSection: ViewModifier {
    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Divider().overlay(RelayColors.borderSubtle)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RelayPagePanel: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(contrast == .increased ? RelayColors.borderStrong : RelayColors.borderSubtle,
                                  lineWidth: contrast == .increased ? 1 : 0.7)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func relayFormSection() -> some View {
        modifier(RelayFormSection())
    }

    func relayPageBackground() -> some View {
        background { RelayWorkspaceBackdrop() }
    }

    func relayPagePanel(cornerRadius: CGFloat = 12) -> some View {
        modifier(RelayPagePanel(cornerRadius: cornerRadius))
    }
}
