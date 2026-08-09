import CoreGraphics
import LaunchCore

/// Folder reorder geometry in the same row-major coordinate system as search mode.
///
/// A gap is the insertion position before slot `gap`; `itemCount` is therefore a
/// valid trailing gap as well.  The point mapping uses the geometric boundary
/// between adjacent logical slots instead of a nearest-item heuristic, so a
/// row transition is a first-class gap.
struct FolderDropGeometry: Equatable, Sendable {
    static let searchPadding: CGFloat = 24

    let geometry: GridGeometry
    let itemCount: Int
    let padding: CGFloat

    init(
        geometry: GridGeometry,
        itemCount: Int,
        padding: CGFloat = FolderDropGeometry.searchPadding
    ) {
        self.geometry = geometry
        self.itemCount = max(0, itemCount)
        self.padding = padding
    }

    /// The slot frame for an insertion gap.  The trailing gap deliberately
    /// asks GridGeometry for the next row/column slot, including a virtual slot.
    func frame(forGap gap: Int) -> CGRect? {
        guard itemCount > 0 else { return nil }
        let bounded = min(max(0, gap), itemCount)
        return geometry.searchFrame(
            forIndex: bounded,
            itemCount: itemCount,
            padding: padding
        )
    }

    /// Maps a document-coordinate point to a row-major insertion gap.
    func gap(for point: CGPoint) -> Int? {
        guard itemCount > 0 else { return nil }

        // The trailing virtual slot is an explicit visible drop target. Prefer it
        // over an equidistant prior-row boundary (common for counts 4/5/7/8).
        if let trailingFrame = frame(forGap: itemCount), trailingFrame.contains(point) {
            return itemCount
        }

        var bestGap = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for gap in 0...itemCount {
            guard let boundary = boundary(forGap: gap) else { continue }
            let distance = squaredDistance(from: point, to: boundary)
            // Strict comparison gives a deterministic lower-gap tie break.
            if distance < bestDistance {
                bestDistance = distance
                bestGap = gap
            }
        }
        return bestGap
    }

    /// Exposes a deterministic point on a gap boundary for unit tests.
    func boundaryPoint(forGap gap: Int) -> CGPoint? {
        guard let boundary = boundary(forGap: gap) else { return nil }
        return CGPoint(
            x: (boundary.start.x + boundary.end.x) / 2,
            y: (boundary.start.y + boundary.end.y) / 2
        )
    }

    private struct Segment {
        let start: CGPoint
        let end: CGPoint
    }

    private func boundary(forGap gap: Int) -> Segment? {
        guard itemCount > 0,
              let target = frame(forGap: gap) else {
            return nil
        }

        let bounded = min(max(0, gap), itemCount)
        if bounded == 0 {
            return Segment(
                start: CGPoint(x: target.minX, y: target.minY),
                end: CGPoint(x: target.minX, y: target.maxY)
            )
        }

        guard let previous = frame(forGap: bounded - 1) else { return nil }

        if previous.minY == target.minY {
            let x = (previous.maxX + target.minX) / 2
            return Segment(
                start: CGPoint(x: x, y: min(previous.minY, target.minY)),
                end: CGPoint(x: x, y: max(previous.maxY, target.maxY))
            )
        }

        // A row transition is one logical boundary across the whole grid row.
        // This makes gaps 3, 6, 9, ... reachable at the actual row boundary.
        let first = geometry.searchFrame(
            forIndex: 0,
            itemCount: itemCount,
            padding: padding
        )
        let y = (previous.maxY + target.minY) / 2
        return Segment(
            start: CGPoint(x: first.minX, y: y),
            end: CGPoint(x: first.minX + geometry.gridWidth, y: y)
        )
    }

    private func squaredDistance(from point: CGPoint, to segment: Segment) -> CGFloat {
        let dx = segment.end.x - segment.start.x
        let dy = segment.end.y - segment.start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            let px = point.x - segment.start.x
            let py = point.y - segment.start.y
            return px * px + py * py
        }

        let projection = ((point.x - segment.start.x) * dx
            + (point.y - segment.start.y) * dy) / lengthSquared
        let t = min(max(0, projection), 1)
        let closestX = segment.start.x + t * dx
        let closestY = segment.start.y + t * dy
        let distanceX = point.x - closestX
        let distanceY = point.y - closestY
        return distanceX * distanceX + distanceY * distanceY
    }
}
