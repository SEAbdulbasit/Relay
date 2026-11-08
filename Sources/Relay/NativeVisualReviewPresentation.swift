import Foundation
import CoreGraphics
import ImageIO

/// A temporary view of one proposed gesture. This is deliberately not Codable:
/// it carries no action capability and never belongs in chat, Activity or export.
nonisolated struct NativeVisualReviewPresentation: Sendable, Identifiable {
    /// Display facts only. The controller supplies these after qualifying the
    /// actual focused target; this value never substitutes for its input fences.
    struct FocusedTarget: Sendable, Equatable {
        struct Selection: Sendable, Equatable {
            let location: Int
            let length: Int
            let originalUTF16Count: Int

            init(location: Int, length: Int, originalUTF16Count: Int) throws {
                guard originalUTF16Count >= 0, originalUTF16Count <= 16_384,
                      location >= 0, length >= 0, location <= originalUTF16Count,
                      length <= originalUTF16Count - location else { throw Failure.invalidDescription }
                self.location = location; self.length = length; self.originalUTF16Count = originalUTF16Count
            }
        }
        let role: String
        let label: String?
        let identifier: String?
        let selection: Selection?

        init(role: String, label: String? = nil, identifier: String? = nil, selection: Selection? = nil) throws {
            func valid(_ value: String, maximum: Int) -> Bool {
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && value.utf8.count <= maximum && !value.contains("\0")
            }
            guard valid(role, maximum: 128), label.map({ valid($0, maximum: 1_024) }) ?? true,
                  identifier.map({ valid($0, maximum: 1_024) }) ?? true else { throw Failure.invalidDescription }
            self.role = role; self.label = label; self.identifier = identifier; self.selection = selection
        }

        var description: String {
            let kind: String = switch role {
            case "AXTextField": "Text field"
            case "AXTextArea": "Text area"
            case "AXButton": "Button"
            case "AXList": "List"
            case "AXTable": "Table"
            default: "Focused control"
            }
            var parts = [label ?? kind]
            if let selection {
                parts.append(selection.length == 0 ? "At the current cursor" : "Text is selected")
            }
            return parts.joined(separator: " · ")
        }
    }

    enum Gesture: Sendable, Equatable {
        case click(NativeVisionFrame.PixelPoint)
        case drag(from: NativeVisionFrame.PixelPoint, to: NativeVisionFrame.PixelPoint)
        case navigationKey(NativeControlKey, target: FocusedTarget)
        case unsentText(literal: String, target: FocusedTarget)
    }
    enum Failure: Error, Equatable { case invalidGeometry, invalidDescription, invalidImage }

    let id: UUID
    let taskID: UUID
    let taskRevision: Int
    let frame: NativeVisionFrame
    let gesture: Gesture
    let sourceLabel: String
    let intendedEffect: String
    let imageIsDecodable: Bool

    init(taskID: UUID, taskRevision: Int, frame: NativeVisionFrame, gesture: Gesture,
         sourceLabel: String, intendedEffect: String) throws {
        guard !sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !intendedEffect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceLabel.utf8.count <= 1_024, intendedEffect.utf8.count <= 4_096,
              !sourceLabel.contains("\0"), !intendedEffect.contains("\0") else {
            throw Failure.invalidDescription
        }
        let points: [NativeVisionFrame.PixelPoint]
        switch gesture {
        case .click(let point): points = [point]
        case .drag(let from, let to): points = [from, to]
        case .navigationKey: points = []
        case .unsentText(let literal, let target):
            guard ["AXTextField", "AXTextArea"].contains(target.role), target.selection != nil,
                  !literal.isEmpty, literal.utf8.count <= 4_096,
                  !literal.unicodeScalars.contains(where: {
                      $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029
                  }) else { throw Failure.invalidDescription }
            points = []
        }
        // The frame owns its prepared-image coordinate plane. Conversion validates
        // finite bounds; it does not grant permission to use the native point.
        do { for point in points { _ = try frame.nativePoint(fromPrepared: point) } }
        catch { throw Failure.invalidGeometry }
        guard Self.decodeImage(frame) != nil else { throw Failure.invalidImage }
        id = UUID(); self.taskID = taskID; self.taskRevision = taskRevision
        self.frame = frame; self.gesture = gesture
        self.sourceLabel = sourceLabel; self.intendedEffect = intendedEffect
        imageIsDecodable = true
    }

    var gestureLabel: String {
        switch gesture {
        case .click: "Click the marked point"
        case .drag: "Drag along the marked path"
        case .navigationKey(let key, _): "Press " + key.rawValue
        case .unsentText(_, let target):
            (target.selection?.length ?? 0) > 0 ? "Replace the selection without submitting" : "Insert this exact text without submitting"
        }
    }

    var focusedTargetDescription: String? {
        switch gesture {
        case .navigationKey(_, let target), .unsentText(_, let target): target.description
        case .click, .drag: nil
        }
    }

    var literalText: String? {
        if case .unsentText(let text, _) = gesture { text } else { nil }
    }

    var imageAccessibilityHint: String {
        switch gesture {
        case .click, .drag: "Current window image with the proposed gesture marked. Approval applies to this exact proposal."
        case .navigationKey, .unsentText: "Original window image for the focused control described below. Approval applies to this exact proposal."
        }
    }

    func decodeImage() -> CGImage? { Self.decodeImage(frame) }

    private static func decodeImage(_ frame: NativeVisionFrame) -> CGImage? {
        guard !frame.jpeg.isEmpty, frame.jpeg.count <= NativeVisionFrame.maximumPreparedBytes,
              frame.preparedPixels.width > 0, frame.preparedPixels.height > 0,
              frame.preparedPixels.width <= NativeVisionFrame.maximumPreparedEdge,
              frame.preparedPixels.height <= NativeVisionFrame.maximumPreparedEdge,
              let source = CGImageSourceCreateWithData(frame.jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), type as String == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == frame.preparedPixels.width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == frame.preparedPixels.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == frame.preparedPixels.width, image.height == frame.preparedPixels.height else { return nil }
        return image
    }

    /// Only the image is scaled to fit. Neither pointer data nor the source image
    /// is cropped, shifted or rewritten for presentation.
    func displayedPoint(_ point: NativeVisionFrame.PixelPoint, width: Double,
                        height: Double) throws -> NativeVisionFrame.PixelPoint {
        _ = try frame.nativePoint(fromPrepared: point)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw Failure.invalidGeometry
        }
        return .init(x: point.x * width / Double(frame.preparedPixels.width),
                     y: point.y * height / Double(frame.preparedPixels.height))
    }
}
