import AppKit
import SwiftUI

// MARK: - Concave-Ear Dynamic Notch Silhouette & Open Skirt

/// Top-anchored Dynamic-Island notch silhouette whose upper corners flare outward with concave
/// quadratic Bezier "ears" into the display bezel while its lower corners round off cleanly.
/// On notchless displays (`isIsland == true`), it morphs smoothly into a continuous floating pill.
nonisolated struct NotchShape: Shape, Equatable, Sendable {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var isIsland: Bool = false

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        if isIsland {
            let maxR = min(rect.width / 2, rect.height / 2)
            let radius = max(0, min(bottomCornerRadius, maxR))
            return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        }
        let top = max(0, min(topCornerRadius, rect.height, rect.width / 2))
        let bottom = max(0, min(bottomCornerRadius, rect.width / 2 - top, rect.height - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top-left concave bezel ear
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        // Bottom-left convex corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        // Bottom-right convex corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // Top-right concave bezel ear back up to screen edge
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Open-top perimeter twin of `NotchShape` for physical notches: traces the concave top-left ear,
/// left wall, rounded bottom edge, right wall, and concave top-right ear — leaving the top bezel
/// edge completely un-stroked so the physical camera housing never gets a visible top seam.
nonisolated struct NotchSkirtShape: Shape, Equatable, Sendable {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var isIsland: Bool = false

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        if isIsland {
            let maxR = min(rect.width / 2, rect.height / 2)
            let radius = max(0, min(bottomCornerRadius, maxR))
            return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        }
        let top = max(0, min(topCornerRadius, rect.height, rect.width / 2))
        let bottom = max(0, min(bottomCornerRadius, rect.width / 2 - top, rect.height - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        return path
    }
}

nonisolated func sidekickRadii(
    attached: Bool,
    isHardwareIsland: Bool = false,
    expanded: Bool,
    showsStatus: Bool = false,
    size: CGSize = CGSize(width: 210, height: 34)
) -> (top: CGFloat, bottom: CGFloat) {
    if !attached || isHardwareIsland {
        let radius = expanded ? min(22, min(size.width, size.height) / 2) : min(size.width, size.height) / 2
        return (top: max(6, radius), bottom: max(6, radius))
    }
    if expanded {
        let bottom = min(max(size.height * 0.16, 16), 20)
        return (top: 9, bottom: bottom)
    }
    if showsStatus {
        let bottom = min(max(size.height * 0.32, 11), 15)
        return (top: 9, bottom: bottom)
    }
    let hardwareRadius = max(8, size.height / 3)
    return (top: max(hardwareRadius - 4, 0), bottom: hardwareRadius)
}

nonisolated func sidekickOutline(
    attached: Bool,
    isHardwareIsland: Bool = false,
    expanded: Bool,
    showsStatus: Bool = false,
    size: CGSize = CGSize(width: 210, height: 34)
) -> NotchShape {
    let radii = sidekickRadii(
        attached: attached,
        isHardwareIsland: isHardwareIsland,
        expanded: expanded,
        showsStatus: showsStatus,
        size: size
    )
    return NotchShape(
        topCornerRadius: radii.top,
        bottomCornerRadius: radii.bottom,
        isIsland: !attached || isHardwareIsland
    )
}

/// Computes optical padding and camera-wing layout metrics so expanded notch content stays clear
/// of `NotchShape`'s top concave ears (`topCornerRadius`) and bottom corner curves.
nonisolated struct NotchLayoutMetrics: Equatable, Sendable {
    let attached: Bool
    let isHardwareIsland: Bool
    let earInset: CGFloat
    let headerHorizontalPadding: CGFloat
    let bodyHorizontalPadding: CGFloat
    let bodyBottomPadding: CGFloat
    let headerToBodySpacing: CGFloat
    let rowSpacing: CGFloat
    let topBandHeight: CGFloat
    let wingGap: CGFloat
    let wingWidth: CGFloat

    init(
        attached: Bool,
        isHardwareIsland: Bool,
        topCornerRadius: CGFloat,
        notchWidth: CGFloat,
        centerGap: CGFloat,
        frameWidth: CGFloat,
        notchInset: CGFloat
    ) {
        self.attached = attached
        self.isHardwareIsland = isHardwareIsland
        let ear = (attached && !isHardwareIsland) ? max(0, topCornerRadius) : 0
        self.earInset = ear
        let headerPad = ear + 14
        let bodyPad = ear + 16
        self.headerHorizontalPadding = headerPad
        self.bodyHorizontalPadding = bodyPad
        self.bodyBottomPadding = 14
        self.headerToBodySpacing = 8
        self.rowSpacing = 10
        self.topBandHeight = attached ? max(32, notchInset) : 36
        let gap = (attached && !isHardwareIsland)
            ? max(centerGap, notchWidth > 0 ? notchWidth : 186)
            : 0
        self.wingGap = gap
        self.wingWidth = gap > 0 ? max(44, (frameWidth - gap - headerPad * 2) / 2) : 0
    }
}

// MARK: - Relay Activity Mark

struct RelayActivityMark: View {
    var size: CGFloat = 20
    var fast: Bool = false
    var paused: Bool = false
    var coreScale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animating = fast && !paused && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * .pi
            let press = animating ? 3 * (1 - CGFloat(cos(phase))) : (fast ? 3.0 : 0)
            RelayMark(size: size, press: press)
                .scaleEffect(coreScale)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Hardware-locked dark tokens for the top-of-screen camera notch shell so it always blends
/// seamlessly into the physical MacBook bezel regardless of whether the workspace is in Night or Light mode.
enum NotchVisualTokens {
    static let closedShellFill = Color.black
    static let openShellFill = Color(red: 0.025, green: 0.027, blue: 0.039).opacity(0.92)
    static let solidFallbackFill = Color(white: 0.075)
    static let buttonInk = Color(red: 0.04, green: 0.045, blue: 0.06)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.72)
    static let borderStroke = Color.white.opacity(0.16)
}

struct NotchIdentityMark: View {
    let size: CGFloat
    let working: Bool
    var paused: Bool = false
    var onActivate: (() -> Void)? = nil

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Circle().inset(by: -4))
                .onTapGesture { onActivate?() }
                .onHover { value in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        hovering = value
                    }
                }
            RelayActivityMark(
                size: size,
                fast: working,
                paused: paused,
                coreScale: hovering ? 1.25 : 1.0
            )
        }
        .frame(width: size, height: size)
        .onDisappear { hovering = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Relay Sidekick")
        .accessibilityAddTraits(onActivate != nil ? .isButton : [])
        .accessibilityHidden(onActivate == nil)
    }
}

// MARK: - Materials, Camera Crown & Underlight Surfaces

/// Always-active dark behind-window HUD blur unaffected by key-window focus changes.
struct IslandBackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.identifier = NSUserInterfaceItemIdentifier("relay.island.backdrop")
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .active
    }

    static func dismantleNSView(_ view: NSVisualEffectView, coordinator: ()) {
        view.isHidden = true
        view.layer?.removeAllAnimations()
    }
}

/// Seamless #000000 top crown that covers the hardware camera band and gently dissolves downward
/// into the translucent obsidian glass surface with zero horizontal seam.
struct NotchBlackCrown: View {
    let protectedHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            let start = min(protectedHeight, height)
            let fade = min(44, max(0, height - start))
            if fade <= 0 {
                Color.black
            } else {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: start / height),
                        .init(color: .black.opacity(0.86), location: (start + fade * 0.28) / height),
                        .init(color: .black.opacity(0.26), location: (start + fade * 0.76) / height),
                        .init(color: .clear, location: (start + fade) / height),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// The expanded Sidekick shares the workspace's static teal atmosphere. The
/// hardware camera band is still protected by NotchBlackCrown above this surface.
struct NotchUnderlightSurface: View {
    let shape: NotchShape
    let animated: Bool
    var lightingStrength: Double = 0.42
    var blackBody: Bool = false
    var solidBlackBase: Bool = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            shape.fill(blackBody || solidBlackBase
                       ? NotchVisualTokens.closedShellFill
                       : NotchVisualTokens.solidFallbackFill)
            if !blackBody {
                if !reduceTransparency && contrast != .increased && lightingStrength > 0 {
                    RelayWorkspaceBackdrop()
                        .environment(\.colorScheme, .dark)
                        .clipShape(shape)
                        .opacity(0.22)
                } else {
                    shape.fill(NotchVisualTokens.solidFallbackFill)
                }
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Three-layer chromatic spectrum stroke tracing `NotchSkirtShape` — lights the concave ears,
/// vertical side walls, and curved bottom lip without ever illuminating the flat top bezel line.
struct NotchSkirtLineGlow: View {
    let radii: (top: CGFloat, bottom: CGFloat)
    let isIsland: Bool
    var active: Bool = true
    var animated: Bool = true
    var strength: Double = 0.72
    var rotationPeriod: TimeInterval = 12.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stops: [Color] = [
        Color(red: 0x7D / 255.0, green: 0xD3 / 255.0, blue: 0xFC / 255.0),
        Color(red: 0x38 / 255.0, green: 0xBD / 255.0, blue: 0xF8 / 255.0),
        Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0),
        Color(red: 0x63 / 255.0, green: 0x66 / 255.0, blue: 0xF1 / 255.0),
        Color(red: 0x2D / 255.0, green: 0xD4 / 255.0, blue: 0xBF / 255.0),
        Color(red: 0xBA / 255.0, green: 0xE6 / 255.0, blue: 0xFD / 255.0),
        Color(red: 0x7D / 255.0, green: 0xD3 / 255.0, blue: 0xFC / 255.0),
    ]

    var body: some View {
        let paused = !active || !animated || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = paused ? 32.0 : (t.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod) * 360.0
            let breathe = paused ? 0.5 : (sin(t * 2 * .pi / 3.2) + 1) / 2
            ZStack {
                glowPass(angle: angle, breathe: breathe, lineWidth: 10, blur: 12, layerOpacity: 0.28)
                glowPass(angle: angle, breathe: breathe, lineWidth: 3.2, blur: 4, layerOpacity: 0.52)
                glowPass(angle: angle, breathe: breathe, lineWidth: 1.4, blur: 0.45, layerOpacity: 0.96)
            }
        }
        .opacity(strength)
        .allowsHitTesting(false)
    }

    private func glowPass(angle: Double, breathe: Double, lineWidth: CGFloat, blur: CGFloat, layerOpacity: Double) -> some View {
        let margin = lineWidth / 2 + blur + 6
        return AngularGradient(colors: Self.stops, center: .center, angle: .degrees(angle))
            .opacity((0.86 + 0.14 * breathe) * layerOpacity)
            .mask {
                NotchSkirtShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom, isIsland: isIsland)
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .padding(margin)
            }
            .blur(radius: blur)
            .padding(-margin)
    }
}

/// Staggered 3-ribbon directional underlight sweeping left-to-right across the bottom edge while
/// Relay is preparing or executing a task.
struct NotchThinkingUnderlight: View {
    var active: Bool
    var protectedHeight: CGFloat = 0
    var maximumDepth: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let depth = min(maximumDepth, max(4, geometry.size.height - protectedHeight))
            if reduceMotion {
                LinearGradient(
                    colors: [
                        Color(red: 0x38 / 255.0, green: 0xBD / 255.0, blue: 0xF8 / 255.0).opacity(0.45),
                        Color(red: 0x63 / 255.0, green: 0x66 / 255.0, blue: 0xF1 / 255.0).opacity(0.50),
                        Color(red: 0x2D / 255.0, green: 0xD4 / 255.0, blue: 0xBF / 255.0).opacity(0.45),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: min(6, depth))
                .blur(radius: 2.2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { ctx in
                    let time = ctx.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        let colors = [
                            Color(red: 0x38 / 255.0, green: 0xBD / 255.0, blue: 0xF8 / 255.0),
                            Color(red: 0x63 / 255.0, green: 0x66 / 255.0, blue: 0xF1 / 255.0),
                            Color(red: 0x2D / 255.0, green: 0xD4 / 255.0, blue: 0xBF / 255.0),
                        ]
                        for (index, color) in colors.enumerated() {
                            let progress = (time / 3.6 + Double(index) / 3.0)
                                .truncatingRemainder(dividingBy: 1.0)
                            let x = size.width * (-0.40 + 1.80 * progress)
                            let intensity = pow(sin(progress * .pi), 0.75) * 0.92
                            let center = CGPoint(x: x, y: size.height * 1.05)

                            context.drawLayer { glow in
                                glow.addFilter(.blur(radius: 5))
                                let area = CGRect(
                                    x: x - size.width * 0.34,
                                    y: -size.height,
                                    width: size.width * 0.68,
                                    height: size.height * 4
                                )
                                glow.fill(
                                    Path(ellipseIn: area),
                                    with: .radialGradient(
                                        Gradient(colors: [
                                            color.opacity(intensity),
                                            color.opacity(intensity * 0.48),
                                            .clear,
                                        ]),
                                        center: center,
                                        startRadius: 0,
                                        endRadius: size.width * 0.34
                                    )
                                )
                            }

                            context.drawLayer { ribbon in
                                ribbon.addFilter(.blur(radius: 1.6))
                                let area = CGRect(
                                    x: x - size.width * 0.22,
                                    y: size.height - 3,
                                    width: size.width * 0.44,
                                    height: 4.5
                                )
                                ribbon.fill(
                                    Path(roundedRect: area, cornerRadius: 2.25),
                                    with: .linearGradient(
                                        Gradient(colors: [.clear, color.opacity(intensity * 0.88), .clear]),
                                        startPoint: CGPoint(x: area.minX, y: area.midY),
                                        endPoint: CGPoint(x: area.maxX, y: area.midY)
                                    )
                                )
                            }
                        }
                    }
                }
                .frame(height: depth)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.22), location: 0.35),
                            .init(color: .white, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : (active ? 0.55 : 0.30)), value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Controls, Waveform & Blur-Dissolve Transition

struct LumenCursor: View {
    var size: CGFloat = 14
    var lifted: Bool = false
    var illuminated: Bool = false

    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(0.96))
            .offset(x: lifted ? 1.5 : 0, y: lifted ? -1.5 : 0)
            .background {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(illuminated ? 0.18 : 0.08), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 1.1
                        )
                    )
                    .frame(width: size * 2.1, height: size * 2.1)
            }
            .accessibilityHidden(true)
    }
}

struct NotchSendButton: View {
    let enabled: Bool
    var help: String = "Send Sidekick task"
    var diameter: CGFloat = 20
    var showsHalo: Bool = true
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var isLight: Bool { colorScheme == .light }

    private var arrowForeground: Color {
        if isLight {
            return enabled ? .white : Color.black.opacity(0.34)
        } else {
            return enabled ? NotchVisualTokens.buttonInk : .white.opacity(0.42)
        }
    }

    private var circleFill: Color {
        if isLight {
            if enabled {
                return hovering
                    ? Color(red: 0x11 / 255.0, green: 0x13 / 255.0, blue: 0x18 / 255.0)
                    : RelayColors.accentBlue
            } else {
                return Color.black.opacity(0.06)
            }
        } else {
            if enabled {
                return .white.opacity(hovering ? 1.0 : 0.96)
            } else {
                return .white.opacity(0.09)
            }
        }
    }

    private var circleStroke: Color {
        if isLight {
            return enabled ? Color.black.opacity(0.12) : Color.black.opacity(0.10)
        } else {
            return enabled ? .white.opacity(0.24) : .white.opacity(0.14)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if enabled && showsHalo {
                    RelayGlowHalo(active: true, intensity: hovering ? 0.56 : 0.38, period: 4.5)
                        .frame(width: diameter, height: diameter)
                }
                Image(systemName: "arrow.up")
                    .font(.system(size: diameter >= 30 ? 13 : (diameter > 18 ? 11 : 9.5), weight: .bold))
                    .foregroundStyle(arrowForeground)
                    .frame(width: diameter, height: diameter)
                    .background(
                        Circle()
                            .fill(circleFill)
                            .shadow(
                                color: (isLight && enabled) ? RelayColors.accentBlue.opacity(hovering ? 0.18 : 0.32) : .clear,
                                radius: 5,
                                x: 0,
                                y: 2
                            )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(circleStroke, lineWidth: enabled ? 0.75 : 1.0)
                    )
            }
            .contentShape(Circle().inset(by: -5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .onChange(of: enabled) { _, on in if !on { hovering = false } }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.14), value: enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct NotchCompactButtonStyle: ButtonStyle {
    var prominent: Bool = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var isLight: Bool { colorScheme == .light }

    func makeBody(configuration: Configuration) -> some View {
        let fgColor: Color = {
            if isLight {
                if prominent {
                    return enabled ? .white : Color.black.opacity(0.36)
                } else {
                    return Color.black.opacity(enabled ? (hovering ? 0.92 : 0.78) : 0.36)
                }
            } else {
                if prominent {
                    return enabled ? NotchVisualTokens.buttonInk : .white.opacity(0.42)
                } else {
                    return .white.opacity(enabled ? (hovering ? 0.98 : 0.88) : 0.38)
                }
            }
        }()

        let bgFill: Color = {
            if isLight {
                if prominent {
                    return !enabled
                        ? Color.black.opacity(0.06)
                        : (configuration.isPressed
                            ? RelayColors.accentBlue.opacity(0.84)
                            : (hovering ? Color(red: 0x11 / 255.0, green: 0x13 / 255.0, blue: 0x18 / 255.0) : RelayColors.accentBlue))
                } else {
                    return Color.black.opacity(enabled ? (configuration.isPressed ? 0.12 : (hovering ? 0.08 : 0.05)) : 0.03)
                }
            } else {
                if prominent {
                    return .white.opacity(!enabled ? 0.14 : (configuration.isPressed ? 0.82 : (hovering ? 0.98 : 0.94)))
                } else {
                    return .white.opacity(enabled ? (configuration.isPressed ? 0.18 : (hovering ? 0.13 : 0.08)) : 0.04)
                }
            }
        }()

        let borderStroke: Color = {
            if isLight {
                return Color.black.opacity(prominent ? (enabled ? 0.14 : 0.08) : (enabled ? (hovering ? 0.18 : 0.11) : 0.06))
            } else {
                return .white.opacity(prominent ? (enabled ? 0.24 : 0.08) : (enabled ? (hovering ? 0.24 : 0.16) : 0.06))
            }
        }()

        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(fgColor)
            .padding(.horizontal, 12)
            .frame(height: RelayControlHeight.pill)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(bgFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(borderStroke, lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.97)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

struct NotchStopButton: View {
    var diameter: CGFloat = 20
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var isLight: Bool { colorScheme == .light }

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: diameter > 18 ? 9.5 : 8.5, weight: .bold))
                .foregroundStyle(
                    isLight
                        ? (hovering ? RelayColors.accentCoral : Color(red: 0x11 / 255.0, green: 0x13 / 255.0, blue: 0x18 / 255.0).opacity(0.88))
                        : .white.opacity(0.95)
                )
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(
                        isLight
                            ? Color.black.opacity(hovering ? 0.12 : 0.07)
                            : .white.opacity(hovering ? 0.24 : 0.15)
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        isLight
                            ? Color.black.opacity(hovering ? 0.22 : 0.14)
                            : .white.opacity(hovering ? 0.36 : 0.22),
                        lineWidth: 0.85
                    )
                )
                .contentShape(Circle().inset(by: -5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help("Stop")
        .accessibilityLabel("Stop Relay task")
    }
}

struct NotchIconButtonStyle: ButtonStyle {
    var circular: Bool = true
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : (hovering ? 0.98 : 0.78)))
            .background {
                if circular {
                    Circle().fill(.white.opacity(hovering ? 0.13 : 0))
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.13 : 0))
                }
            }
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.13), value: hovering)
    }
}

struct NotchMessageButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(prominent ? 0.94 : 0.74))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(prominent ? (hovering ? 0.14 : 0.095) : (hovering ? 0.08 : 0.045)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.22 : 0.11), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.15), value: hovering)
            .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.15), value: configuration.isPressed)
    }
}

struct NotchAudioWaveform: View {
    var isRecording: Bool
    var height: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 14
    private static let restingProfile: [CGFloat] = [
        0.24, 0.36, 0.56, 0.38, 0.68, 0.88, 0.52,
        0.92, 0.64, 0.44, 0.72, 0.48, 0.34, 0.22
    ]

    var body: some View {
        let paused = !isRecording || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: paused)) { ctx in
            let t = paused ? 0.0 : ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    let base = Self.restingProfile[index]
                    let wave = paused
                        ? base * 0.55
                        : max(0.18, min(1.0, base * (0.42 + 0.58 * (0.5 + 0.5 * sin(t * 7.5 + Double(index) * 0.72)))))
                    Capsule(style: .continuous)
                        .fill(isRecording ? RelayColors.accentCoral.opacity(0.92) : .white.opacity(0.65))
                        .frame(width: 2.2, height: max(3, wave * height))
                }
            }
            .frame(height: height, alignment: .center)
        }
        .accessibilityHidden(true)
    }
}

private struct NotchBlurFadeScale: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(opacity)
            .scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    static var notchBlurDissolve: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: NotchBlurFadeScale(radius: 7, opacity: 0, scale: 0.94),
                identity: NotchBlurFadeScale(radius: 0, opacity: 1, scale: 1.0)
            ),
            removal: .modifier(
                active: NotchBlurFadeScale(radius: 6, opacity: 0, scale: 1.03),
                identity: NotchBlurFadeScale(radius: 0, opacity: 1, scale: 1.0)
            )
        )
    }
}
