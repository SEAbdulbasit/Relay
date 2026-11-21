import SwiftUI

/// Light belongs to the edge of the workspace. The reading surface stays neutral,
/// and the atmosphere has no timer, interaction, or accessibility footprint.
struct RelayWorkspaceBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { scheme == .dark }
    private var canvas: Color { RelayColors.canvas }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                canvas
                if contrast != .increased && !reduceTransparency {
                    atmosphere(in: geometry.size)
                }
            }
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func atmosphere(in size: CGSize) -> some View {
        ZStack {
            // Relay uses one quiet teal field, shared with Settings and Knowledge.
            // The offset light is deliberately distinct from a multicolor crown.
            light(Color(red: 0.19, green: 0.47, blue: 0.42),
                  opacity: isDark ? 0.19 : 0.05,
                  width: min(1000, max(600, size.width * 0.8)),
                  height: 580, blur: 120)
                .rotationEffect(.degrees(-30))
                .position(x: size.width * -0.06, y: size.height * 0.18)
            light(Color(red: 0.24, green: 0.34, blue: 0.41),
                  opacity: isDark ? 0.09 : 0.025,
                  width: 760, height: 340, blur: 120)
                .position(x: size.width * 0.88, y: -120)
        }
    }

    private func light(_ color: Color, opacity: Double, width: CGFloat, height: CGFloat, blur: CGFloat) -> some View {
        Ellipse()
            .fill(color.opacity(opacity))
            .frame(width: width, height: height)
            .blur(radius: blur)
    }
}

private struct RelayWorkspaceSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var isDark: Bool { scheme == .dark }
    private var needsSolidSurface: Bool { reduceTransparency || contrast == .increased }
    private var solidFill: Color { RelayColors.cardBG }
    private var edge: Color {
        if contrast == .increased {
            return isDark ? .white.opacity(0.52) : .black.opacity(0.36)
        }
        return isDark ? .white.opacity(0.105) : .black.opacity(0.085)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if needsSolidSurface {
                    shape.fill(solidFill)
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(isDark ? .black.opacity(0.30) : .white.opacity(0.42)))
                }
            }
            .overlay {
                shape.strokeBorder(edge, lineWidth: contrast == .increased ? 1 : 0.65)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isDark ? 0.14 : 0.035), radius: 18, y: 7)
    }
}

private struct RelayWorkspaceSidebarSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency || contrast == .increased {
                scheme == .dark ? Color(white: 0.055) : Color(white: 0.975)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(scheme == .dark ? Color.black.opacity(0.36) : Color.white.opacity(0.48))
            }
        }
    }
}

extension View {
    func relayWorkspaceSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(RelayWorkspaceSurface(cornerRadius: cornerRadius))
    }

    /// Supplementary history shares the atmosphere instead of masking it with
    /// the opaque panel color used by document-oriented workspaces.
    func relayWorkspaceSidebarSurface() -> some View {
        modifier(RelayWorkspaceSidebarSurface())
    }
}
