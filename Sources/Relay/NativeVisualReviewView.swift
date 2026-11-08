import AppKit
import SwiftUI

/// Used by both workspace and Sidekick review. It never dispatches or approves.
struct NativeVisualReviewView: View {
    let presentation: NativeVisualReviewPresentation
    var maximumImageHeight: CGFloat = 220
    @State private var enlarged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.sourceLabel)
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if showsDetailsFirst { actionDetails }
            if let image = presentation.decodeImage() {
                markedImage(image)
                    .frame(maxHeight: maximumImageHeight)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RelayColors.borderDefault) }
                    .accessibilityHidden(false)
                    .accessibilityIdentifier("review.windowImage")
                    .accessibilityLabel(presentation.gestureLabel + " in " + presentation.sourceLabel)
                    .accessibilityHint(presentation.imageAccessibilityHint)
                Button("Enlarge image", systemImage: "arrow.up.left.and.arrow.down.right") { enlarged = true }
                    .buttonStyle(.link).font(.relayCaption)
                    .sheet(isPresented: $enlarged) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(presentation.sourceLabel).font(.relayHeadline)
                            ScrollView([.horizontal, .vertical]) {
                                markedImage(image)
                                    .frame(width: CGFloat(presentation.frame.preparedPixels.width),
                                           height: CGFloat(presentation.frame.preparedPixels.height))
                            }
                            HStack {
                                Text(presentation.gestureLabel).font(.relayBody)
                                Spacer()
                                Button("Close") { enlarged = false }.keyboardShortcut(.cancelAction)
                                    .buttonStyle(RelaySecondaryButtonStyle())
                            }
                        }
                        .padding(20).frame(minWidth: 560, idealWidth: 880, minHeight: 420, idealHeight: 620)
                        .background(RelayTheme.canvas)
                    }
            } else {
                Label("The review image is unavailable. Decline and inspect the window again.", systemImage: "photo.badge.exclamationmark")
                    .font(.relayCaption).foregroundStyle(RelayColors.accentCoral)
            }
            if !showsDetailsFirst { actionDetails }
            Text(presentation.intendedEffect).font(.relayBody)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var showsDetailsFirst: Bool {
        switch presentation.gesture {
        case .navigationKey, .unsentText: true
        case .click, .drag: false
        }
    }

    private var actionDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.gestureLabel).font(.relayBody.weight(.medium))
                .accessibilityIdentifier("review.gesture")
            if let target = presentation.focusedTargetDescription {
                Text(target).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("review.focusedTarget")
            }
            if let literal = presentation.literalText {
                Text(literal).font(.relayBody).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("review.literalText")
            }
            if case .drag = presentation.gesture {
                Text("Start at the solid dot and move to the ring.")
                    .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
            }
        }
    }

    private func markedImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            .overlay { GeometryReader { geometry in marks(in: geometry.size) } }
    }

    @ViewBuilder private func marks(in size: CGSize) -> some View {
        switch presentation.gesture {
        case .click(let point):
            if let location = location(point, size: size) { marker.position(location) }
        case .drag(let from, let to):
            if let start = location(from, size: size), let end = location(to, size: size) {
                let path = Path { path in path.move(to: start); path.addLine(to: end) }
                path.stroke(.black.opacity(0.85), style: .init(lineWidth: 6, lineCap: .round))
                path.stroke(.white, style: .init(lineWidth: 2, lineCap: .round))
                Circle().fill(.white).frame(width: 7, height: 7)
                    .overlay { Circle().strokeBorder(.black, lineWidth: 1) }.position(start)
                marker.position(end)
            }
        case .navigationKey, .unsentText:
            EmptyView()
        }
    }

    private var marker: some View {
        Circle().stroke(.black.opacity(0.9), lineWidth: 5)
            .overlay { Circle().stroke(.white, lineWidth: 2) }
            .overlay { Circle().fill(.white).frame(width: 3, height: 3) }
            .frame(width: 16, height: 16).accessibilityHidden(true)
    }

    private func location(_ point: NativeVisionFrame.PixelPoint, size: CGSize) -> CGPoint? {
        guard let scaled = try? presentation.displayedPoint(point, width: size.width, height: size.height) else { return nil }
        return CGPoint(x: scaled.x, y: scaled.y)
    }
}
