import SwiftUI

/// Static atmosphere stays at the window edge; conversation content has no
/// animated or high-contrast color behind it. Increased Contrast gets a flat canvas.
struct RelayWorkspaceBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                (isDark ? Color(red: 0.035, green: 0.043, blue: 0.055) : RelayColors.canvas)
                if contrast != .increased && !reduceTransparency {
                    ZStack(alignment: .topLeading) {
                        light(Color(red: 0.15, green: 0.38, blue: 0.70),
                              opacity: isDark ? 0.44 : 0.065,
                              width: min(520, geometry.size.width * 0.50))
                            .position(x: geometry.size.width * 0.10, y: -24)
                        light(Color(red: 0.66, green: 0.18, blue: 0.28),
                              opacity: isDark ? 0.32 : 0.045,
                              width: min(560, geometry.size.width * 0.48))
                            .position(x: geometry.size.width * 0.51, y: -48)
                        light(Color(red: 0.68, green: 0.48, blue: 0.21),
                              opacity: isDark ? 0.40 : 0.065,
                              width: min(640, geometry.size.width * 0.55))
                            .position(x: geometry.size.width * 0.91, y: -26)
                        Ellipse().fill(Color(red: 0.68, green: 0.48, blue: 0.21).opacity(isDark ? 0.10 : 0.025))
                            .frame(width: 300, height: 150).blur(radius: 48)
                            .position(x: geometry.size.width * 0.73, y: geometry.size.height + 48)
                    }
                    .clipped()
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func light(_ color: Color, opacity: Double, width: CGFloat) -> some View {
        Ellipse()
            .fill(color.opacity(opacity))
            .frame(width: width, height: 240)
            .blur(radius: 64)
    }
}

private struct RelayWorkspaceSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(RelayColors.cardBG)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(RelayColors.borderDefault, lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func relayWorkspaceSurface(cornerRadius: CGFloat = 18) -> some View {
        modifier(RelayWorkspaceSurface(cornerRadius: cornerRadius))
    }
}
