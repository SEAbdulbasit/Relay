import SwiftUI

// MARK: - Color Palette Tokens (Sentient OS & ChatGPT OLED Obsidian Palette)
enum RelayColors {
    static let pitch = Color(red: 5/255, green: 5/255, blue: 8/255)               // #050508 Pure OLED Obsidian
    static let canvas = Color(red: 6/255, green: 7/255, blue: 10/255)             // #06070A Night Sky Base
    static let background = Color(red: 8/255, green: 9/255, blue: 13/255)         // #08090D Deep Obsidian
    static let cardBG = Color(red: 12/255, green: 12/255, blue: 16/255)           // #0C0C10 Sentient Card Surface
    static let surface = Color(red: 16/255, green: 17/255, blue: 22/255)          // #101116 Elevated Panel
    static let surfaceElevated = Color(red: 23/255, green: 25/255, blue: 32/255)  // #171920 Interactive Surface
    static let glassBackdrop = Color(red: 16/255, green: 18/255, blue: 24/255).opacity(0.78)

    static let borderSubtle = Color.white.opacity(0.08)
    static let borderDefault = Color.white.opacity(0.14)
    static let borderFocus = Color(red: 253/255, green: 226/255, blue: 163/255).opacity(0.45)

    static let textPrimary = Color.white   // #EEEDF3 Crisp Editorial Ink
    static let textSecondary = Color(red: 197/255, green: 200/255, blue: 209/255) // #C5C8D1
    static let textMuted = Color(red: 155/255, green: 154/255, blue: 160/255)     // #9B9AA0 Sentient Body Ink
    static let textDim = Color(red: 160/255, green: 166/255, blue: 180/255)       // #6E6D75 Whisper Ink

    // Semantic Accents (Matching Sentient OS Ink Tokens)
    static let accentEmerald = Color(red: 74/255, green: 222/255, blue: 128/255)  // #4ADE80 Sentient Green
    static let accentAmethyst = Color(red: 187/255, green: 101/255, blue: 255/255)// #BB65FF Planner Violet
    static let accentPeriwinkle = Color(red: 142/255, green: 166/255, blue: 255/255) // #8EA6FF Starlight Accent
    static let accentBlue = Color(red: 111/255, green: 182/255, blue: 255/255)    // #6FB6FF Navigator Sky Blue
    static let accentCoral = Color(red: 255/255, green: 92/255, blue: 92/255)     // #FF5C5C Status Red/Coral
    static let accentAmber = Color(red: 255/255, green: 195/255, blue: 113/255)   // #FFC371 Sentient Amber
    static let accentGold = Color(red: 253/255, green: 226/255, blue: 163/255)    // #FDE2A3 Prism Warm Gold
    static let accentCyan = Color(red: 111/255, green: 182/255, blue: 255/255)    // #6FB6FF Starlight Cyan / Sky Blue
    static let knowledgeLink = Color(red: 173/255, green: 186/255, blue: 255/255) // #ADB4FF Sentient Wikilink Violet-Blue

    // Button Tokens
    static let buttonFace = Color.white                                           // #FFFFFF Crisp White Capsule
    static let buttonInk = Color(red: 10/255, green: 11/255, blue: 14/255)        // #0A0B0E
}

// MARK: - Sentient OS Gradients
enum RelayGradients {
    static let glowStops: [Color] = RelayTheme.prismStops

    static let ambientTopGlow = RadialGradient(
        colors: [
            RelayColors.accentAmethyst.opacity(0.08),
            RelayColors.accentGold.opacity(0.04),
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
    static let canvas = RelayColors.pitch
    static let background = RelayColors.pitch
    static let surface = RelayColors.surface
    static let surfaceElevated = RelayColors.surfaceElevated
    static let cardBG = RelayColors.cardBG
    static let accent = RelayColors.accentEmerald
    static let ink = RelayColors.textPrimary
    static let muted = RelayColors.textMuted
    static let line = RelayColors.borderSubtle
    static let sidebar = Color(red: 10/255, green: 11/255, blue: 15/255) // Moonlit slate
    static let contentWidth: CGFloat = 780
    static let inset: CGFloat = 24
    static let radius: CGFloat = 12

    // Canonical 8-stop Sentient/Relay Prism spectrum
    static let prismStops: [Color] = [
        Color(red: 253/255, green: 226/255, blue: 163/255), // #FDE2A3 Warm Gold
        Color(red: 255/255, green: 142/255, blue: 60/255),  // #FF8E3C Orange
        Color(red: 255/255, green: 70/255, blue: 70/255),   // #FF4646 Coral Red
        Color(red: 232/255, green: 56/255, blue: 143/255),  // #E8388F Magenta Pink
        Color(red: 155/255, green: 72/255, blue: 212/255),  // #9B48D4 Amethyst
        Color(red: 108/255, green: 92/255, blue: 229/255),  // #6C5CE5 Indigo
        Color(red: 74/255, green: 144/255, blue: 226/255),  // #4A90E2 Sky Blue
        Color(red: 253/255, green: 226/255, blue: 163/255)  // #FDE2A3 Wrap
    ]

    static let prismGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 253/255, green: 226/255, blue: 163/255), location: 0.01),
            .init(color: Color(red: 255/255, green: 142/255, blue: 60/255), location: 0.15),
            .init(color: Color(red: 255/255, green: 70/255, blue: 70/255), location: 0.28),
            .init(color: Color(red: 232/255, green: 56/255, blue: 143/255), location: 0.42),
            .init(color: Color(red: 155/255, green: 72/255, blue: 212/255), location: 0.57),
            .init(color: Color(red: 108/255, green: 92/255, blue: 229/255), location: 0.71),
            .init(color: Color(red: 74/255, green: 144/255, blue: 226/255), location: 0.84),
            .init(color: Color(red: 253/255, green: 226/255, blue: 163/255), location: 0.99)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let prismAngularGradient = AngularGradient(
        colors: prismStops,
        center: .center
    )

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

// MARK: - Editorial Serif + Native System Typography (Sentient OS Typography System)
extension Font {
    static let relayDisplayHero = Font.system(size: 34, weight: .regular, design: .serif)
    static let relayDisplayTitle = Font.system(size: 22, weight: .regular, design: .serif)
    static let relayHeadline = Font.system(size: 18, weight: .semibold, design: .default)
    static let relayBody = Font.system(size: 14.5, weight: .regular, design: .default)
    static let relayCaption = Font.system(size: 12, weight: .regular, design: .default)
    static let relayMono = Font.system(size: 12, weight: .medium, design: .monospaced)

    static let relayEditorialHero = Font.system(size: 32, weight: .regular, design: .serif)
    static let relayEditorialTitle = Font.system(size: 20, weight: .regular, design: .serif)
    static let relayEditorialSubtitle = Font.system(size: 16, weight: .regular, design: .default)
}

/// Monospace ALL-CAPS with wide tracking — Sentient OS's machine whisper voice.
struct RelayMonoCaps: View {
    let text: String
    var size: CGFloat = 13
    var tracking: CGFloat = 1.6
    var color: Color = RelayColors.textDim

    init(_ text: String, size: CGFloat = 13, tracking: CGFloat = 1.6, color: Color = RelayColors.textDim) {
        self.text = text
        self.size = size
        self.tracking = tracking
        self.color = color
    }

    init(text: String, color: Color = RelayColors.textDim, size: CGFloat = 13, tracking: CGFloat = 1.6) {
        self.text = text
        self.size = size
        self.tracking = tracking
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

// MARK: - Frosted Glass & Editorial Card Modifiers
struct RelayGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var strokeColor: Color = RelayColors.borderSubtle
    var fillOpacity: Double = 0.88

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(RelayColors.cardBG.opacity(fillOpacity), in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [strokeColor.opacity(1.3), strokeColor.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
    }
}

extension View {
    func relayGlassCard(cornerRadius: CGFloat = 16, strokeColor: Color = RelayColors.borderSubtle) -> some View {
        modifier(RelayGlassCardModifier(cornerRadius: cornerRadius, strokeColor: strokeColor))
    }
}

// MARK: - Brand Marks & Living Sentient Orb
/// A quiet relay glyph shared by navigation and conversation authorship.
struct RelayMark: View {
    var size: CGFloat = 24
    var illuminated: Bool = true

    var body: some View {
        Image(systemName: "arrow.triangle.swap")
            .font(.system(size: size * 0.56, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.94))
            .frame(width: size, height: size)
            .background(Color.white.opacity(illuminated ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

/// Sentient OS inspired dimensional Orb with glowing white heart, nebula sphere, and tilted orbital ring.
struct RelayPrismOrb: View {
    var size: CGFloat = 76

    var body: some View {
        ZStack {
            // Ambient multi-stop rainbow aura
            Circle()
                .fill(RelayTheme.prismAngularGradient)
                .frame(width: size * 1.35, height: size * 1.35)
                .blur(radius: size * 0.32)
                .opacity(0.38)

            // Tilted outer orbital ring (back arc)
            Ellipse()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            RelayColors.accentGold.opacity(0.55),
                            RelayColors.accentAmethyst.opacity(0.25),
                            RelayColors.accentBlue.opacity(0.65)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1.4
                )
                .frame(width: size * 1.48, height: size * 0.52)
                .rotationEffect(.degrees(-22))

            // Dark glassy planet body
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.22, green: 0.20, blue: 0.34),
                            Color(red: 0.08, green: 0.07, blue: 0.14),
                            Color(red: 0.015, green: 0.015, blue: 0.03)
                        ],
                        center: UnitPoint(x: 0.34, y: 0.28),
                        startRadius: 1,
                        endRadius: size * 0.56
                    )
                )
                .frame(width: size, height: size)

            // Subtle internal prism nebula cloud
            Circle()
                .fill(RelayTheme.prismAngularGradient)
                .frame(width: size * 0.78, height: size * 0.78)
                .blur(radius: size * 0.16)
                .opacity(0.28)
                .clipShape(Circle())

            // Glowing white heart halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, .white.opacity(0.35), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.26
                    )
                )
                .frame(width: size * 0.52, height: size * 0.52)

            // Crisp white heart dot
            Circle()
                .fill(Color.white)
                .frame(width: size * 0.24, height: size * 0.24)
                .shadow(color: .white.opacity(0.8), radius: 6)

            // Specular rim light on the sphere
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.75),
                            RelayColors.accentAmethyst.opacity(0.45),
                            .white.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.25
                )
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.55, height: size * 1.25)
        .accessibilityHidden(true)
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
                .font(.system(size: 10.5, weight: .semibold))
            Text(role.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
        }
        .foregroundStyle(roleColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(roleColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(roleColor.opacity(0.32), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role) role")
    }
}

// MARK: - Button Styles (Sentient OS GlowButton & QuietPillButton)
struct RelayPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .scaleEffect(enabled && !reducedMotion && configuration.isPressed ? 0.97 : 1)
    }
}

/// High-contrast white CTA button with full-bounds hit testing and hover feedback.
struct RelayPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? RelayColors.buttonInk : RelayColors.textDim)
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 34)
            .background(enabled ? Color.white.opacity(configuration.isPressed ? 0.82 : hovered ? 0.92 : 1) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(enabled ? 0.22 : 0.05), lineWidth: 0.75))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

struct RelaySecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? RelayTheme.ink : RelayColors.textDim.opacity(0.6))
            .padding(.horizontal, 12).padding(.vertical, 7).frame(minHeight: 32)
            .background(Color.white.opacity(enabled ? (configuration.isPressed ? 0.12 : hovered ? 0.08 : 0.045) : 0.02), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(enabled ? (hovered ? 0.18 : 0.10) : 0.04), lineWidth: 0.75))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// Borderless ghost pill button for toolbars and secondary navigation
struct RelayGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(enabled ? (configuration.isPressed || hovered ? RelayTheme.ink : RelayTheme.muted) : RelayColors.textDim)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(
                configuration.isPressed ? Color.white.opacity(0.08) : (hovered ? Color.white.opacity(0.045) : Color.clear),
                in: Capsule(style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

// MARK: - Full-Row Clickable DisclosureGroupStyle (Fixes tiny chevron-only click area on macOS)

/// Replaces macOS SwiftUI's chevron-only `DisclosureGroup` header with a full-width clickable button row,
/// hover illumination, a 24x24 rotating chevron pill, and a subtle left accent rule for expanded content.
struct RelayDisclosureGroupStyle: DisclosureGroupStyle {
    var accent: Color = RelayColors.accentAmethyst
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
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.55), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 2)
                        .padding(.leading, 10)
                        .padding(.vertical, 4)

                    configuration.content
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

        var body: some View {
            Button {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 5) {
                        Text(configuration.isExpanded ? "Hide" : "Expand")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(hovered ? RelayColors.textPrimary : RelayColors.textMuted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(hovered || configuration.isExpanded ? accent : RelayColors.textSecondary)
                            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                            .frame(width: 22, height: 22)
                            .background(
                                (configuration.isExpanded ? accent : Color.white)
                                    .opacity(configuration.isExpanded ? 0.16 : (hovered ? 0.09 : 0.04)),
                                in: Circle()
                            )
                    }
                }
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: 38, maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(hovered ? 0.055 : (configuration.isExpanded ? 0.035 : 0.02)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            hovered || configuration.isExpanded
                                ? accent.opacity(0.28)
                                : Color.white.opacity(0.06),
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(RelayPressStyle())
            .onHover { hovered = $0 }
        }
    }
}

// MARK: - Semantic Jewel Icon Badge & Directional Lit Card Surface

/// Top-lit jewel squircle icon badge that gives dark surfaces semantic color warmth instead of flat grayscale.
struct RelayIconBadge: View {
    let icon: String
    var color: Color = RelayColors.accentAmethyst
    var size: CGFloat = 36
    var iconSize: CGFloat? = nil

    var body: some View {
        let corner = size * 0.28
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.fill(
                RadialGradient(
                    colors: [color.opacity(0.24), color.opacity(0.07)],
                    center: .topLeading,
                    startRadius: 2,
                    endRadius: size * 1.1
                )
            )
            shape.strokeBorder(
                LinearGradient(
                    colors: [color.opacity(0.55), color.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            Image(systemName: icon)
                .font(.system(size: iconSize ?? (size * 0.44), weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Guaranteed 32x32pt minimum hit-target icon button with hover illumination.
struct RelayIconButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 32
    var iconSize: CGFloat = 13
    var tint: Color = RelayColors.textSecondary
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(hovered ? Color.white : tint)
                .frame(width: max(32, size), height: max(32, size))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(hovered ? 0.09 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovered ? 0.16 : 0.07), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

/// Directional jewel-lit surface card modifier (Ported from Sentient OS BriefingCard & SettingsComponents).
struct RelayLitCardModifier: ViewModifier {
    var accent: Color = RelayColors.accentAmethyst
    var isHovered: Bool = false
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    shape.fill(RelayColors.surface)
                    shape.fill(
                        RadialGradient(
                            colors: [accent.opacity(isHovered ? 0.14 : 0.08), .clear],
                            center: .topLeading,
                            startRadius: 6,
                            endRadius: 340
                        )
                    )
                }
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            accent.opacity(isHovered ? 0.52 : 0.32),
                            Color.white.opacity(isHovered ? 0.12 : 0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
    }
}

extension View {
    func relayLitCard(accent: Color = RelayColors.accentAmethyst, isHovered: Bool = false, cornerRadius: CGFloat = 16) -> some View {
        modifier(RelayLitCardModifier(accent: accent, isHovered: isHovered, cornerRadius: cornerRadius))
    }
}

// MARK: - Sentient OS Crown Light Petals & Atmospheric Canvas (`SidekickAtmosphere`)

/// Renders Sentient OS's warm nocturnal atmosphere: pure obsidian canvas + top-crown spectrum light petals
/// (sky blue, coral, warm gold, amber) + focus-responsive bottom composer halo.
struct RelayAtmosphere: View {
    var focused: Bool = false

    var body: some View {
        ZStack {
            RelayColors.pitch.ignoresSafeArea()

            // Top Crown Light Petals
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    Ellipse()
                        .fill(RelayColors.accentBlue.opacity(0.13))
                        .frame(width: 280, height: 190)
                        .blur(radius: 64)
                        .position(x: w * 0.34, y: 40)

                    Ellipse()
                        .fill(RelayColors.accentCoral.opacity(0.08))
                        .frame(width: 230, height: 165)
                        .blur(radius: 62)
                        .position(x: w * 0.46, y: 28)

                    Ellipse()
                        .fill(RelayColors.accentGold.opacity(0.11))
                        .frame(width: 260, height: 175)
                        .blur(radius: 62)
                        .position(x: w * 0.56, y: 34)

                    Ellipse()
                        .fill(RelayColors.accentAmethyst.opacity(0.12))
                        .frame(width: 260, height: 180)
                        .blur(radius: 66)
                        .position(x: w * 0.66, y: 44)
                }
                .frame(maxWidth: .infinity, maxHeight: 320, alignment: .top)
                .mask(
                    LinearGradient(
                        colors: [.white, .white.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Bottom Composer Echo Halo
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [
                                RelayColors.accentGold.opacity(focused ? 0.16 : 0.07),
                                RelayColors.accentAmethyst.opacity(focused ? 0.14 : 0.06),
                                RelayColors.accentBlue.opacity(focused ? 0.12 : 0.04)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 520, height: 70)
                    .blur(radius: 42)
                    .position(x: w * 0.5, y: geo.size.height - 36)
                    .animation(.easeOut(duration: 0.3), value: focused)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

/// Sentient OS `GlowButton` / `OnboardingNextButton`: crisp white capsule CTA with a conic spectrum halo glow.
struct RelayGlowButton: View {
    let title: String
    var icon: String = "arrow.right"
    var enabled: Bool = true
    var glowOpacity: Double = 0.34
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .offset(x: hovered && enabled ? 2 : 0)
                }
            }
            .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.35))
            .padding(.horizontal, 34)
            .frame(minWidth: 210, minHeight: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(enabled ? Color.white : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        enabled ? AnyShapeStyle(RelayTheme.prismAngularGradient) : AnyShapeStyle(Color.white.opacity(0.08)),
                        lineWidth: enabled ? 1.2 : 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(RelayPressStyle())
        .background {
            if enabled && glowOpacity > 0 {
                Capsule(style: .continuous)
                    .fill(RelayTheme.prismAngularGradient)
                    .blur(radius: hovered ? 18 : 14)
                    .opacity(hovered ? min(0.65, glowOpacity * 1.45) : glowOpacity)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.18), value: hovered)
    }
}
