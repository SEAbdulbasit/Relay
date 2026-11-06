import AppKit
import SwiftUI
import Observation

// MARK: - 1. NotchShape & NotchSkirtShape (Ported from Sentient OS NotchShape.swift)

/// Top-anchored Dynamic-Island notch silhouette whose outer top corners curve up into the screen bezel
/// and whose inner bottom corners round off. Both radii are animatable for fluid morphing.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        let top = max(0, min(topCornerRadius, rect.height, rect.width / 2))
        let bottom = max(0, min(bottomCornerRadius, rect.width / 2 - top, rect.height - top))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // top-left: curve down out of the bezel
        p.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                       control: CGPoint(x: rect.minX + top, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        // bottom-left inner corner
        p.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                       control: CGPoint(x: rect.minX + top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        // bottom-right inner corner
        p.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // top-right: curve up into the bezel
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - top, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Open path tracing the visible perimeter of the notch (concave top corners, sides, and rounded bottom)
/// without stroking the flat top bezel edge.
struct NotchSkirtShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        let top = max(0, min(topCornerRadius, rect.height, rect.width / 2))
        let bottom = max(0, min(bottomCornerRadius, rect.width / 2 - top, rect.height - top))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                       control: CGPoint(x: rect.minX + top, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                       control: CGPoint(x: rect.minX + top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - top, y: rect.minY))
        return p
    }
}

// MARK: - 2. SpinningLogo (Refined Architectural Monochrome Mark)

/// Clean monochrome silver-and-white orbital emblem (ChatGPT macOS / Antigravity style).
struct SpinningLogo: View {
    var size: CGFloat = 20
    var fast: Bool = false
    var paused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var anchorAngle: Double = 0
    @State private var anchorTime: Double = Date().timeIntervalSinceReferenceDate

    private var isStill: Bool { paused || !fast || reduceMotion }
    private static let activePeriod = 1.8

    private static let bandStops: [Color] = [
        Color.white.opacity(0.95),
        Color.white.opacity(0.35),
        Color.white.opacity(0.18),
        Color.white.opacity(0.55),
        Color.white.opacity(0.95)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isStill)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = anchorAngle + (isStill ? 0 : (t - anchorTime) / Self.activePeriod * 360.0)
            let ringGradient = AngularGradient(colors: Self.bandStops, center: .center, angle: .degrees(angle))
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                Circle()
                    .stroke(ringGradient, lineWidth: max(1.3, size * 0.11))
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.34, height: size * 0.34)
            }
            .frame(width: size, height: size)
        }
        .transaction { $0.animation = nil }
        .onChange(of: isStill) { wasStill, _ in
            let t = Date().timeIntervalSinceReferenceDate
            if !wasStill { anchorAngle += (t - anchorTime) / Self.activePeriod * 360.0 }
            anchorTime = t
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 3. CaretSwirl (Ported from Sentient OS CaretSwirl.swift)

/// Double Tap's rainbow comet spiral: three rainbow comets and 14 golden-angle sparks spiral inward
/// around the text cursor/caret, orbit while drafting, and dive + bloom when the reply lands.
@MainActor @Observable
final class SwirlModel {
    enum Phase {
        case idle
        case gathering
        case landing(since: Date, from: SwirlMath.State)
        case dissolving(since: Date, from: SwirlMath.State)
    }

    var phase: Phase = .idle
    private(set) var began = Date()
    private(set) var orbit = 18.0
    private(set) var initialRadius = SwirlMath.startRadius

    func begin(orbit: Double = 18.0, initialRadius: Double = SwirlMath.startRadius) {
        self.orbit = orbit
        self.initialRadius = initialRadius
        began = Date()
        phase = .gathering
    }

    func transition(landing: Bool) {
        let now = Date()
        let from = SwirlMath.gather(t: now.timeIntervalSince(began), orbit: orbit, initialRadius: initialRadius)
        phase = landing ? .landing(since: now, from: from) : .dissolving(since: now, from: from)
    }
}

struct CaretSwirlView: View {
    let model: SwirlModel

    private var paused: Bool {
        if case .idle = model.phase { return true }
        return false
    }

    var body: some View {
        TimelineView(.animation(paused: paused)) { context in
            Canvas { graphics, size in
                guard let frame = SwirlMath.frame(
                    phase: model.phase,
                    began: model.began,
                    orbit: model.orbit,
                    at: context.date,
                    initialRadius: model.initialRadius
                ) else { return }
                SwirlPainter.draw(frame, in: &graphics, size: size)
            }
        }
        .allowsHitTesting(false)
    }
}

enum SwirlMath {
    static let canvasSide: CGFloat = 560
    static let startRadius = 148.0
    static let landDuration = 0.68
    static let dissolveDuration = 0.62

    struct State {
        var radius: Double
        var angle: Double
        var omega: Double
        var tighten: Double
    }

    struct Frame {
        struct Comet { var radius, head, tail, width, opacity: Double }
        struct Spark { var x, y, size, opacity, angle: Double }
        var comets: [Comet]
        var sparks: [Spark]
        var core: Double
        var hueShift: Double
        var bloom: (radius: Double, opacity: Double)?
        var ripple: (radius: Double, width: Double, opacity: Double)?
    }

    private static let omega0 = 0.85, omegaMax = 3.4, kRadius = 2.3, kSpeed = 1.6
    private static let cometRadius = [1.0, 0.84, 1.14]
    private static let cometSpeed = [1.0, 1.11, 0.93]
    private static let sparkCount = 14

    static func gather(t: Double, orbit: Double, initialRadius: Double = startRadius) -> State {
        let e = exp(-kRadius * t)
        let tighten = 1 - e
        let radius = orbit + (initialRadius - orbit) * e + 2.2 * tighten * sin(2 * .pi * 1.7 * t)
        let es = exp(-kSpeed * t)
        let omega = omegaMax - (omegaMax - omega0) * es
        let angle = 2 * .pi * (omegaMax * t - (omegaMax - omega0) / kSpeed * (1 - es))
        return State(radius: radius, angle: angle, omega: omega, tighten: tighten)
    }

    static func frame(phase: SwirlModel.Phase, began: Date, orbit: Double, at now: Date,
                      initialRadius: Double = startRadius) -> Frame? {
        let t = now.timeIntervalSince(began)
        switch phase {
        case .idle:
            return nil
        case .gathering:
            let base = gather(t: t, orbit: orbit, initialRadius: initialRadius)
            let intro = min(t / 0.12, 1)
            return Frame(
                comets: comets(base, opacity: intro),
                sparks: sparks(base, t: t, radiusScale: 1, opacity: min(t / 0.25, 1)),
                core: base.tighten * base.tighten * (0.85 + 0.15 * sin(2 * .pi * 1.7 * t)),
                hueShift: base.angle * 0.3,
                bloom: nil,
                ripple: nil
            )
        case .landing(let since, let from):
            let u = now.timeIntervalSince(since)
            let p = min(u / 0.24, 1)
            let dive = pow(p, 2.2)
            let base = State(
                radius: from.radius * (1 - dive),
                angle: from.angle + 2 * .pi * from.omega * (u + 1.5 * u * u / 0.24),
                omega: from.omega * (1 + 3 * p),
                tighten: 1
            )
            let bloomAt = 0.16
            let q = max(0, min((u - bloomAt) / 0.42, 1))
            let out = 1 - pow(1 - q, 3)
            let cometOpacity = p < 0.7 ? 1 : max(0, 1 - (p - 0.7) / 0.3)
            let core = u < bloomAt ? from.tighten + (1 - from.tighten) * p : max(0, 1 - q * 1.2)
            let sparkOpacity = u < bloomAt ? 1 : 1 - q
            let sparkScale = u < bloomAt ? 1 - pow(p, 1.8) : 0
            var frame = Frame(
                comets: comets(base, opacity: cometOpacity),
                sparks: sparks(base, t: t, radiusScale: sparkScale, opacity: sparkOpacity),
                core: core,
                hueShift: base.angle * 0.3,
                bloom: nil,
                ripple: nil
            )
            if u >= bloomAt {
                frame.bloom = (radius: 6 + 84 * out, opacity: 0.9 * pow(1 - q, 1.6))
                frame.ripple = (radius: 4 + 110 * out, width: 0.5 + 2.4 * (1 - q), opacity: 0.75 * (1 - q))
                frame.sparks = burst(from: from, t: t, out: out, opacity: 1 - q)
            }
            return frame
        case .dissolving(let since, let from):
            let v = now.timeIntervalSince(since)
            let p = min(v / dissolveDuration, 1)
            let out = 1 - pow(1 - p, 3)
            let base = State(
                radius: from.radius * (1 + 0.35 * out),
                angle: from.angle + 2 * .pi * from.omega * (v - v * v / (2 * dissolveDuration)),
                omega: from.omega * (1 - p),
                tighten: from.tighten
            )
            let fade = pow(1 - p, 1.3)
            return Frame(
                comets: comets(base, opacity: fade),
                sparks: sparks(base, t: t, radiusScale: 1 + 0.5 * out, opacity: fade),
                core: from.tighten * (1 - p),
                hueShift: base.angle * 0.3,
                bloom: nil,
                ripple: nil
            )
        }
    }

    private static func comets(_ base: State, opacity: Double) -> [Frame.Comet] {
        (0..<3).map { i in
            let radius = base.radius * cometRadius[i]
            let speed = min(base.omega / omegaMax, 1.6)
            return Frame.Comet(
                radius: radius,
                head: base.angle * cometSpeed[i] + Double(i) * 2 * .pi / 3,
                tail: min(0.9 + 1.7 * speed, 2.9),
                width: 2.4 + 3.0 * min(radius / startRadius, 1),
                opacity: opacity
            )
        }
    }

    private static func sparkSeed(_ j: Int) -> (angle: Double, orbit: Double, speed: Double, size: Double, twinkle: Double) {
        func frac(_ x: Double) -> Double { x - floor(x) }
        let d = Double(j)
        return (
            angle: d * 2 * .pi * 0.618,
            orbit: 1.06 + 0.42 * frac(d * 0.37),
            speed: 0.7 + 0.6 * frac(d * 0.53),
            size: 1.3 + 1.6 * frac(d * 0.71),
            twinkle: d * 1.3
        )
    }

    private static func sparks(_ base: State, t: Double, radiusScale: Double, opacity: Double) -> [Frame.Spark] {
        (0..<sparkCount).map { j in
            let s = sparkSeed(j)
            let angle = base.angle * s.speed + s.angle
            let r = base.radius * s.orbit * radiusScale
            let twinkle = 0.5 + 0.5 * sin(2 * .pi * 2.1 * t + s.twinkle)
            return Frame.Spark(
                x: r * cos(angle),
                y: r * sin(angle),
                size: s.size,
                opacity: opacity * (0.35 + 0.55 * twinkle),
                angle: angle
            )
        }
    }

    private static func burst(from: State, t: Double, out: Double, opacity: Double) -> [Frame.Spark] {
        (0..<sparkCount).map { j in
            let s = sparkSeed(j)
            let angle = from.angle * s.speed + s.angle + 0.6 * out
            let r = 4 + (34 + 60 * (s.orbit - 1)) * out * 2.2
            return Frame.Spark(
                x: r * cos(angle),
                y: r * sin(angle),
                size: s.size * (1 - 0.5 * out),
                opacity: opacity * 0.9,
                angle: angle
            )
        }
    }
}

enum SwirlPainter {
    private static let wheel: [(r: Double, g: Double, b: Double)] = [
        (0.99, 0.59, 0.27),
        (0.99, 0.38, 0.41),
        (0.95, 0.34, 0.63),
        (0.86, 0.39, 0.84),
        (0.71, 0.40, 0.91),
        (0.55, 0.42, 0.93),
        (0.34, 0.49, 0.97),
        (0.35, 0.63, 0.93),
        (0.49, 0.77, 0.89),
        (0.71, 0.82, 0.74),
        (0.89, 0.80, 0.48),
        (0.97, 0.72, 0.30),
        (0.99, 0.59, 0.27)
    ]

    private static func hue(_ angle: Double, white: Double = 0) -> Color {
        let f = angle / (2 * .pi)
        let pos = (f - floor(f)) * Double(wheel.count - 1)
        let i = min(Int(pos), wheel.count - 2)
        let k = pos - Double(i)
        let a = wheel[i], b = wheel[i + 1]
        let r = a.r + (b.r - a.r) * k, g = a.g + (b.g - a.g) * k, bl = a.b + (b.b - a.b) * k
        return Color(red: r + (1 - r) * white, green: g + (1 - g) * white, blue: bl + (1 - bl) * white)
    }

    static func draw(_ frame: SwirlMath.Frame, in g: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)

        if frame.core > 0.01 {
            let radius = 30.0
            let tint = frame.hueShift + .pi
            let gradient = Gradient(colors: [
                hue(tint, white: 0.3).opacity(0.55 * frame.core),
                hue(tint).opacity(0.28 * frame.core),
                .clear
            ])
            g.fill(
                Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(gradient, center: c, startRadius: 0, endRadius: radius)
            )
        }

        for comet in frame.comets where comet.opacity > 0.01 {
            drawComet(comet, hueShift: frame.hueShift, center: c, in: &g)
        }

        for spark in frame.sparks where spark.opacity > 0.01 {
            let p = CGPoint(x: c.x + spark.x, y: c.y + spark.y)
            let color = hue(spark.angle - frame.hueShift, white: 0.3)
            g.fill(
                Path(ellipseIn: CGRect(x: p.x - spark.size * 2.2, y: p.y - spark.size * 2.2, width: spark.size * 4.4, height: spark.size * 4.4)),
                with: .color(color.opacity(spark.opacity * 0.3))
            )
            g.fill(
                Path(ellipseIn: CGRect(x: p.x - spark.size / 2, y: p.y - spark.size / 2, width: spark.size, height: spark.size)),
                with: .color(color.opacity(spark.opacity))
            )
        }

        if let bloom = frame.bloom, bloom.opacity > 0.01 {
            let gradient = Gradient(colors: [
                hue(frame.hueShift + 1.0, white: 0.45).opacity(bloom.opacity * 0.85),
                hue(frame.hueShift + 1.0).opacity(bloom.opacity * 0.5),
                hue(frame.hueShift + 3.5).opacity(bloom.opacity * 0.2),
                .clear
            ])
            g.fill(
                Path(ellipseIn: CGRect(x: c.x - bloom.radius, y: c.y - bloom.radius, width: bloom.radius * 2, height: bloom.radius * 2)),
                with: .radialGradient(gradient, center: c, startRadius: 0, endRadius: bloom.radius)
            )
        }

        if let ripple = frame.ripple, ripple.opacity > 0.01 {
            let ring = Path(ellipseIn: CGRect(x: c.x - ripple.radius, y: c.y - ripple.radius, width: ripple.radius * 2, height: ripple.radius * 2))
            let stops = (0...6).map { i in
                Gradient.Stop(color: hue(Double(i) / 6 * 2 * .pi).opacity(ripple.opacity), location: Double(i) / 6)
            }
            g.stroke(ring, with: .conicGradient(Gradient(stops: stops), center: c, angle: .radians(frame.hueShift)), lineWidth: ripple.width)
        }
    }

    private static func drawComet(_ comet: SwirlMath.Frame.Comet, hueShift: Double, center c: CGPoint, in g: inout GraphicsContext) {
        let start = comet.head - comet.tail
        var path = Path()
        let steps = 40
        for s in 0...steps {
            let a = start + comet.tail * Double(s) / Double(steps)
            let p = CGPoint(x: c.x + comet.radius * cos(a), y: c.y + comet.radius * sin(a))
            if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        let tailFraction = comet.tail / (2 * .pi)
        var stops: [Gradient.Stop] = (0...8).map { j in
            let k = Double(j) / 8
            return Gradient.Stop(
                color: hue(start + comet.tail * k - hueShift).opacity(pow(k, 1.5) * comet.opacity),
                location: k * tailFraction
            )
        }
        stops.append(Gradient.Stop(color: .clear, location: min(tailFraction + 0.002, 1)))
        stops.append(Gradient.Stop(color: .clear, location: 1))
        let shading = GraphicsContext.Shading.conicGradient(Gradient(stops: stops), center: c, angle: .radians(start))
        let style = StrokeStyle(lineWidth: comet.width, lineCap: .round, lineJoin: .round)

        for (scale, alpha) in [(5.0, 0.10), (2.6, 0.28), (1.0, 1.0)] {
            g.opacity = alpha
            g.stroke(path, with: shading, style: StrokeStyle(lineWidth: style.lineWidth * scale, lineCap: .round, lineJoin: .round))
        }
        g.opacity = 1

        let head = CGPoint(x: c.x + comet.radius * cos(comet.head), y: c.y + comet.radius * sin(comet.head))
        let headColor = hue(comet.head - hueShift, white: 0.3)
        let glow = comet.width * 1.9
        g.fill(
            Path(ellipseIn: CGRect(x: head.x - glow, y: head.y - glow, width: glow * 2, height: glow * 2)),
            with: .color(headColor.opacity(0.35 * comet.opacity))
        )
        let dot = comet.width * 0.75
        g.fill(
            Path(ellipseIn: CGRect(x: head.x - dot, y: head.y - dot, width: dot * 2, height: dot * 2)),
            with: .color(headColor.opacity(comet.opacity))
        )
    }
}

// MARK: - 4. Living Notch Overlay Controller & View (Sentient OS "Notch Magic" Sidekick)

@Observable @MainActor
final class NotchOverlayController {
    static let shared = NotchOverlayController()

    enum NotchPhase: Equatable {
        case compact
        case hovered
        case expanded
        case working
    }

    enum SidekickKey: String, CaseIterable, Identifiable {
        case rightCommand = "rightCommand"
        case rightOption = "rightOption"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .rightCommand: return "Right ⌘ (Command)"
            case .rightOption: return "Right ⌥ (Option)"
            }
        }
        var deviceMask: UInt {
            switch self {
            case .rightCommand: return 0x10 // NX_DEVICERCMDKEYMASK
            case .rightOption: return 0x40  // NX_DEVICERALTKEYMASK
            }
        }
        var modifierFlag: NSEvent.ModifierFlags {
            switch self {
            case .rightCommand: return .command
            case .rightOption: return .option
            }
        }
    }

    var phase: NotchPhase = .compact
    var promptText: String = ""
    var rememberedNoteTitle: String? = nil
    var sidekickKey: SidekickKey = {
        let raw = UserDefaults.standard.string(forKey: "relay.sidekick.hotkey") ?? SidekickKey.rightCommand.rawValue
        return SidekickKey(rawValue: raw) ?? .rightCommand
    }() {
        didSet {
            UserDefaults.standard.set(sidekickKey.rawValue, forKey: "relay.sidekick.hotkey")
        }
    }
    var notchClickEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "relay.sidekick.notchClickEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "relay.sidekick.notchClickEnabled")
    }() {
        didSet {
            UserDefaults.standard.set(notchClickEnabled, forKey: "relay.sidekick.notchClickEnabled")
            if !notchClickEnabled && phase == .hovered {
                phase = .compact
            }
        }
    }
    var speedTier: Int = UserDefaults.standard.integer(forKey: "relay.sidekick.speedTier") {
        didSet {
            UserDefaults.standard.set(speedTier, forKey: "relay.sidekick.speedTier")
        }
    }
    var doubleTapCustomInstructions: String = UserDefaults.standard.string(forKey: "relay.doubleTap.instructions") ?? "Keep replies concise, warm, and grounded in local Markdown notes." {
        didSet {
            UserDefaults.standard.set(doubleTapCustomInstructions, forKey: "relay.doubleTap.instructions")
        }
    }
    var floatingPanelEnabled: Bool = false {
        didSet {
            if floatingPanelEnabled {
                showFloatingNotchPanel()
            } else {
                hideFloatingNotchPanel()
            }
        }
    }
    var lastDoubleTapDraft: String? = nil
    var isDoubleTapSwirling: Bool = false
    var isVoiceHolding: Bool = false
    let swirlModel = SwirlModel()

    @ObservationIgnored private var floatingPanel: NSPanel?
    @ObservationIgnored private var cursorSwirlPanel: NSPanel?
    @ObservationIgnored private var globalFlagsMonitor: Any?
    @ObservationIgnored private var localFlagsMonitor: Any?
    @ObservationIgnored private var globalKeyDownMonitor: Any?
    @ObservationIgnored private var localKeyDownMonitor: Any?
    @ObservationIgnored private weak var monitoredStore: AssistantStore?
    @ObservationIgnored private var keyIsDown = false
    @ObservationIgnored private var chordKeyPressedWhileDown = false
    @ObservationIgnored private var lastCleanKeyUpTime: TimeInterval = 0

    /// Installs Sentient OS's zero-permission global + local `.flagsChanged` monitors reading the right-key device bit (`0x10` / `0x40`).
    func installHotkeyMonitorsIfNeeded(store: AssistantStore) {
        monitoredStore = store
        guard NSApp?.isRunning == true, globalFlagsMonitor == nil, localFlagsMonitor == nil else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let rawFlags = UInt(event.modifierFlags.rawValue)
            Task { @MainActor in
                self?.handleFlagsChanged(rawFlags: rawFlags)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let rawFlags = UInt(event.modifierFlags.rawValue)
            Task { @MainActor in
                self?.handleFlagsChanged(rawFlags: rawFlags)
            }
            return event
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in
                self?.markChordKeyPressed()
            }
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.markChordKeyPressed()
            }
            return event
        }
    }

    private func markChordKeyPressed() {
        chordKeyPressedWhileDown = true
        lastCleanKeyUpTime = 0
    }

    private func handleFlagsChanged(rawFlags: UInt) {
        let mask = sidekickKey.deviceMask
        let pressed = (rawFlags & mask) != 0
        // Ignore chord combinations with Shift, Control, or Option/Command
        let otherModifiersMask: UInt = (sidekickKey == .rightCommand)
            ? UInt(NSEvent.ModifierFlags([.shift, .control, .option]).rawValue)
            : UInt(NSEvent.ModifierFlags([.shift, .control, .command]).rawValue)
        if (rawFlags & otherModifiersMask) != 0 {
            chordKeyPressedWhileDown = true
            lastCleanKeyUpTime = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime

        if pressed && !keyIsDown {
            keyIsDown = true
            chordKeyPressedWhileDown = false
        } else if !pressed && keyIsDown {
            keyIsDown = false
            guard !chordKeyPressedWhileDown else {
                lastCleanKeyUpTime = 0
                return
            }

            let delta = now - lastCleanKeyUpTime
            if delta > 0.04 && delta <= 0.38 {
                // Clean Double Tap (⌘⌘ within 0.38s with no chord keys pressed)
                lastCleanKeyUpTime = 0
                if let store = monitoredStore {
                    triggerDoubleTapDraft(store: store)
                }
            } else {
                lastCleanKeyUpTime = now
            }
        }
    }

    /// Spawns a click-through floating NSPanel right at `NSEvent.mouseLocation` rendering the 3-comet CaretSwirl.
    func showFloatingCursorSwirlAtMouse() {
        let mouse = NSEvent.mouseLocation
        let size: CGFloat = 180
        let frame = NSRect(x: mouse.x - size / 2, y: mouse.y - size / 2, width: size, height: size)
        if cursorSwirlPanel == nil {
            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: CaretSwirlView(model: swirlModel).frame(width: size, height: size))
            cursorSwirlPanel = panel
        } else {
            cursorSwirlPanel?.setFrame(frame, display: true)
        }
        cursorSwirlPanel?.orderFrontRegardless()
    }

    func toggleExpanded() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            if phase == .expanded {
                phase = .compact
            } else {
                phase = .expanded
            }
        }
    }

    func updateRememberedNote(for text: String, records: [KnowledgeRecord]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 3 else {
            rememberedNoteTitle = nil
            return
        }
        if let matched = records.first(where: { rec in
            rec.title.lowercased().contains(trimmed) ||
            trimmed.split(separator: " ").contains(where: { word in word.count >= 4 && rec.title.lowercased().contains(word) })
        }) {
            rememberedNoteTitle = matched.title
        } else {
            rememberedNoteTitle = nil
        }
    }

    /// Prepares an unsent, locally grounded contextual reply prompt in `store.draft`
    /// using actual indexed `KnowledgeRecord` matches and `store.writingProfile`.
    /// Never invents notes, touches the clipboard, pastes, or sends automatically.
    @discardableResult
    func prepareGroundedReplyPrompt(store: AssistantStore, incomingText: String) -> String? {
        let cleaned = incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !PIIScan.containsHighRiskPII(cleaned) else {
            rememberedNoteTitle = nil
            return nil
        }
        updateRememberedNote(for: cleaned, records: store.knowledge.records)
        let styleNote = store.writingProfile.hasApprovedProfile
            ? "matching my saved Writing Profile (\(store.writingProfile.preferredTone.isEmpty ? "personal voice" : store.writingProfile.preferredTone))"
            : "in a concise, natural first-person voice"
        let knowledgeClause: String
        if let noteTitle = rememberedNoteTitle {
            knowledgeClause = " Use my indexed note “\(noteTitle)” via search_knowledge for factual grounding."
        } else {
            knowledgeClause = ""
        }
        let prompt = "Draft an unsent reply \(styleNote) to the following message:\n\"\(cleaned)\"\(knowledgeClause)"
        store.draft = prompt
        return prompt
    }

    /// This legacy entry point remains inert until a real, qualified drafting
    /// pipeline is available. It does not capture the selection or screen,
    /// manufacture a reply, touch the clipboard, paste, or send a message.
    func triggerDoubleTapDraft(store: AssistantStore, sampleContext: String? = nil) {
        lastDoubleTapDraft = nil
        rememberedNoteTitle = nil
        isDoubleTapSwirling = false
        swirlModel.phase = .idle
        cursorSwirlPanel?.orderOut(nil)
        if store.focusedDraft.enabled {
            store.selectionNotice = "Return to the reply field and tap Right Command twice to draft there."
            return
        }
        store.selectionNotice = "Double Tap drafting is unavailable. Enter or paste the text in Relay and ask for a draft; nothing was captured, pasted or sent."
    }

    func showFloatingNotchPanel(store: AssistantStore? = nil) {
        guard floatingPanel == nil, let screen = NSScreen.main else { return }
        let width: CGFloat = 540
        let height: CGFloat = 150
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        let panel = NotchFloatingPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        if let store {
            let host = NSHostingView(rootView: NotchOverlayBar(store: store, controller: self, isFloatingBezel: true))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            panel.contentView = host
        }
        panel.orderFrontRegardless()
        floatingPanel = panel
    }

    func toggleFromRightCommand(store: AssistantStore) {
        if floatingPanel != nil { hideFloatingNotchPanel(); return }
        phase = .expanded
        showFloatingNotchPanel(store: store)
        floatingPanel?.makeKey()
    }

    func hideFloatingNotchPanel() {
        floatingPanel?.orderOut(nil)
        floatingPanel = nil
    }
}

private final class NotchFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The Living Notch Overlay Bar — renders both docked at the top center of Relay's main window
/// AND inside the floating top-bezel NSPanel when enabled.
struct NotchOverlayBar: View {
    @Bindable var store: AssistantStore
    @Bindable var controller: NotchOverlayController
    var isFloatingBezel: Bool = false
    @FocusState private var fieldFocused: Bool

    private var effectivePhase: NotchOverlayController.NotchPhase {
        if store.isRunning { return .working }
        return controller.phase
    }

    private var notchWidth: CGFloat {
        switch effectivePhase {
        case .compact: return 228
        case .hovered: return 348
        case .expanded: return 510
        case .working: return 460
        }
    }

    private var notchHeight: CGFloat {
        switch effectivePhase {
        case .compact: return 32
        case .hovered: return 36
        case .expanded: return controller.rememberedNoteTitle != nil ? 104 : 78
        case .working: return 54
        }
    }

    private var topRadius: CGFloat {
        switch effectivePhase {
        case .compact, .hovered: return 10
        case .expanded, .working: return 14
        }
    }

    private var bottomRadius: CGFloat {
        switch effectivePhase {
        case .compact, .hovered: return 14
        case .expanded, .working: return 20
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Deep pitch-black Notch silhouette
                NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.65), radius: effectivePhase == .expanded ? 22 : 10, y: 6)

                // Rotating AI-spectrum rim glow along NotchSkirtShape (visible perimeter only, never the top bezel seam)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let period = effectivePhase == .working ? 2.5 : 6.0
                    let angle = (t.truncatingRemainder(dividingBy: period) / period) * 360.0
                    let glowOpacity: Double = {
                        switch effectivePhase {
                        case .compact: return 0.28
                        case .hovered: return 0.68
                        case .expanded: return 0.85
                        case .working: return 0.95
                        }
                    }()
                    ZStack {
                        NotchSkirtShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                            .stroke(
                                AngularGradient(colors: RelayGradients.glowStops, center: .center, angle: .degrees(angle)),
                                style: StrokeStyle(lineWidth: effectivePhase == .compact ? 1.2 : 2.2, lineCap: .round)
                            )
                            .blur(radius: effectivePhase == .compact ? 2 : 5)
                            .opacity(glowOpacity)

                        NotchSkirtShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                            .stroke(
                                AngularGradient(colors: RelayGradients.glowStops, center: .center, angle: .degrees(angle)),
                                style: StrokeStyle(lineWidth: 1.0, lineCap: .round)
                            )
                            .opacity(glowOpacity * 0.9)
                    }
                }
                .allowsHitTesting(false)

                // Notch Interior Content
                Group {
                    switch effectivePhase {
                    case .compact:
                        compactContent
                    case .hovered:
                        hoveredContent
                    case .expanded:
                        expandedContent
                    case .working:
                        workingContent
                    }
                }
                .padding(.horizontal, topRadius + 12)
            }
            .frame(width: notchWidth, height: notchHeight)
            .contentShape(NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius))
            .onHover { hovering in
                guard effectivePhase != .working else { return }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    if hovering && controller.phase == .compact {
                        controller.phase = .hovered
                    } else if !hovering && controller.phase == .hovered {
                        controller.phase = .compact
                    }
                }
            }
            .onTapGesture {
                guard effectivePhase != .working else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
                    if controller.phase != .expanded {
                        controller.phase = .expanded
                        fieldFocused = true
                    }
                }
            }

            if isFloatingBezel {
                Spacer(minLength: 0)
            }
        }
    }

    private var compactContent: some View {
        HStack(spacing: 8) {
            SpinningLogo(size: 15, fast: false)
            Text("Sidekick")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
            Text("·")
                .foregroundStyle(RelayColors.textDim)
            Text("Click or ⌘⇧Space")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayColors.textMuted)
        }
        .frame(maxHeight: .infinity)
    }

    private var hoveredContent: some View {
        HStack(spacing: 10) {
            SpinningLogo(size: 17, fast: false)
            Text("Hand off a task to Sidekick")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("⌘⌘ Double Tap")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayColors.accentCyan)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RelayColors.accentCyan.opacity(0.14), in: Capsule())
        }
        .frame(maxHeight: .infinity)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SpinningLogo(size: 20, fast: !controller.promptText.isEmpty)

                ZStack(alignment: .leading) {
                    if controller.promptText.isEmpty {
                        (Text("Tell Sidekick what you want it to ")
                            .foregroundColor(RelayColors.textSecondary)
                         + Text("DO")
                            .foregroundColor(.white)
                            .fontWeight(.heavy))
                            .font(.system(size: 13))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $controller.promptText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .focused($fieldFocused)
                        .onChange(of: controller.promptText) { _, newValue in
                            controller.updateRememberedNote(for: newValue, records: store.knowledge.records)
                        }
                        .onSubmit {
                            submitFromNotch()
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Double Tap 2-tap reply trigger
                Button {
                    controller.triggerDoubleTapDraft(store: store)
                } label: {
                    HStack(spacing: 4) {
                        Text("⌘⌘")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                        Text("Draft")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(RelayColors.accentGold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RelayColors.accentGold.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(RelayColors.accentGold.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(RelayPressStyle())
                .help("Double Tap: Draft a reply in your voice from local context")

                // Send button
                Button {
                    submitFromNotch()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(controller.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.35) : .black)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(
                                controller.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.white.opacity(0.08)
                                    : Color.white
                            )
                        )
                }
                .buttonStyle(RelayPressStyle())
                .disabled(controller.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // Collapse notch button
                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                        controller.phase = .compact
                        fieldFocused = false
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RelayColors.textMuted)
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(RelayPressStyle())
                .help("Collapse Notch")
            }
            .padding(.top, 12)

            // "Remembering <note>" rainbow bloom row (Sentient OS NotchView signature)
            if let note = controller.rememberedNoteTitle {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(RelayColors.accentAmethyst)
                    Text("Remembering")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [RelayColors.accentGold, RelayColors.accentCoral, RelayColors.accentAmethyst, RelayColors.accentCyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text(note)
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Text("LOCAL VAULT")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(RelayColors.textMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04), in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                HStack(spacing: 12) {
                    Label("Computer use ready", systemImage: "cursorarrow.motionlines")
                        .font(.system(size: 10.5))
                        .foregroundStyle(RelayColors.textMuted)
                    Spacer()
                    Button {
                        controller.floatingPanelEnabled.toggle()
                        if controller.floatingPanelEnabled {
                            controller.showFloatingNotchPanel(store: store)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: controller.floatingPanelEnabled ? "macwindow.on.rectangle" : "menubar.dock.rectangle")
                                .font(.system(size: 9.5))
                            Text(controller.floatingPanelEnabled ? "Pinned to Screen Notch" : "Pin to Mac Bezel")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(controller.floatingPanelEnabled ? RelayColors.accentEmerald : RelayColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var workingContent: some View {
        let activeRole = store.activeAgentRole ?? store.agentActivities.last?.role
        let latestLine = store.agentActivities.last.map { "[\($0.role.displayName)] \($0.title)" } ?? store.modelStatus
        return HStack(spacing: 10) {
            SpinningLogo(size: 20, fast: true)

            if let role = activeRole {
                Text(role.displayName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(RelayTheme.agentColor(for: role))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RelayTheme.agentColor(for: role).opacity(0.16), in: Capsule())
            }

            Text(latestLine.isEmpty ? "Executing multi-agent plan…" : latestLine)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.stop()
                withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                    controller.phase = .compact
                }
            } label: {
                Text("STOP")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelayColors.accentCoral.opacity(0.28), in: Capsule())
                    .overlay(Capsule().strokeBorder(RelayColors.accentCoral.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(RelayPressStyle())
        }
        .frame(maxHeight: .infinity)
    }

    private func submitFromNotch() {
        let trimmed = controller.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.draft = trimmed
        controller.promptText = ""
        controller.rememberedNoteTitle = nil
        store.send()
    }
}

// MARK: - 5. Disk-Backed Plain Markdown Knowledge Vault & writingstyle.md Manager

@MainActor
final class KnowledgeVaultManager {
    static let shared = KnowledgeVaultManager()

    private let directoryOverride: URL?

    init(directoryURL: URL? = nil) { directoryOverride = directoryURL }

    var vaultDirectory: URL {
        directoryOverride ?? URL.applicationSupportDirectory
            .appending(path: "Relay", directoryHint: .isDirectory)
            .appending(path: "KnowledgeVault", directoryHint: .isDirectory)
    }

    var writingStyleURL: URL {
        vaultDirectory.appending(path: "writingstyle.md")
    }

    /// Compatibility entry point: creates the container only. User notes are
    /// never seeded with fictitious people, events, preferences or task results.
    func ensureDefaultVaultFilesExist() {
        try? FileManager.default.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)
    }

    func saveVaultNote(title: String, body: String) {
        ensureDefaultVaultFilesExist()
        let filename = title.hasSuffix(".md") ? title : "\(title).md"
        let url = vaultDirectory.appending(path: filename)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    func revealVaultInFinder() {
        ensureDefaultVaultFilesExist()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: vaultDirectory.path)
    }

    func revealWritingStyleInFinder() {
        ensureDefaultVaultFilesExist()
        NSWorkspace.shared.activateFileViewerSelecting([writingStyleURL])
    }

    /// The old keepsake claimed overnight work that had not occurred. Keep the
    /// signature for legacy callers, but do not create that misleading document.
    @discardableResult
    func saveGiftKeepsakeToDesktop(recipientName: String) -> URL? { nil }
}
