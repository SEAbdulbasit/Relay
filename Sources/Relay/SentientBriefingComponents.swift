import SwiftUI

// MARK: - Reusable Paper & Step Plan Primitives (Zero Dummy Data)

/// Dog-eared rectangle missing its top-right triangle of side `fold`.
struct LetterPaper: Shape {
    var fold: CGFloat
    var radius: CGFloat = 14

    nonisolated func path(in r: CGRect) -> Path {
        let f = min(fold, min(r.width, r.height) * 0.35)
        let rad = min(radius, (min(r.width, r.height) - f) * 0.5)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + f))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addArc(center: CGPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addArc(center: CGPoint(x: r.minX + rad, y: r.minY + rad), radius: rad,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The folded-over triangle flap sitting at the top-right corner of `LetterPaper`.
struct LetterPaperFold: Shape {
    var fold: CGFloat

    nonisolated func path(in r: CGRect) -> Path {
        let f = min(fold, min(r.width, r.height) * 0.35)
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - f, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + f))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY + f))
        p.closeSubpath()
        return p
    }
}
