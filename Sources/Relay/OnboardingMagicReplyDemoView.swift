import AppKit
import SwiftUI

// MARK: - Relay Electric Indigo/Cyan Caret Pulse Engine

@MainActor @Observable
final class OnboardingCaretSwirlModel {
    enum Phase {
        case idle
        case gathering
        case landing(since: Date, from: OnboardingSwirlMath.State)
    }

    var phase: Phase = .idle
    private(set) var began = Date()
    private(set) var orbit = 16.0
    private(set) var initialRadius = OnboardingSwirlMath.startRadius

    func begin(orbit: Double = 16.0, initialRadius: Double = OnboardingSwirlMath.startRadius) {
        self.orbit = orbit
        self.initialRadius = initialRadius
        self.began = Date()
        self.phase = .gathering
    }

    func transitionToLanding() {
        let now = Date()
        let from = OnboardingSwirlMath.gather(
            t: now.timeIntervalSince(began),
            orbit: orbit,
            initialRadius: initialRadius
        )
        phase = .landing(since: now, from: from)
    }

    func reset() {
        phase = .idle
    }
}

struct OnboardingCaretSwirlView: View {
    let model: OnboardingCaretSwirlModel

    private var paused: Bool {
        if case .idle = model.phase { return true }
        return false
    }

    var body: some View {
        TimelineView(.animation(paused: paused)) { context in
            Canvas { graphics, size in
                guard let frame = OnboardingSwirlMath.frame(
                    phase: model.phase,
                    began: model.began,
                    orbit: model.orbit,
                    at: context.date,
                    initialRadius: model.initialRadius
                ) else { return }
                OnboardingSwirlPainter.draw(frame, in: &graphics, size: size)
            }
        }
        .allowsHitTesting(false)
    }
}

enum OnboardingSwirlMath {
    static let startRadius = 112.0
    static let landDuration = 0.55

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

    private static let omega0 = 0.85, omegaMax = 3.2, kRadius = 2.4, kSpeed = 1.6
    private static let cometRadius = [1.0, 0.84, 1.12]
    private static let cometSpeed = [1.0, 1.09, 0.94]
    private static let sparkCount = 10

    static func gather(t: Double, orbit: Double, initialRadius: Double = startRadius) -> State {
        let e = exp(-kRadius * t)
        let tighten = 1 - e
        let radius = orbit + (initialRadius - orbit) * e + 1.8 * tighten * sin(2 * .pi * 1.6 * t)
        let es = exp(-kSpeed * t)
        let omega = omegaMax - (omegaMax - omega0) * es
        let angle = 2 * .pi * (omegaMax * t - (omegaMax - omega0) / kSpeed * (1 - es))
        return State(radius: radius, angle: angle, omega: omega, tighten: tighten)
    }

    static func frame(
        phase: OnboardingCaretSwirlModel.Phase,
        began: Date,
        orbit: Double,
        at now: Date,
        initialRadius: Double = startRadius
    ) -> Frame? {
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
                core: base.tighten * base.tighten * (0.85 + 0.15 * sin(2 * .pi * 1.6 * t)),
                hueShift: base.angle * 0.25,
                bloom: nil,
                ripple: nil
            )
        case .landing(let since, let from):
            let u = now.timeIntervalSince(since)
            let p = min(u / 0.22, 1)
            let dive = pow(p, 2.1)
            let base = State(
                radius: from.radius * (1 - dive),
                angle: from.angle + 2 * .pi * from.omega * (u + 1.4 * u * u / 0.22),
                omega: from.omega * (1 + 2.6 * p),
                tighten: 1
            )
            let bloomAt = 0.14
            let q = max(0, min((u - bloomAt) / 0.38, 1))
            let out = 1 - pow(1 - q, 3)
            let cometOpacity = p < 0.7 ? 1 : max(0, 1 - (p - 0.7) / 0.3)
            let core = u < bloomAt ? from.tighten + (1 - from.tighten) * p : max(0, 1 - q * 1.2)
            let sparkOpacity = u < bloomAt ? 1 : 1 - q
            let sparkScale = u < bloomAt ? 1 - pow(p, 1.8) : 0
            var frame = Frame(
                comets: comets(base, opacity: cometOpacity),
                sparks: sparks(base, t: t, radiusScale: sparkScale, opacity: sparkOpacity),
                core: core,
                hueShift: base.angle * 0.25,
                bloom: nil,
                ripple: nil
            )
            if u >= bloomAt {
                frame.bloom = (radius: 6 + 64 * out, opacity: 0.75 * pow(1 - q, 1.6))
                frame.ripple = (radius: 4 + 84 * out, width: 0.5 + 2.0 * (1 - q), opacity: 0.65 * (1 - q))
                frame.sparks = burst(from: from, t: t, out: out, opacity: 1 - q)
            }
            return frame
        }
    }

    private static func comets(_ base: State, opacity: Double) -> [Frame.Comet] {
        (0..<3).map { i in
            let radius = base.radius * cometRadius[i]
            let speed = min(base.omega / omegaMax, 1.6)
            return Frame.Comet(
                radius: radius,
                head: base.angle * cometSpeed[i] + Double(i) * 2 * .pi / 3,
                tail: min(0.85 + 1.5 * speed, 2.6),
                width: 2.0 + 2.2 * min(radius / startRadius, 1),
                opacity: opacity
            )
        }
    }

    private static func sparkSeed(_ j: Int) -> (angle: Double, orbit: Double, speed: Double, size: Double, twinkle: Double) {
        func frac(_ x: Double) -> Double { x - floor(x) }
        let d = Double(j)
        return (
            angle: d * 2 * .pi * 0.618,
            orbit: 1.04 + 0.36 * frac(d * 0.37),
            speed: 0.7 + 0.5 * frac(d * 0.53),
            size: 1.2 + 1.4 * frac(d * 0.71),
            twinkle: d * 1.3
        )
    }

    private static func sparks(_ base: State, t: Double, radiusScale: Double, opacity: Double) -> [Frame.Spark] {
        (0..<sparkCount).map { j in
            let s = sparkSeed(j)
            let angle = base.angle * s.speed + s.angle
            let r = base.radius * s.orbit * radiusScale
            let twinkle = 0.5 + 0.5 * sin(2 * .pi * 2.0 * t + s.twinkle)
            return Frame.Spark(
                x: r * cos(angle),
                y: r * sin(angle),
                size: s.size,
                opacity: opacity * (0.35 + 0.50 * twinkle),
                angle: angle
            )
        }
    }

    private static func burst(from: State, t: Double, out: Double, opacity: Double) -> [Frame.Spark] {
        (0..<sparkCount).map { j in
            let s = sparkSeed(j)
            let angle = from.angle * s.speed + s.angle + 0.5 * out
            let r = 4 + (28 + 46 * (s.orbit - 1)) * out * 1.9
            return Frame.Spark(
                x: r * cos(angle),
                y: r * sin(angle),
                size: s.size * (1 - 0.5 * out),
                opacity: opacity * 0.85,
                angle: angle
            )
        }
    }
}

enum OnboardingSwirlPainter {
    private static let wheel: [(r: Double, g: Double, b: Double)] = [
        (0.388, 0.400, 0.945), // Electric Indigo #6366F1
        (0.231, 0.510, 0.965), // Sapphire #3B82F6
        (0.055, 0.647, 0.914), // Sky Cyan #0EA5E9
        (0.024, 0.714, 0.831), // Teal Cyan #06B6D4
        (0.063, 0.725, 0.506), // Emerald #10B981
        (0.231, 0.510, 0.965), // Sapphire #3B82F6
        (0.545, 0.361, 0.965), // Soft Violet #8B5CF6
        (0.388, 0.400, 0.945)  // Electric Indigo #6366F1
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

    static func draw(_ frame: OnboardingSwirlMath.Frame, in g: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)

        if frame.core > 0.01 {
            let radius = 24.0
            let tint = frame.hueShift + .pi
            let gradient = Gradient(colors: [
                hue(tint, white: 0.3).opacity(0.50 * frame.core),
                hue(tint).opacity(0.24 * frame.core),
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
                Path(ellipseIn: CGRect(x: p.x - spark.size * 2.0, y: p.y - spark.size * 2.0, width: spark.size * 4.0, height: spark.size * 4.0)),
                with: .color(color.opacity(spark.opacity * 0.28))
            )
            g.fill(
                Path(ellipseIn: CGRect(x: p.x - spark.size / 2, y: p.y - spark.size / 2, width: spark.size, height: spark.size)),
                with: .color(color.opacity(spark.opacity))
            )
        }

        if let bloom = frame.bloom, bloom.opacity > 0.01 {
            let gradient = Gradient(colors: [
                hue(frame.hueShift + 1.0, white: 0.45).opacity(bloom.opacity * 0.80),
                hue(frame.hueShift + 1.0).opacity(bloom.opacity * 0.45),
                hue(frame.hueShift + 3.5).opacity(bloom.opacity * 0.18),
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
            g.stroke(
                ring,
                with: .conicGradient(Gradient(stops: stops), center: c, angle: .radians(frame.hueShift)),
                lineWidth: ripple.width
            )
        }
    }

    private static func drawComet(
        _ comet: OnboardingSwirlMath.Frame.Comet,
        hueShift: Double,
        center c: CGPoint,
        in g: inout GraphicsContext
    ) {
        let start = comet.head - comet.tail
        var path = Path()
        let steps = 32
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

        for (scale, alpha) in [(4.2, 0.10), (2.2, 0.26), (1.0, 1.0)] {
            g.opacity = alpha
            g.stroke(path, with: shading, style: StrokeStyle(lineWidth: comet.width * scale, lineCap: .round, lineJoin: .round))
        }
        g.opacity = 1

        let head = CGPoint(x: c.x + comet.radius * cos(comet.head), y: c.y + comet.radius * sin(comet.head))
        let headColor = hue(comet.head - hueShift, white: 0.3)
        let glow = comet.width * 1.7
        g.fill(
            Path(ellipseIn: CGRect(x: head.x - glow, y: head.y - glow, width: glow * 2, height: glow * 2)),
            with: .color(headColor.opacity(0.32 * comet.opacity))
        )
        let dot = comet.width * 0.70
        g.fill(
            Path(ellipseIn: CGRect(x: head.x - dot, y: head.y - dot, width: dot * 2, height: dot * 2)),
            with: .color(headColor.opacity(comet.opacity))
        )
    }
}

private struct MagicReplyCaretBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - OnboardingMagicReplyDemoView (Step 2 Multi-App Interactive Playground)

struct OnboardingMagicReplyDemoView: View {
    enum Stage: Equatable {
        case waitingForTrigger
        case drafting
        case drafted
    }

    enum SelectedNotchAction: String, CaseIterable, Identifiable {
        case magicReply = "Instant Draft"
        case takeOver = "Take Over"
        case summarize = "Summarize"
        case proofread = "Proofread"

        var id: String { rawValue }

        var showcaseLabel: String { rawValue }

        var symbol: String {
            switch self {
            case .magicReply: "sparkles"
            case .takeOver: "cursorarrow.motionlines"
            case .summarize: "doc.text.magnifyingglass"
            case .proofread: "text.badge.checkmark"
            }
        }
    }

    enum DemoAppContext: String, CaseIterable, Identifiable {
        case appleMail = "Apple Mail"
        case slackDM = "Slack DM"
        case iMessage = "iMessage"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .appleMail: "envelope.fill"
            case .slackDM: "number.square.fill"
            case .iMessage: "message.fill"
            }
        }

        var avatarInitials: String {
            switch self {
            case .appleMail: "ML"
            case .slackDM: "AC"
            case .iMessage: "SJ"
            }
        }

        var avatarTint: Color {
            switch self {
            case .appleMail: Color(red: 0.25, green: 0.45, blue: 0.92)
            case .slackDM: Color(red: 0.18, green: 0.75, blue: 0.68)
            case .iMessage: Color(red: 0.22, green: 0.78, blue: 0.48)
            }
        }

        var senderName: String {
            switch self {
            case .appleMail: "Maya Lin"
            case .slackDM: "Alex Chen"
            case .iMessage: "Sarah Jenkins"
            }
        }

        var threadContext: String {
            switch self {
            case .appleMail: "· Q4 Architecture Review"
            case .slackDM: "· #northstar-rollout"
            case .iMessage: "· Saturday Dinner Plan"
            }
        }

        var incomingText: String {
            switch self {
            case .appleMail:
                "Are you free Thursday at 2:30 PM to walk through the Q4 benchmark notes and Friday release checklist?"
            case .slackDM:
                "Hey — did Okta SAML sign-off land for the 80-seat Northstar pilot, or should we hold Friday’s deploy?"
            case .iMessage:
                "Are we still doing Juniper at 7:30 PM this Saturday? Need to know if I should confirm 4 seats!"
            }
        }

        var sourcePills: [(icon: String, label: String)] {
            switch self {
            case .appleMail:
                return [("doc.text.fill", "Benchmark Notes"), ("calendar", "Thu 2:30 PM"), ("person.text.rectangle", "Tone Profile")]
            case .slackDM:
                return [("lock.shield.fill", "sso-review.md"), ("folder.fill", "northstar.md"), ("person.text.rectangle", "Slack Cadence")]
            case .iMessage:
                return [("fork.knife", "Juniper Hold"), ("calendar", "Sat 7:30 PM"), ("person.2.fill", "4 Guests")]
            }
        }

        func replyText(for remix: DraftRemixPreset) -> String {
            switch (self, remix) {
            case (.appleMail, .standard):
                return "Hi Maya — Thursday at 2:30 PM works for me. I’ll send the updated Q4 benchmark notes and release checklist before our call."
            case (.appleMail, .shorter):
                return "Thursday at 2:30 PM works great. Sending the Q4 benchmark notes and checklist shortly."
            case (.appleMail, .warmer):
                return "Hey Maya! Thursday at 2:30 PM works great for me — excited to walk through the Q4 benchmarks and Friday release plan together."
            case (.appleMail, .counterTime):
                return "Hi Maya — I have a conflict at 2:30 PM Thursday, but Friday at 11:00 AM is wide open. I’ll share the Q4 benchmark notes ahead of time."

            case (.slackDM, .standard):
                return "Okta SAML + SCIM passed verification today — final security sign-off is Thursday at 2:30 PM, so Friday’s 80-seat deploy stays on track."
            case (.slackDM, .shorter):
                return "SAML/SCIM is verified. Final sign-off is Thu 2:30 PM — Friday deploy is green."
            case (.slackDM, .warmer):
                return "All good on our end! Okta SAML passed today and we lock final sign-off Thursday at 2:30 PM — Friday’s 80-seat rollout is good to go."
            case (.slackDM, .counterTime):
                return "SAML is verified; let’s do a quick 10-min sync Friday at 11:00 AM right before flipping the 80-seat rollout flag."

            case (.iMessage, .standard):
                return "Yes! Saturday at 7:30 PM at Juniper is locked in for 4 seats on the patio — already added the hold to our calendar."
            case (.iMessage, .shorter):
                return "Locked in! Juniper for 4 at 7:30 PM Saturday on the patio."
            case (.iMessage, .warmer):
                return "100% on! Reserved Juniper for 4 at 7:30 PM Saturday on the patio — can’t wait to catch up!"
            case (.iMessage, .counterTime):
                return "7:30 PM is great, or we can do 8:00 PM on the patio if you want extra time — confirm 4 seats either way!"
            }
        }
    }

    enum DraftRemixPreset: String, CaseIterable, Identifiable {
        case standard = "Your Voice"
        case shorter = "Shorter"
        case warmer = "Warmer"
        case counterTime = "Alt Time"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .standard: "sparkles"
            case .shorter: "bolt.fill"
            case .warmer: "hand.wave.fill"
            case .counterTime: "calendar.badge.clock"
            }
        }
    }

    enum TakeOverStage: Int, CaseIterable {
        case idle = 0
        case planner = 1
        case navigator = 2
        case awaitingReview = 3
        case verifier = 4

        var roleName: String {
            switch self {
            case .idle: "Planner"
            case .planner: "Planner"
            case .navigator: "Navigator"
            case .awaitingReview: "Executor"
            case .verifier: "Verifier"
            }
        }

        var shortStepTitle: String {
            switch self {
            case .idle: "Ready"
            case .planner: "1. Inspect Mail & Calendar"
            case .navigator: "2. Select Thu 2:30 PM Slot"
            case .awaitingReview: "3. Hold for 1-Click Review"
            case .verifier: "4. Verified Invite & Draft"
            }
        }
    }

    enum SummarySource: String, CaseIterable, Identifiable {
        case pdfReport = "PDF Report"
        case safariArticle = "Safari Article"
        case youtubeTranscript = "YouTube Lecture"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .pdfReport: "doc.richtext.fill"
            case .safariArticle: "safari.fill"
            case .youtubeTranscript: "play.rectangle.fill"
            }
        }

        var documentTitle: String {
            switch self {
            case .pdfReport: "Q4_Architecture_Benchmark_Report.pdf (48 KB · 14 pages)"
            case .safariArticle: "Apple Silicon Unified Memory Scaling — Engineering Blog"
            case .youtubeTranscript: "Systems Design Lecture: Local-First AI Agents (42:18)"
            }
        }

        var takeaways: [String] {
            switch self {
            case .pdfReport:
                return [
                    "The team will review the first release together on Thursday at 2:30 PM.",
                    "Maya will bring the updated planning and benchmark notes to the review.",
                    "Release checklist requires sign-off on Friday before 4:00 PM PST."
                ]
            case .safariArticle:
                return [
                    "Zero-copy unified memory allows simultaneous vision encoding and token streaming.",
                    "Non-activating NSPanel HUDs preserve key focus in Mail, Slack, and Xcode.",
                    "64 KB context window comfortably fits full technical RFCs and long thread archives."
                ]
            case .youtubeTranscript:
                return [
                    "Multi-agent separation (Planner → Navigator → Executor → Verifier) prevents stray clicks.",
                    "Human-in-the-loop review gates sensitive state changes before execution.",
                    "Local Markdown vaults keep knowledge inspectable, portable, and grep-friendly."
                ]
            }
        }

        var citations: [String] {
            switch self {
            case .pdfReport:
                return ["§2.1 Agenda (p. 4)", "§3.4 Benchmarks (p. 9)", "§5.0 Release Gate (p. 13)"]
            case .safariArticle:
                return ["¶3 Unified Memory", "¶7 Non-Activating HUD", "¶11 Context Budget"]
            case .youtubeTranscript:
                return ["04:12 Agent Loop", "18:45 Review Gates", "31:10 Markdown Graph"]
            }
        }
    }

    enum ProofreadToneMode: String, CaseIterable, Identifiable {
        case grammarOnly = "Fix Typos"
        case crisp = "Crisp Executive"
        case friendly = "Friendly Slack"

        var id: String { rawValue }

        var polishedOutput: String {
            switch self {
            case .grammarOnly:
                return "Hi team — I attached the Q4 benchmark numbers; please review them before Friday’s release."
            case .crisp:
                return "Team — Q4 benchmark metrics are attached. Please sign off ahead of Friday’s 4:00 PM release gate."
            case .friendly:
                return "Hey team! Attached the latest Q4 benchmark numbers — let me know if everything looks good for Friday’s release."
            }
        }
    }

    enum ConstellationNode: String, CaseIterable, Identifiable {
        case overview = "Vault Root"
        case mayaLin = "Maya Lin"
        case architectureReview = "Q4 Review"
        case benchmarkNotes = "Benchmark Notes"

        var id: String { rawValue }

        var shortTitle: String { rawValue }

        var domainLabel: String {
            switch self {
            case .overview: "ROOT"
            case .mayaLin: "PERSON"
            case .architectureReview: "PROJECT"
            case .benchmarkNotes: "NOTE"
            }
        }

        var filePath: String {
            switch self {
            case .overview: "Vault/index.md"
            case .mayaLin: "Vault/people/maya-lin.md"
            case .architectureReview: "Vault/projects/q4-review.md"
            case .benchmarkNotes: "Vault/topics/benchmarks.md"
            }
        }

        var tint: Color {
            switch self {
            case .overview: Color(red: 0.38, green: 0.72, blue: 1.00)
            case .mayaLin: Color(red: 0.22, green: 0.78, blue: 0.88)
            case .architectureReview: Color(red: 0.96, green: 0.68, blue: 0.28)
            case .benchmarkNotes: Color(red: 0.55, green: 0.58, blue: 0.98)
            }
        }

        var position: CGPoint {
            switch self {
            case .overview: CGPoint(x: 0.24, y: 0.26)
            case .mayaLin: CGPoint(x: 0.76, y: 0.26)
            case .architectureReview: CGPoint(x: 0.24, y: 0.74)
            case .benchmarkNotes: CGPoint(x: 0.76, y: 0.74)
            }
        }

        var markdownSnippet: String {
            switch self {
            case .overview:
                return """
                # Local Memory Vault
                - **38 plain-text Markdown notes** indexed locally on this Mac
                - Connected across `[[Maya Lin]]`, `[[Q4 Review]]`, and `[[Benchmark Notes]]`
                - Grounded in `writingstyle.md` (concise technical cadence)
                """
            case .mayaLin:
                return """
                # Maya Lin — Staff Systems Architect
                - **Cadence**: Prefers concise bullet points + benchmark diffs ahead of meetings
                - **Upcoming**: Thursday 2:30 PM `[[Q4 Review]]`
                - **Recent Thread**: Requested updated `[[Benchmark Notes]]` before Friday’s release
                """
            case .architectureReview:
                return """
                # Q4 Architecture Review
                - **Slot**: Thursday · 2:30 PM – 3:15 PM (Calendar hold verified)
                - **Attendees**: `[[Maya Lin]]`, Core Mac Runtime Team
                - **Agenda**: Sign off on `[[Benchmark Notes]]` & Friday release checklist
                """
            case .benchmarkNotes:
                return """
                # Benchmark Notes (Gemma 4 & Hybrid Vault)
                - **E2B / E4B TTFT**: 190 ms cold, 48 ms warm on Apple Silicon
                - **Memory Footprint**: 2.6 GB (E2B) / 4.5 GB (E4B)
                - **Referenced By**: `[[Maya Lin]]`, `[[Q4 Review]]`
                """
            }
        }

        var linkedNodes: [ConstellationNode] {
            switch self {
            case .overview: [.mayaLin, .architectureReview]
            case .mayaLin: [.architectureReview, .benchmarkNotes]
            case .architectureReview: [.mayaLin, .benchmarkNotes]
            case .benchmarkNotes: [.architectureReview, .mayaLin]
            }
        }
    }

    let store: AssistantStore
    @Bindable var coordinator: OnboardingCoordinator
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: Stage = .waitingForTrigger
    @State private var selectedAppContext: DemoAppContext = .appleMail
    @State private var selectedRemix: DraftRemixPreset = .standard
    @State private var revealedCharacters = 0
    @State private var exampleReply = DemoAppContext.appleMail.replyText(for: .standard)
    @State private var wrongSideHint = false
    @State private var selectedAction: SelectedNotchAction = .magicReply
    @State private var demoGesture = RightCommandDoubleTap()
    @State private var lastOrdinaryInputAt: TimeInterval = 0
    @State private var demoTask: Task<Void, Never>?
    @State private var eventMonitor: Any?
    @State private var swirlModel = OnboardingCaretSwirlModel()
    @State private var swirlVisible = false

    // Take Over simulator state
    @State private var takeOverStage: TakeOverStage = .awaitingReview
    @State private var takeOverTask: Task<Void, Never>?

    // Summarize simulator state
    @State private var selectedSummarySource: SummarySource = .pdfReport
    @State private var summaryRunning = false
    @State private var summaryRevealedCount = 3
    @State private var checkedSummaryRows: Set<Int> = [0]
    @State private var summarySavedToVault = false
    @State private var summaryCopied = false
    @State private var summaryTask: Task<Void, Never>?

    // Proofread simulator state
    @State private var isProofreadPolished = true
    @State private var showInlineDiff = true
    @State private var proofreadTone: ProofreadToneMode = .grammarOnly

    // Memory Graph & Morning Brief sheet state
    @State private var selectedConstellationNode: ConstellationNode = .mayaLin
    @State private var checkedBriefItems: Set<Int> = [0]
    @State private var showConstellationBriefSheet = false

    private static let proofreadOriginalText = "Hey team — i attached teh Q4 benchmrk numbers, plz review before friday release."

    private var activeSampleDraft: String {
        selectedAppContext.replyText(for: selectedRemix)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Fictional practice · no apps are changed", systemImage: "info.circle")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
            MagicReplyPracticeCard(
                shortcutTitle: store.focusedDraft.shortcutKey.title,
                senderName: selectedAppContext.senderName,
                incomingText: selectedAppContext.incomingText,
                selectedApp: selectedAppContext.rawValue,
                appChoices: DemoAppContext.allCases.map(\.rawValue),
                selectedTone: selectedRemix.rawValue,
                toneChoices: DraftRemixPreset.allCases.map(\.rawValue),
                stage: stage,
                reply: String(exampleReply.prefix(revealedCharacters)),
                onSelectApp: { raw in
                    guard let app = DemoAppContext(rawValue: raw) else { return }
                    selectedAppContext = app
                    resetDemo()
                },
                onSelectTone: { raw in
                    guard let tone = DraftRemixPreset(rawValue: raw) else { return }
                    selectedRemix = tone
                    triggerDemo()
                },
                onTry: triggerDemo,
                onReset: resetDemo
            )
            DisclosureGroup("Other Relay actions & previews") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Practice action", selection: $selectedAction) {
                        ForEach(SelectedNotchAction.allCases) { action in
                            Text(action == .magicReply ? "Magic Reply" : action.rawValue).tag(action)
                        }
                    }
                    .pickerStyle(.segmented)
                    if selectedAction != .magicReply {
                        activeWorkflowSimulatorCard
                            .environment(\.colorScheme, .dark)
                            .background(NotchVisualTokens.solidFallbackFill)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    RelayChipFlow(spacing: 8, alignment: .leading) {
                        Button("Memory Graph & Brief…") { showConstellationBriefSheet = true }
                        Button("Preview Command Bar") {
                            coordinator.notchQuickAccessExplored = true
                            NotchOverlayController.shared.previewFromOnboarding(store: store)
                        }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                }
                .padding(.top, 10)
            }
            if wrongSideHint {
                Label("Use \(store.focusedDraft.shortcutKey.title) on the right of the Spacebar.", systemImage: "keyboard")
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.warning)
            }
        }
        .sheet(isPresented: $showConstellationBriefSheet) { memoryGraphAndMorningBriefSheet }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - 1. Unified Relay Command Bar Header & 4-Mode Switcher

    private var relayCommandHeaderBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                RelayActivityMark(
                    size: 14,
                    fast: stage == .drafting || summaryRunning || takeOverStage == .planner || takeOverStage == .navigator
                )
                Text("RELAY HUD")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: true, vertical: false)

                Button(action: triggerDemo) {
                    HStack(spacing: 5) {
                        Text("⌘")
                            .font(.system(size: 11, weight: .bold))
                        Text("\(store.focusedDraft.shortcutKey.title) × 2")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.96))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.32, green: 0.39, blue: 0.92).opacity(0.55),
                                Color(red: 0.12, green: 0.58, blue: 0.88).opacity(0.42)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.65), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Click to trigger \(store.focusedDraft.shortcutKey.title) × 2 Instant Draft")
            }

            Spacer(minLength: 10)

            HStack(spacing: 4) {
                ForEach(SelectedNotchAction.allCases) { item in
                    let isSelected = selectedAction == item
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedAction = item
                            coordinator.notchQuickAccessExplored = true
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(
                                    isSelected
                                        ? Color(red: 0.42, green: 0.75, blue: 1.0)
                                        : .white.opacity(0.55)
                                )
                            Text(item.rawValue)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.65))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
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
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.38), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Color.black.opacity(0.28))
    }

    // MARK: - 2. Active Workflow Simulator Body

    @ViewBuilder
    private var activeWorkflowSimulatorCard: some View {
        switch selectedAction {
        case .magicReply:
            instantDraftSandboxBody
        case .takeOver:
            takeOverSimulatorCard
        case .summarize:
            summarizeSimulatorCard
        case .proofread:
            proofreadSimulatorCard
        }
    }

    // MARK: - 2A. Interactive Multi-App Instant Draft Playground (.magicReply)

    private var statusBadge: some View {
        HStack(spacing: 6) {
            switch stage {
            case .waitingForTrigger:
                Image(systemName: "keyboard")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
                Text("Double-tap \(store.focusedDraft.shortcutKey.title) or click Run Draft")
            case .drafting:
                ProgressView().controlSize(.small)
                Text("Streaming reply in your voice…")
            case .drafted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11.5))
                Text("Unsent draft ready · Click any tone to remix")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(stage == .drafted ? RelayColors.accentEmerald : .white.opacity(0.78))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var instantDraftSandboxBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Interactive App Switcher + Sender Row (Apple Mail / Slack DM / iMessage)
            HStack(alignment: .top, spacing: 11) {
                Text(selectedAppContext.avatarInitials)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(selectedAppContext.avatarTint.opacity(0.38), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(selectedAppContext.senderName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text(selectedAppContext.threadContext)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.50))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        // Interactive App Context Switcher Pills
                        HStack(spacing: 4) {
                            ForEach(DemoAppContext.allCases) { app in
                                let isCurrentApp = selectedAppContext == app
                                Button {
                                    selectedAppContext = app
                                    triggerDemo()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: app.icon)
                                            .font(.system(size: 9, weight: .semibold))
                                        Text(app.rawValue)
                                            .font(.system(size: 10, weight: isCurrentApp ? .semibold : .medium))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(.white.opacity(isCurrentApp ? 0.98 : 0.60))
                                    .padding(.horizontal, 8)
                                    .frame(height: 21)
                                    .background(
                                        isCurrentApp ? selectedAppContext.avatarTint.opacity(0.28) : Color.white.opacity(0.05),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(
                                            isCurrentApp ? selectedAppContext.avatarTint.opacity(0.75) : Color.white.opacity(0.09),
                                            lineWidth: 0.75
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }

                    Text(selectedAppContext.incomingText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.80))
                        .lineSpacing(1.5)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // 2. Full-Width Reply Composer Box with Interactive Live Tone Remixer Pills
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(stage == .drafted ? RelayColors.accentEmerald : Color(red: 0.45, green: 0.72, blue: 1.0))
                    Text("Reply to \(selectedAppContext.senderName)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .fixedSize(horizontal: true, vertical: false)

                    if stage == .drafting {
                        RelayActivityMark(size: 12, fast: true)
                    }

                    // Interactive Live Tone Remixer Buttons!
                    HStack(spacing: 4) {
                        ForEach(DraftRemixPreset.allCases) { preset in
                            let isPicked = selectedRemix == preset
                            Button {
                                selectedRemix = preset
                                triggerDemo()
                            } label: {
                                HStack(spacing: 3.5) {
                                    Image(systemName: preset.icon)
                                        .font(.system(size: 8.5, weight: .semibold))
                                    Text(preset.rawValue)
                                        .font(.system(size: 9.5, weight: isPicked ? .semibold : .medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(
                                    isPicked
                                        ? Color(red: 0.48, green: 0.80, blue: 1.0)
                                        : .white.opacity(0.62)
                                )
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(
                                    isPicked ? RelayColors.accentBlue.opacity(0.24) : Color.white.opacity(0.045),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isPicked ? Color(red: 0.45, green: 0.75, blue: 1.0).opacity(0.65) : Color.white.opacity(0.09),
                                        lineWidth: 0.75
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.leading, 4)

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        ForEach(Array(selectedAppContext.sourcePills.prefix(2).enumerated()), id: \.offset) { _, pill in
                            sourceMicroPill(icon: pill.icon, label: pill.label)
                        }
                    }
                }

                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)

                    Text(activeSampleDraft)
                        .font(.system(size: 13))
                        .lineSpacing(2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .accessibilityHidden(true)

                    if stage == .waitingForTrigger {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color(red: 0.45, green: 0.72, blue: 1.0))
                                .frame(width: 2, height: 16)
                                .anchorPreference(key: MagicReplyCaretBoundsKey.self, value: .bounds) { $0 }
                            Text("Double-tap \(store.focusedDraft.shortcutKey.title) or click any tone pill above to live-stream an unsent reply…")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.46))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if stage == .drafted {
                        TextEditor(text: $exampleReply)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.95))
                            .scrollContentBackground(.hidden)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .accessibilityLabel("Example reply, not sent")
                    } else {
                        HStack(alignment: .top, spacing: 2) {
                            let visible = String(activeSampleDraft.prefix(revealedCharacters))
                            Text(visible)
                                .font(.system(size: 13))
                                .lineSpacing(2.5)
                                .foregroundStyle(.white.opacity(0.95))
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color(red: 0.45, green: 0.72, blue: 1.0))
                                .frame(width: 2, height: 16)
                                .anchorPreference(key: MagicReplyCaretBoundsKey.self, value: .bounds) { $0 }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.028), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        stage == .drafted
                            ? RelayColors.accentEmerald.opacity(0.42)
                            : (stage == .drafting ? Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.48) : Color.white.opacity(0.09)),
                        lineWidth: 1
                    )
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 11)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            // 3. Single-Line Aligned Bottom Action Toolbar
            HStack(spacing: 8) {
                statusBadge
                Spacer(minLength: 8)

                Button {
                    showConstellationBriefSheet = true
                } label: {
                    Label("Memory Graph & Brief…", systemImage: "point.3.connected.trianglepath.dotted")
                        .lineLimit(1)
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)

                Button("Preview Command Bar") {
                    coordinator.notchQuickAccessExplored = true
                    NotchOverlayController.shared.previewFromOnboarding(store: store)
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)

                Button(stage == .drafted ? "Replay Instant Draft" : "Run Instant Draft", action: triggerDemo)
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(stage == .drafting)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Color.black.opacity(0.22))
        }
        .overlayPreferenceValue(MagicReplyCaretBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if swirlVisible && !reduceMotion {
                    let caretRect = anchor.map { proxy[$0] }
                        ?? CGRect(x: proxy.size.width * 0.22, y: proxy.size.height * 0.56, width: 2, height: 16)
                    OnboardingCaretSwirlView(model: swirlModel)
                        .frame(width: 280, height: 280)
                        .position(x: caretRect.midX, y: caretRect.midY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func sourceMicroPill(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.white.opacity(0.76))
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75))
    }

    // MARK: - 2B. Interactive Visual Take Over & Live Calendar Simulator (.takeOver)

    private var takeOverSimulatorCard: some View {
        let stages: [TakeOverStage] = [.planner, .navigator, .awaitingReview, .verifier]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Left Column: Interactive Clickable Agent Pipeline Steps
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("CLICK ANY STEP OR SIMULATE")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        RelayBadge("⌘. Instant Stop", icon: "hand.raised.fill", tint: Color.white.opacity(0.72))
                    }

                    ForEach(stages, id: \.rawValue) { step in
                        let isReached = takeOverStage.rawValue >= step.rawValue
                        let isCurrent = takeOverStage == step
                        Button {
                            takeOverTask?.cancel()
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                                takeOverStage = step
                                coordinator.notchQuickAccessExplored = true
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isReached ? (isCurrent && step == .awaitingReview ? "hand.tap.fill" : "checkmark.circle.fill") : "circle.dotted")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(
                                        isCurrent && step == .awaitingReview
                                            ? RelayColors.accentAmber
                                            : (isReached ? RelayColors.accentEmerald : .white.opacity(0.38))
                                    )
                                    .frame(width: 14)

                                Text(step.shortStepTitle)
                                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(.white.opacity(isReached ? 0.95 : 0.60))
                                    .lineLimit(1)

                                Spacer(minLength: 4)

                                RelayRoleBadge(role: step.roleName)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 27)
                            .background(
                                isCurrent ? Color.white.opacity(0.09) : Color.white.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(
                                        isCurrent ? Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.55) : Color.white.opacity(0.07),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)

                // Right Column: Visual Interactive Calendar Window with Relay Agent Cursor
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RelayColors.accentCoral)
                        Text("Calendar.app · Thursday")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.90))
                        Spacer()
                        Text(takeOverStage == .verifier ? "INVITE STAGED" : "LIVE PREVIEW")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(takeOverStage == .verifier ? RelayColors.accentEmerald : Color(red: 0.45, green: 0.75, blue: 1.0))
                    }

                    Rectangle().fill(Color.white.opacity(0.065)).frame(height: 1)

                    // Visual Timeline Slots
                    VStack(spacing: 5) {
                        HStack(spacing: 8) {
                            Text("1:00 PM")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.40))
                                .frame(width: 48, alignment: .leading)
                            Text("Core Runtime Standup")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }

                        // Target 2:30 PM Slot where Relay places the event
                        HStack(spacing: 8) {
                            Text("2:30 PM")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                                .frame(width: 48, alignment: .leading)

                            Button {
                                approveTakeOverExecution()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: takeOverStage == .verifier ? "checkmark.circle.fill" : "cursorarrow.rays")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(takeOverStage == .verifier ? RelayColors.accentEmerald : Color(red: 0.45, green: 0.78, blue: 1.0))
                                    Text("Q4 Architecture Review · Maya Lin")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(takeOverStage == .verifier ? "Confirmed" : "Click to Approve")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(takeOverStage == .verifier ? RelayColors.accentEmerald : RelayColors.accentAmber)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .padding(.horizontal, 9)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .background(
                                    takeOverStage == .verifier
                                        ? RelayColors.accentEmerald.opacity(0.20)
                                        : RelayColors.accentBlue.opacity(0.24),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(
                                            takeOverStage == .verifier ? RelayColors.accentEmerald : Color(red: 0.45, green: 0.75, blue: 1.0),
                                            lineWidth: 1.2
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 8) {
                            Text("4:00 PM")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.40))
                                .frame(width: 48, alignment: .leading)
                            Text("Open Focus Block")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.38))
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
                .padding(10)
                .frame(width: 340)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            HStack(spacing: 10) {
                Text(
                    takeOverStage == .verifier
                        ? "Calendar hold staged at Thu 2:30 PM without auto-sending external invites"
                        : "Relay pauses at Step 3 for your 1-click confirmation before committing"
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(takeOverStage == .verifier ? RelayColors.accentEmerald : .white.opacity(0.68))
                .lineLimit(1)

                Spacer()

                Button {
                    startTakeOverSimulation()
                } label: {
                    Label("Replay Simulation", systemImage: "play.fill")
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                if takeOverStage != .verifier {
                    Button {
                        approveTakeOverExecution()
                    } label: {
                        Label("Approve & Commit", systemImage: "checkmark.shield.fill")
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Color.black.opacity(0.22))
        }
    }

    private func startTakeOverSimulation() {
        takeOverTask?.cancel()
        coordinator.notchQuickAccessExplored = true
        if reduceMotion {
            takeOverStage = .awaitingReview
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            takeOverStage = .planner
        }
        takeOverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                takeOverStage = .navigator
            }
            try? await Task.sleep(for: .milliseconds(460))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                takeOverStage = .awaitingReview
            }
        }
    }

    private func approveTakeOverExecution() {
        takeOverTask?.cancel()
        coordinator.notchQuickAccessExplored = true
        coordinator.magicReplyDemoCompleted = true
        withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
            takeOverStage = .verifier
        }
    }

    // MARK: - 2C. Interactive 64 KB Document & Media Summary HUD (.summarize)

    private var summarizeSimulatorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 8) {
                    Label("Interactive Summary HUD · Click takeaways to pin", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    Spacer()

                    HStack(spacing: 5) {
                        ForEach(SummarySource.allCases) { source in
                            let isSelected = selectedSummarySource == source
                            Button {
                                summaryTask?.cancel()
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    selectedSummarySource = source
                                    triggerSummaryDemo()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: source.icon)
                                        .font(.system(size: 9.5, weight: .semibold))
                                    Text(source.rawValue)
                                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                                }
                                .padding(.horizontal, 9)
                                .frame(height: 23)
                                .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.65))
                                .background(
                                    isSelected ? RelayColors.accentBlue.opacity(0.28) : Color.white.opacity(0.05),
                                    in: Capsule(style: .continuous)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(
                                            isSelected ? Color(red: 0.45, green: 0.75, blue: 1.0) : Color.white.opacity(0.09),
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    let items = Array(selectedSummarySource.takeaways.prefix(max(1, summaryRevealedCount)))
                    ForEach(Array(items.enumerated()), id: \.offset) { index, point in
                        let isPinned = checkedSummaryRows.contains(index)
                        let citation = selectedSummarySource.citations[min(index, selectedSummarySource.citations.count - 1)]
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isPinned {
                                    checkedSummaryRows.remove(index)
                                } else {
                                    checkedSummaryRows.insert(index)
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isPinned ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(isPinned ? RelayColors.accentEmerald : Color(red: 0.45, green: 0.72, blue: 1.0))

                                Text(point)
                                    .font(.system(size: 11.5, weight: isPinned ? .medium : .regular))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)

                                Spacer(minLength: 4)

                                sourceMicroPill(icon: "bookmark.fill", label: citation)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                isPinned ? RelayColors.accentEmerald.opacity(0.10) : Color.white.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(
                                        isPinned ? RelayColors.accentEmerald.opacity(0.35) : Color.white.opacity(0.07),
                                        lineWidth: 0.75
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            HStack(spacing: 8) {
                Text("\(checkedSummaryRows.count) of 3 takeaways pinned for Vault export")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        summarySavedToVault.toggle()
                        coordinator.notchQuickAccessExplored = true
                    }
                } label: {
                    Label(
                        summarySavedToVault ? "Saved to Vault" : "Save to Vault",
                        systemImage: summarySavedToVault ? "checkmark.circle.fill" : "folder.badge.plus"
                    )
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Button {
                    triggerSummaryDemo()
                } label: {
                    Label("Stream Summary (⌘⇧D)", systemImage: "sparkles")
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(summaryRunning)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Color.black.opacity(0.22))
        }
    }

    private func triggerSummaryDemo() {
        summaryTask?.cancel()
        coordinator.notchQuickAccessExplored = true
        coordinator.magicReplyDemoCompleted = true
        summarySavedToVault = false
        summaryCopied = false
        if reduceMotion {
            summaryRevealedCount = selectedSummarySource.takeaways.count
            summaryRunning = false
            return
        }
        summaryRunning = true
        summaryRevealedCount = 1
        summaryTask = Task { @MainActor in
            for count in 1...selectedSummarySource.takeaways.count {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    summaryRevealedCount = count
                }
            }
            summaryRunning = false
        }
    }

    // MARK: - 2D. Interactive Visual Diff & Tone Proofreader (.proofread)

    private var proofreadSimulatorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 8) {
                    Label("In-Place Proofread & Visual Diff", systemImage: "text.badge.checkmark")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))

                    Spacer()

                    // Interactive Style Presets
                    HStack(spacing: 4) {
                        ForEach(ProofreadToneMode.allCases) { mode in
                            let isPicked = proofreadTone == mode && isProofreadPolished
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    proofreadTone = mode
                                    isProofreadPolished = true
                                    coordinator.notchQuickAccessExplored = true
                                    coordinator.magicReplyDemoCompleted = true
                                }
                            } label: {
                                Text(mode.rawValue)
                                    .font(.system(size: 10, weight: isPicked ? .semibold : .medium))
                                    .foregroundStyle(.white.opacity(isPicked ? 0.98 : 0.62))
                                    .padding(.horizontal, 8.5)
                                    .frame(height: 22)
                                    .background(
                                        isPicked ? RelayColors.accentEmerald.opacity(0.24) : Color.white.opacity(0.05),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(
                                            isPicked ? RelayColors.accentEmerald.opacity(0.70) : Color.white.opacity(0.09),
                                            lineWidth: 0.75
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    if showInlineDiff && isProofreadPolished {
                        // Visual Inline Diff Card showing exact strikethrough typos + emerald corrections
                        HStack(spacing: 6) {
                            diffToken(old: "i", new: "I")
                            Text("attached")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.88))
                            diffToken(old: "teh", new: "the")
                            Text("Q4")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.88))
                            diffToken(old: "benchmrk", new: "benchmark")
                            Text("numbers;")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.88))
                            diffToken(old: "plz", new: "please")
                            Text("review before")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.88))
                            diffToken(old: "friday", new: "Friday’s")
                            Text("release.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.88))
                            Spacer(minLength: 0)
                        }
                    } else {
                        Text(isProofreadPolished ? proofreadTone.polishedOutput : Self.proofreadOriginalText)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.94))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isProofreadPolished ? RelayColors.accentEmerald.opacity(0.45) : Color.white.opacity(0.09),
                            lineWidth: 1
                        )
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            HStack(spacing: 8) {
                Text(
                    isProofreadPolished
                        ? "5 grammar fixes applied in place · Clipboard untouched"
                        : "Showing original unedited draft (restored via 1-step ⌘Z)"
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isProofreadPolished ? RelayColors.accentEmerald : .white.opacity(0.68))
                .lineLimit(1)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showInlineDiff.toggle()
                        isProofreadPolished = true
                    }
                } label: {
                    Label(showInlineDiff ? "Clean View" : "Show Diff", systemImage: "eye")
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isProofreadPolished.toggle()
                        coordinator.notchQuickAccessExplored = true
                    }
                } label: {
                    Label(
                        isProofreadPolished ? "Test ⌘Z Undo" : "Apply Polish",
                        systemImage: isProofreadPolished ? "arrow.uturn.backward" : "checkmark.circle.fill"
                    )
                }
                .buttonStyle(RelayPrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Color.black.opacity(0.22))
        }
    }

    private func diffToken(old: String, new: String) -> some View {
        HStack(spacing: 3) {
            Text(old)
                .font(.system(size: 11.5, design: .monospaced))
                .strikethrough()
                .foregroundStyle(RelayColors.accentCoral.opacity(0.85))
            Text(new)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RelayColors.accentEmerald)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(RelayColors.accentEmerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - 3. Collision-Free Memory Graph & Morning Brief Modal Sheet

    private var memoryGraphAndMorningBriefSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.38, green: 0.72, blue: 1.0))
                        .frame(width: 6.5, height: 6.5)
                    Text("LOCAL MEMORY GRAPH & MORNING BRIEF")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Color(red: 0.48, green: 0.75, blue: 1.0))
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    coordinator.notchQuickAccessExplored = true
                    NotchOverlayController.shared.previewFromOnboarding(store: store)
                } label: {
                    Label("Preview Command Bar", systemImage: "menubar.dock.rectangle")
                        .lineLimit(1)
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)

                Button("Done") {
                    showConstellationBriefSheet = false
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
            }

            Text("Select any node to inspect its local Markdown note and backlinks, or review your daily Morning Brief.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            HStack(alignment: .top, spacing: 14) {
                constellationInteractivePane
                morningBriefInteractivePane
            }
            .frame(height: 368)
        }
        .padding(20)
        .frame(width: 840)
        .background(Color(red: 0.04, green: 0.043, blue: 0.056))
        .relayPreferredAppearance()
    }

    private var constellationInteractivePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Local Memory Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Spacer()
                Text(selectedConstellationNode.filePath)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }
            .frame(height: 20)

            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    Canvas { context, canvasSize in
                        let pulsePhase: CGFloat = 0.52

                        let specks: [(CGFloat, CGFloat, CGFloat, Double)] = [
                            (0.08, 0.14, 1.4, 0.18), (0.50, 0.14, 1.3, 0.15),
                            (0.92, 0.14, 1.4, 0.18), (0.50, 0.50, 1.4, 0.14),
                            (0.08, 0.86, 1.3, 0.16), (0.50, 0.86, 1.4, 0.16),
                            (0.92, 0.86, 1.3, 0.16)
                        ]
                        for (sx, sy, sr, sa) in specks {
                            let r = CGRect(x: sx * canvasSize.width, y: sy * canvasSize.height, width: sr, height: sr)
                            context.fill(Path(ellipseIn: r), with: .color(.white.opacity(sa)))
                        }

                        let edges: [(ConstellationNode, ConstellationNode)] = [
                            (.overview, .mayaLin),
                            (.overview, .architectureReview),
                            (.mayaLin, .architectureReview),
                            (.mayaLin, .benchmarkNotes),
                            (.architectureReview, .benchmarkNotes)
                        ]
                        for (from, to) in edges {
                            let p1 = CGPoint(x: from.position.x * canvasSize.width, y: from.position.y * canvasSize.height)
                            let p2 = CGPoint(x: to.position.x * canvasSize.width, y: to.position.y * canvasSize.height)
                            var path = Path()
                            path.move(to: p1)
                            path.addLine(to: p2)
                            let isHighlighted = selectedConstellationNode == from || selectedConstellationNode == to
                            if isHighlighted {
                                let shading = GraphicsContext.Shading.linearGradient(
                                    Gradient(colors: [
                                        from.tint.opacity(0.88),
                                        to.tint.opacity(0.88)
                                    ]),
                                    startPoint: p1,
                                    endPoint: p2
                                )
                                var glow = context
                                glow.opacity = 0.24
                                glow.stroke(path, with: shading, lineWidth: 3.6)
                                context.stroke(path, with: shading, lineWidth: 1.4)

                                let startPt = (selectedConstellationNode == from) ? p1 : p2
                                let endPt = (selectedConstellationNode == from) ? p2 : p1
                                let px = startPt.x + (endPt.x - startPt.x) * pulsePhase
                                let py = startPt.y + (endPt.y - startPt.y) * pulsePhase
                                let dotRect = CGRect(x: px - 2.5, y: py - 2.5, width: 5, height: 5)
                                context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.92)))
                            } else {
                                context.stroke(path, with: .color(.white.opacity(0.13)), lineWidth: 0.9)
                            }
                        }
                    }

                    ForEach(ConstellationNode.allCases) { node in
                        constellationNodeButton(node: node, in: size)
                    }
                }
            }
            .frame(height: 152)
            .background(Color(red: 0.022, green: 0.025, blue: 0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                Text(selectedConstellationNode.markdownSnippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

            Spacer(minLength: 0)

            // Interactive Clickable Wikilink Row (Clicking any pill navigates to that node!)
            HStack(spacing: 6) {
                Text("JUMP TO LINK")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: true, vertical: false)

                ForEach(selectedConstellationNode.linkedNodes) { targetNode in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            selectedConstellationNode = targetNode
                        }
                    } label: {
                        Text("[[\(targetNode.shortTitle)]]")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(targetNode.tint)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(targetNode.tint.opacity(0.15), in: Capsule())
                            .overlay(Capsule().strokeBorder(targetNode.tint.opacity(0.38), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 28)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }

    private func constellationNodeButton(node: ConstellationNode, in size: CGSize) -> some View {
        let isSelected = selectedConstellationNode == node

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                selectedConstellationNode = node
            }
        } label: {
            HStack(spacing: 5.5) {
                Circle()
                    .fill(node.tint)
                    .frame(width: 6, height: 6)
                    .shadow(color: node.tint.opacity(0.8), radius: 3)

                Text(node.domainLabel)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(node.tint)

                Text("·")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.32))

                Text(node.shortTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.82))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9.5)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(red: 0.055, green: 0.060, blue: 0.080))
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(node.tint.opacity(isSelected ? 0.18 : 0.06))
                    }
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? node.tint.opacity(0.88) : Color.white.opacity(0.18),
                        lineWidth: isSelected ? 1.2 : 1
                    )
            )
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .shadow(color: .black.opacity(0.55), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .position(x: node.position.x * size.width, y: node.position.y * size.height)
    }

    private var morningBriefInteractivePane: some View {
        let briefTasks: [(kicker: String, title: String, accent: Color)] = [
            ("FOLLOW-UP · DRAFT READY", "Reply to Maya Lin re: Thursday 2:30 PM review", RelayColors.accentEmerald),
            ("BENCHMARK · GEMMA 4 E4B", "Attach Q4 Gemma 4 E4B benchmark latency table", RelayColors.accentAmber),
            ("RELEASE GATE · FRIDAY 4 PM", "Review Friday 4:00 PM release checklist sign-off items", Color(red: 0.38, green: 0.72, blue: 1.0))
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Morning Brief Daily Card", systemImage: "sun.horizon.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Spacer()
                Text("9:00 AM · PROACTIVE")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(RelayColors.accentAmber)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(RelayColors.accentAmber.opacity(0.14), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text("3 Priority Follow-Ups & Architecture Review Prep")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text("Synthesized locally from Calendar, Mail, and 3 Memory Vault notes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(briefTasks.enumerated()), id: \.offset) { index, item in
                    let isDone = checkedBriefItems.contains(index)
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            if isDone {
                                checkedBriefItems.remove(index)
                            } else {
                                checkedBriefItems.insert(index)
                            }
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isDone ? RelayColors.accentEmerald : item.accent)
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.kicker)
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundStyle(isDone ? .white.opacity(0.38) : item.accent)
                                Text(item.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .strikethrough(isDone)
                                    .foregroundStyle(isDone ? .white.opacity(0.42) : .white.opacity(0.90))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    isDone ? Color.white.opacity(0.06) : item.accent.opacity(0.28),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    showConstellationBriefSheet = false
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedAction = .magicReply
                        triggerDemo()
                    }
                } label: {
                    Label("Run Instant Draft", systemImage: "sparkles")
                        .lineLimit(1)
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    coordinator.notchQuickAccessExplored = true
                    NotchOverlayController.shared.previewFromOnboarding(store: store)
                } label: {
                    Label("Preview Command Bar", systemImage: "menubar.dock.rectangle")
                        .lineLimit(1)
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
            }
            .frame(height: 28)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }

    // MARK: - Choreography & Local Key Monitor

    private func triggerDemo() {
        demoTask?.cancel()
        wrongSideHint = false
        selectedAction = .magicReply
        stage = .drafting
        revealedCharacters = 0
        let targetText = activeSampleDraft
        exampleReply = targetText

        if reduceMotion {
            swirlVisible = false
            swirlModel.reset()
            revealedCharacters = targetText.count
            stage = .drafted
            coordinator.magicReplyDemoCompleted = true
            return
        }

        swirlModel.begin(orbit: 16, initialRadius: 108)
        swirlVisible = true

        demoTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }

            swirlModel.transitionToLanding()
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }

            let total = targetText.count
            let chunk = 7
            var count = 0
            while count < total {
                guard !Task.isCancelled else { return }
                count = min(total, count + chunk)
                revealedCharacters = count
                try? await Task.sleep(for: .milliseconds(15))
            }
            guard !Task.isCancelled else { return }
            stage = .drafted
            coordinator.magicReplyDemoCompleted = true

            try? await Task.sleep(for: .milliseconds(340))
            guard !Task.isCancelled else { return }
            swirlVisible = false
            swirlModel.reset()
        }
    }

    private func resetDemo() {
        demoTask?.cancel()
        swirlVisible = false
        swirlModel.reset()
        stage = .waitingForTrigger
        revealedCharacters = 0
        wrongSideHint = false
        demoGesture = RightCommandDoubleTap()
    }

    private func installKeyMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { event in
            if event.type == .flagsChanged {
                handleFlagsChanged(event)
            } else {
                lastOrdinaryInputAt = ProcessInfo.processInfo.systemUptime
                demoGesture = RightCommandDoubleTap()
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        demoTask?.cancel()
        takeOverTask?.cancel()
        summaryTask?.cancel()
        swirlVisible = false
        swirlModel.reset()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    static let relevantModifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static func normalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(relevantModifierMask)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard selectedAction == .magicReply else { return }
        let key = store.focusedDraft.shortcutKey
        let flags = Self.normalizedModifierFlags(event.modifierFlags)
        let now = ProcessInfo.processInfo.systemUptime
        if event.keyCode == (key == .rightCommand ? 55 : 58), flags == key.flag {
            wrongSideHint = true
        }
        let isSelectedKey = event.keyCode == key.keyCode
        let down = flags.contains(key.flag)
        let triggered = demoGesture.consume(
            rightCommand: isSelectedKey,
            commandOnly: down ? flags == key.flag : flags.isEmpty,
            down: down,
            at: now,
            secondsSinceOrdinaryInput: now - lastOrdinaryInputAt
        )
        if triggered { triggerDemo() }
    }
}

/// Store-free presentation shared by onboarding and public, fictional demo renders.
/// This view has no account, source, disk, network, or task-execution dependencies.
struct MagicReplyPracticeCard: View {
    let shortcutTitle: String
    let senderName: String
    let incomingText: String
    let selectedApp: String
    let appChoices: [String]
    let selectedTone: String
    let toneChoices: [String]
    let stage: OnboardingMagicReplyDemoView.Stage
    let reply: String
    let onSelectApp: (String) -> Void
    let onSelectTone: (String) -> Void
    let onTry: () -> Void
    let onReset: () -> Void

    var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Magic Reply", systemImage: "sparkles")
                        .font(RelayPageStyle.sectionTitle)
                    Spacer()
                    Button("\(shortcutTitle) × 2", action: onTry)
                        .buttonStyle(RelayGhostButtonStyle())
                        .accessibilityLabel("Practice the Magic Reply shortcut")
                }
                HStack {
                    Text("From \(senderName)")
                        .font(RelayPageStyle.body.weight(.medium))
                    Spacer()
                    Menu(selectedApp) {
                        ForEach(appChoices, id: \.self) { app in
                            Button(app) { onSelectApp(app) }
                        }
                    }
                    .fixedSize()
                }
                Text(incomingText)
                    .font(RelayPageStyle.body)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text(stage == .drafted ? "Your unsent reply" : "Practice a reply")
                        .font(RelayPageStyle.sectionTitle)
                    Spacer()
                    Menu("Tone: \(selectedTone)") {
                        ForEach(toneChoices, id: \.self) { tone in
                            Button(tone) { onSelectTone(tone) }
                        }
                    }
                    .fixedSize()
                }
                Group {
                    if stage == .waitingForTrigger {
                        Text("Try Magic Reply below, or double-tap \(shortcutTitle).")
                            .foregroundStyle(RelayColors.textMuted)
                    } else {
                        Text(reply)
                            .foregroundStyle(RelayColors.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .font(RelayPageStyle.body)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if stage == .drafting {
                        ProgressView().controlSize(.small)
                        Text("Preparing fictional reply…").font(RelayPageStyle.caption)
                    } else if stage == .drafted {
                        Label("Ready for review · nothing sent", systemImage: "checkmark.circle")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.success)
                    }
                    Spacer()
                    if stage == .drafted {
                        Button("Reset example", action: onReset).buttonStyle(RelayGhostButtonStyle())
                    }
                    Button(stage == .drafted ? "Try again" : "Try Magic Reply", action: onTry)
                        .buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(stage == .drafting)
                        .accessibilityIdentifier("onboarding.magicReply.try")
                }
            }
            .padding(20)
            .relayPagePanel()
    }
}
