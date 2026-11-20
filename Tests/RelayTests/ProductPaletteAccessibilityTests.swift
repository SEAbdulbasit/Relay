import AppKit
import SwiftUI
import Testing
@testable import Relay

@Suite("Product palette readability")
@MainActor
struct ProductPaletteAccessibilityTests {
    @Test func supportingTextAndSemanticLabelsMeetNormalTextContrast() throws {
        for mode in [RelayAppearanceMode.light, .dark] {
            for background in [RelayColors.canvas, RelayColors.pitch, RelayColors.cardBG, RelayColors.surface, RelayColors.surfaceElevated] {
                for foreground in [RelayColors.textMuted, RelayColors.textDim, RelayColors.textFaint, RelayColors.success, RelayColors.warning, RelayColors.error, RelayColors.information, RelayColors.workbenchAccent] {
                    let ratio = try contrast(foreground, background, mode: mode)
                    #expect(ratio >= 4.5, "Normal text contrast must reach 4.5:1 in \(mode): \(ratio)")
                }
            }
        }
    }

    private func contrast(_ foreground: Color, _ background: Color, mode: RelayAppearanceMode) throws -> Double {
        func luminance(_ color: Color) throws -> Double {
            let rgb = try #require(RelayColors.resolvedNSColor(color, for: mode).usingColorSpace(.sRGB))
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let a = try luminance(foreground)
        let b = try luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
