import SwiftUI
import AppKit

extension View {
    /// Plain macOS text fields dim native placeholders even when a prompt supplies
    /// a color. Draw the empty-state prompt once at the shared readable contrast.
    func relayTextFieldPrompt(_ prompt: String, when isEmpty: Bool, font: Font = .relayBody) -> some View {
        overlay(alignment: .topLeading) {
            if isEmpty {
                Text(prompt)
                    .font(font)
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Color Palette Tokens (ChatGPT macOS & Antigravity Matte Graphite Palette)
enum RelayColors {
    static let pitch = Color(red: 18/255, green: 19/255, blue: 23/255)              // #121317 Window canvas
    static let canvas = Color(red: 15/255, green: 16/255, blue: 20/255)             // #0F1014 Sidebar
    static let background = pitch         // Window background
    static let cardBG = Color(red: 29/255, green: 29/255, blue: 32/255)             // #1D1D20 Elevated Matte Card Surface
    static let surface = Color(red: 34/255, green: 34/255, blue: 38/255)            // #222226 Composer & Control Surface
    static let surfaceElevated = Color(red: 43/255, green: 43/255, blue: 48/255)    // #2B2B30 User Message Pill & Hover Surface
    static let glassBackdrop = Color(red: 29/255, green: 29/255, blue: 32/255).opacity(0.88)

    static let borderSubtle = Color.white.opacity(0.07)
    static let borderDefault = Color.white.opacity(0.16)
    static let borderFocus = Color(red: 133/255, green: 181/255, blue: 238/255)

    static let textPrimary = Color(red: 244/255, green: 244/255, blue: 246/255)     // #F4F4F6 Crisp Warm White Ink
    static let textBright = Color(red: 228/255, green: 228/255, blue: 231/255)      // #E4E4E7 Zinc 200
    static let textStatus = Color(red: 212/255, green: 212/255, blue: 216/255)      // #D4D4D8 Zinc 300
    static let textSecondary = Color(red: 161/255, green: 161/255, blue: 170/255)   // #A1A1AA Zinc 400
    static let textMuted = Color(red: 145/255, green: 147/255, blue: 158/255)       // Secondary control labels
    static let textDim = Color(red: 82/255, green: 82/255, blue: 91/255)            // #52525B Zinc 600
    static let textFaint = Color.white.opacity(0.28)

    // Restrained Semantic Accents (Subtle status & role indicators only)
    static let accentEmerald = Color(red: 52/255, green: 211/255, blue: 153/255)    // #34D399 Subtle Mint/Emerald Status
    static let accentAmethyst = Color(red: 212/255, green: 212/255, blue: 216/255)  // #D4D4D8 Monochrome Silver Accent
    static let accentPeriwinkle = Color(red: 161/255, green: 161/255, blue: 170/255)// #A1A1AA Muted Slate Accent
    static let accentBlue = Color(red: 147/255, green: 197/255, blue: 253/255)      // #93C5FD Soft Sky Status
    static let accentCoral = Color(red: 248/255, green: 113/255, blue: 113/255)     // #F87171 Soft Red Alert
    static let accentAmber = Color(red: 251/255, green: 191/255, blue: 36/255)      // #FBBF24 Warm Amber Warning
    static let accentGold = Color(red: 228/255, green: 228/255, blue: 231/255)      // #E4E4E7 Warm Silver Highlight
    static let accentCyan = Color(red: 165/255, green: 243/255, blue: 252/255)      // #A5F3FC Soft Ice Cyan
    static let knowledgeLink = Color(red: 228/255, green: 228/255, blue: 231/255)   // #E4E4E7 Clean Understated Link

    // Button Tokens
    static let buttonFace = Color.white                                             // #FFFFFF High-Contrast White Pill
    static let buttonInk = Color(red: 17/255, green: 17/255, blue: 19/255)          // #111113 Deep Graphite Ink
}

// MARK: - Subtle Matte Gradients
enum RelayGradients {
    static let glowStops: [Color] = RelayTheme.prismStops

    static let ambientTopGlow = RadialGradient(
        colors: [
            Color.white.opacity(0.025),
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
    static let accent = RelayColors.textPrimary
    static let ink = RelayColors.textPrimary
    static let muted = RelayColors.textMuted
    static let line = RelayColors.borderSubtle
    static let sidebar = RelayColors.canvas
    static let contentWidth: CGFloat = 760
    static let inset: CGFloat = 24
    static let radius: CGFloat = 14


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

// MARK: - Display Typography

extension View {
    func display(_ size: CGFloat, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight))
    }
}

extension Font {
    static let relayDisplayHero = Font.system(size: 30, weight: .medium, design: .default)
    static let relayDisplayTitle = Font.system(size: 22, weight: .medium, design: .default)
    static let relayHeadline = Font.system(size: 16, weight: .medium, design: .default)
    static let relayBody = Font.system(size: 14, weight: .regular, design: .default)
    static let relayCaption = Font.system(size: 12, weight: .regular, design: .default)
    static let relayMono = Font.system(size: 12, weight: .medium, design: .default).monospacedDigit()

    static let relayEditorialHero = Font.system(size: 28, weight: .medium, design: .default)
    static let relayEditorialTitle = Font.system(size: 20, weight: .medium, design: .default)
    static let relayEditorialSubtitle = Font.system(size: 14.5, weight: .regular, design: .default)
}


struct OnboardingWhisper: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(RelayColors.textSecondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct RelayMonoCaps: View {
    let text: String
    var size: CGFloat = 10.5
    var tracking: CGFloat = 1.4
    var color: Color = RelayColors.textDim

    init(_ text: String, size: CGFloat = 10.5, tracking: CGFloat = 1.4, color: Color = RelayColors.textDim) {
        self.text = text
        self.size = size
        self.tracking = tracking
        self.color = color
    }

    init(text: String, color: Color = RelayColors.textDim, size: CGFloat = 10.5, tracking: CGFloat = 1.4) {
        self.text = text
        self.size = size
        self.tracking = tracking
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: max(9.5, size), weight: .medium, design: .monospaced))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}


// MARK: - Status Indicator

struct RelayHealthDot: View {
    static let warnAmber = Color(red: 0.98, green: 0.69, blue: 0.36)
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16)).frame(width: 14, height: 14)
            Circle().strokeBorder(color.opacity(0.30), lineWidth: 0.75).frame(width: 11, height: 11)
            Circle().fill(color).frame(width: 5, height: 5)
        }
        .accessibilityHidden(true)
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
            .overlay(
                shape.strokeBorder(strokeColor, lineWidth: 1)
            )
    }
}

extension View {
    func relayGlassCard(cornerRadius: CGFloat = 14, strokeColor: Color = RelayColors.borderSubtle) -> some View {
        modifier(RelayGlassCardModifier(cornerRadius: cornerRadius, strokeColor: strokeColor))
    }
}


// MARK: - Relay Brand

struct RelaySignalGlyph: Shape {
    // The same two paths form the app icon in Resources/Relay-icon.svg.
    nonisolated func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 100, y: rect.minY + rect.height * y / 100)
        }

        var path = Path()
        path.move(to: point(17, 78))
        path.addLine(to: point(35, 36))
        path.addCurve(to: point(49, 24), control1: point(39, 27), control2: point(42, 24))
        path.addLine(to: point(64, 24))
        path.move(to: point(83, 22))
        path.addLine(to: point(65, 64))
        path.addCurve(to: point(51, 76), control1: point(61, 73), control2: point(58, 76))
        path.addLine(to: point(36, 76))
        return path
    }
}

struct RelayMark: View {
    var size: CGFloat = 20
    var illuminated: Bool = true

    var body: some View {
        RelaySignalGlyph()
            .stroke(LinearGradient(
                colors: illuminated ? [RelayColors.textPrimary, RelayColors.accentCyan] : [RelayColors.textSecondary, RelayColors.textSecondary],
                startPoint: .topTrailing, endPoint: .bottomLeading
            ), style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .shadow(color: illuminated ? RelayColors.accentBlue.opacity(0.27) : .clear, radius: 4)
            .accessibilityHidden(true)
    }
}

struct RelayPrismOrb: View {
    enum Mode { case idle, processing, attention }

    var mode: Mode = .idle
    var size: CGFloat = 96
    var paused: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = paused || reduceMotion
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .scaleEffect(enabled && !reducedMotion && configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// Subtle translucent graphite pill for secondary Back navigation buttons (ChatGPT macOS / Antigravity style).

struct RelayBackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(configuration.isPressed ? .white.opacity(0.13) : .white.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(isEnabled ? RelayColors.textPrimary : RelayColors.textMuted)
            .contentShape(Rectangle())
    }
}

struct RelayPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(enabled ? RelayColors.buttonInk : RelayColors.textDim)
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 34)
            .background(enabled ? Color.white.opacity(configuration.isPressed ? 0.82 : hovered ? 0.92 : 1) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(enabled ? 0.22 : 0.05), lineWidth: 0.75))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

struct RelaySecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(enabled ? RelayColors.textBright : RelayColors.textDim.opacity(0.6))
            .padding(.horizontal, 13).padding(.vertical, 7).frame(minHeight: 34)
            .background(
                enabled
                    ? (configuration.isPressed ? Color(white: 0.14) : hovered ? Color(white: 0.12) : Color(white: 0.075))
                    : Color.white.opacity(0.02),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(enabled ? 0.16 : 0.04), lineWidth: 1)
            )
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
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(enabled ? (configuration.isPressed || hovered ? RelayTheme.ink : RelayColors.textBright) : RelayColors.textDim)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 34)
            .background(
                configuration.isPressed ? Color.white.opacity(0.08) : (hovered ? Color.white.opacity(0.05) : Color.clear),
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule())
            .onHover { hovered = $0 }
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

        var body: some View {
            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 5) {
                        Text(configuration.isExpanded ? "Hide" : "Details")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(hovered ? RelayColors.textPrimary : RelayColors.textMuted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(hovered || configuration.isExpanded ? RelayColors.textPrimary : RelayColors.textSecondary)
                            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                            .frame(width: 20, height: 20)
                            .background(
                                Color.white.opacity(configuration.isExpanded ? 0.10 : (hovered ? 0.07 : 0.03)),
                                in: Circle()
                            )
                    }
                }
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(hovered ? 0.045 : (configuration.isExpanded ? 0.03 : 0.015)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(hovered || configuration.isExpanded ? 0.12 : 0.06),
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
            shape.fill(Color.white.opacity(0.055))
            shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            Image(systemName: icon)
                .font(.system(size: iconSize ?? (size * 0.44), weight: .medium))
                .foregroundStyle(RelayColors.textBright)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

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
                        .fill(Color.white.opacity(hovered ? 0.08 : 0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovered ? 0.14 : 0.06), lineWidth: 1)
                )
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
            .background(
                ZStack {
                    shape.fill(RelayColors.cardBG)
                    shape.fill(Color.white.opacity(isHovered ? 0.035 : 0.0))
                }
            )
            .overlay(
                shape.strokeBorder(
                    Color.white.opacity(isHovered ? 0.14 : 0.08),
                    lineWidth: 1
                )
            )
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
                .foregroundStyle(RelayColors.textSecondary)
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

    var body: some View {
        DisclosureGroup {
            Text(text)
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label("Action evidence", systemImage: "checkmark.shield")
                .font(.relayCaption.weight(.medium))
                .foregroundStyle(RelayColors.textBright)
        }
        .disclosureGroupStyle(RelayTranscriptDisclosureGroupStyle())
    }
}

// MARK: - Calm Matte Graphite Atmospheric Canvas (ChatGPT macOS & Antigravity Style)
struct RelayAtmosphere: View {
    var focused: Bool = false

    var body: some View {
        ZStack {
            RelayColors.pitch.ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.white.opacity(focused ? 0.025 : 0.015),
                    Color.clear
                ],
                center: .top,
                startRadius: 10,
                endRadius: 520
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
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
            let light = colors ?? [RelayColors.accentBlue, RelayColors.accentAmethyst, RelayColors.accentCoral]
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
            .font(.system(size: 13, weight: .semibold))
            .frame(minWidth: minimumLabelWidth)
            .padding(.horizontal, 16)
            .frame(minHeight: 38)
            .foregroundStyle(enabled ? RelayColors.buttonInk : RelayColors.textMuted)
            .background {
                ZStack {
                    RelayGlowHalo(active: enabled, intensity: glowOpacity * (hovering ? 1.28 : 1))
                    Capsule()
                        .fill(enabled ? .white.opacity(hovering ? 0.94 : 0.99) : RelayColors.surfaceElevated)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
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
                        .fill(LinearGradient(colors: [RelayColors.accentAmethyst, RelayColors.accentBlue, .white],
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
                    .strokeBorder(selected ? RelayColors.accentBlue.opacity(0.55) : .white.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
