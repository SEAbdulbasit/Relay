import Foundation

/// A trusted policy's positive context selection, never model arguments or a mutation permit.
/// The authorizer chooses this only after semantic/task-scope admission and any required review.
/// There is no negative mask, cursor heuristic, per-app exception or pixel tolerance.
nonisolated enum NativeVisualProofScope: Sendable, Equatable {
    case wholeFrame
    case contextRegions(imageID: UUID, observationID: UUID, regions: [Region])

    /// Coordinates are in the attached prepared image, matching the proposed pointer action.
    /// Regions should include the complete relevant controls and review context. The geometric
    /// margin below is only an additional floor; geometry never establishes semantic authority.
    struct Region: Sendable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    struct NativeRectangle: Sendable, Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        var area: Int { width * height }
    }
    enum Failure: Error, Equatable {
        case wrongImage, unsupportedAction, invalidRegion, insufficientContext, regionLimit
    }

    static let maximumRegions = 8
    static let minimumRegionEdge = 16.0
    static let minimumActionMargin = 32.0

    /// nil means unchanged whole-frame proof. Validation must finish before policy consumption
    /// or transport dispatch. Positive regions are immutable for this prepared image/action.
    func nativeRectangles(action: NativeControlSession.Action, frame: NativeVisionFrame?) throws -> [NativeRectangle]? {
        guard case .contextRegions(let imageID, let observationID, let regions) = self else { return nil }
        guard let frame, frame.id == imageID, frame.observationID == observationID else { throw Failure.wrongImage }
        guard !regions.isEmpty, regions.count <= Self.maximumRegions else { throw Failure.regionLimit }
        let start: NativeVisionFrame.PixelPoint, end: NativeVisionFrame.PixelPoint
        switch action {
        case .click(let actionImage, let point):
            guard actionImage == imageID else { throw Failure.wrongImage }
            start = point; end = point
        case .drag(let actionImage, let from, let to):
            guard actionImage == imageID else { throw Failure.wrongImage }
            start = from; end = to
        case .key, .typeUnsentText: throw Failure.unsupportedAction
        }
        let prepared = frame.preparedPixels, native = frame.nativePixels
        guard prepared.width > 0, prepared.height > 0, native.width > 0, native.height > 0,
              [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite),
              [start.x, end.x].allSatisfy({ $0 >= 0 && $0 < Double(prepared.width) }),
              [start.y, end.y].allSatisfy({ $0 >= 0 && $0 < Double(prepared.height) }) else { throw Failure.invalidRegion }
        // Each interval below proves that one positive rectangle contains the complete
        // margin square around every path point in that interval. Covering [0,1] with those
        // intervals proves the continuous swept corridor, not sampled points/endpoints only.
        var intervals: [ClosedRange<Double>] = [], area = 0
        var rectangles: [NativeRectangle] = []
        for region in regions {
            let right = region.x + region.width, bottom = region.y + region.height
            guard [region.x, region.y, region.width, region.height, right, bottom].allSatisfy(\.isFinite),
                  region.x >= 0, region.y >= 0,
                  region.width >= Self.minimumRegionEdge, region.height >= Self.minimumRegionEdge,
                  right <= Double(prepared.width), bottom <= Double(prepared.height) else { throw Failure.invalidRegion }
            if let interval = Self.coveredPathInterval(region: region, right: right, bottom: bottom,
                                                       start: start, end: end, width: prepared.width, height: prepared.height) {
                intervals.append(interval)
            }
            let xScale = Double(native.width) / Double(prepared.width)
            let yScale = Double(native.height) / Double(prepared.height)
            // Bounds were already checked in the source plane. min only absorbs floating-point
            // roundoff at the exact image edge; out-of-bounds source regions are never clamped.
            let left = Int((region.x * xScale).rounded(.down))
            let top = Int((region.y * yScale).rounded(.down))
            let endX = min(native.width, Int((right * xScale).rounded(.up)))
            let endY = min(native.height, Int((bottom * yScale).rounded(.up)))
            let rectangle = NativeRectangle(x: left, y: top, width: endX - left, height: endY - top)
            guard rectangle.width > 0, rectangle.height > 0,
                  !rectangles.contains(rectangle) else { throw Failure.invalidRegion }
            area += rectangle.area
            guard area <= native.width * native.height else { throw Failure.regionLimit }
            rectangles.append(rectangle)
        }
        var covered = 0.0
        for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard interval.lowerBound <= covered else { throw Failure.insufficientContext }
            covered = max(covered, interval.upperBound)
            if covered >= 1 { return rectangles }
        }
        throw Failure.insufficientContext
    }

    private static func coveredPathInterval(region: Region, right: Double, bottom: Double,
                                             start: NativeVisionFrame.PixelPoint, end: NativeVisionFrame.PixelPoint,
                                             width: Int, height: Int) -> ClosedRange<Double>? {
        // The entire available context is required at an image edge. Pixels outside the
        // image cannot be demanded, but source regions outside the image were rejected above.
        let left = region.x == 0 ? 0 : region.x + minimumActionMargin
        let top = region.y == 0 ? 0 : region.y + minimumActionMargin
        let maxX = right == Double(width) ? Double(width) : right - minimumActionMargin
        let maxY = bottom == Double(height) ? Double(height) : bottom - minimumActionMargin
        guard let x = parameterInterval(start: start.x, end: end.x, lower: left, upper: maxX),
              let y = parameterInterval(start: start.y, end: end.y, lower: top, upper: maxY) else { return nil }
        let low = max(x.lowerBound, y.lowerBound), high = min(x.upperBound, y.upperBound)
        return low <= high ? low...high : nil
    }

    private static func parameterInterval(start: Double, end: Double, lower: Double, upper: Double) -> ClosedRange<Double>? {
        guard lower <= upper else { return nil }
        let delta = end - start
        if delta == 0 { return (lower...upper).contains(start) ? 0...1 : nil }
        let first = (lower - start) / delta, second = (upper - start) / delta
        let low = max(0, min(first, second)), high = min(1, max(first, second))
        return low <= high ? low...high : nil
    }
}
