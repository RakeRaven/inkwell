import PencilKit

/// A recognised shape as the points PencilKit should draw through.
struct ShapeOutline {
    var points: [CGPoint]
    /// Straight edges with hard corners, as opposed to a smooth curve.
    var sharp: Bool

    var isLine: Bool { points.count == 2 }

    /// Follows the pencil after snapping: a line's end tracks it, other shapes scale about their centre.
    func adjusted(from anchor: CGPoint, to point: CGPoint) -> ShapeOutline {
        if isLine {
            return ShapeOutline(points: [points[0], ShapeRecognizer.snapped(point, from: points[0])], sharp: sharp)
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        let c = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
        let before = hypot(anchor.x - c.x, anchor.y - c.y)
        guard before > 1 else { return self }
        let scale = hypot(point.x - c.x, point.y - c.y) / before
        return ShapeOutline(points: points.map { CGPoint(x: c.x + ($0.x - c.x) * scale, y: c.y + ($0.y - c.y) * scale) }, sharp: sharp)
    }
}

/// Turns a freehand path into a clean line, polyline, polygon or ellipse.
enum ShapeRecognizer {
    static func outline(for raw: [CGPoint]) -> ShapeOutline? {
        guard raw.count > 4 else { return nil }
        let points = resample(raw, count: 96)
        let bounds = boundingBox(points)
        let size = max(bounds.width, bounds.height)
        guard size > 12, let first = points.first, let last = points.last else { return nil }
        let length = pathLength(points)
        let gap = distance(first, last)

        if gap < size * 0.2 {
            if roundness(points, in: bounds) < 0.08 {
                return ShapeOutline(points: ellipse(in: bounds, startingAt: first), sharp: false)
            }
            let corners = removeFlat(simplifyClosed(points, epsilon: size * 0.06), closed: true, minEdge: size * 0.08)
            switch corners.count {
            case 3:
                return ShapeOutline(points: corners + [corners[0]], sharp: true)
            case 4:
                let quad = rectangle(corners, bounds: bounds) ?? corners
                return ShapeOutline(points: quad + [quad[0]], sharp: true)
            case 5...8:
                return ShapeOutline(points: corners + [corners[0]], sharp: true)
            default:
                return roundness(points, in: bounds) < 0.15
                    ? ShapeOutline(points: ellipse(in: bounds, startingAt: first), sharp: false)
                    : nil
            }
        }

        if gap / max(length, 1) > 0.92 {
            return ShapeOutline(points: [first, snapped(last, from: first)], sharp: true)
        }
        let corners = removeFlat(rdp(points, epsilon: size * 0.06), closed: false, minEdge: size * 0.08)
        guard (3...5).contains(corners.count) else { return nil }
        return ShapeOutline(points: corners, sharp: true)
    }

    // Geometry

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Evenly spaced points along the path, so slow corners don't skew the shape.
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let step = pathLength(points) / CGFloat(count - 1)
        guard step > 0 else { return points }
        var result = [points[0]]
        var carried: CGFloat = 0
        var prev = points[0]
        for p in points.dropFirst() {
            var segment = distance(prev, p)
            var start = prev
            while carried + segment >= step {
                let t = (step - carried) / segment
                let q = CGPoint(x: start.x + (p.x - start.x) * t, y: start.y + (p.y - start.y) * t)
                result.append(q)
                segment = distance(q, p)
                start = q
                carried = 0
            }
            carried += segment
            prev = p
        }
        if result.count < count, let last = points.last { result.append(last) }
        return result
    }

    /// Spread of distances from the centre once the box is squashed square: low means ellipse.
    private static func roundness(_ points: [CGPoint], in bounds: CGRect) -> CGFloat {
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let radii = points.map { hypot(($0.x - bounds.midX) / w, ($0.y - bounds.midY) / h) }
        let mean = radii.reduce(0, +) / CGFloat(radii.count)
        guard mean > 0 else { return 1 }
        let variance = radii.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(radii.count)
        return variance.squareRoot() / mean
    }

    /// Ramer-Douglas-Peucker simplification of an open path.
    private static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2, let a = points.first, let b = points.last else { return points }
        var farthest = 0
        var maxDistance: CGFloat = 0
        for i in 1..<(points.count - 1) {
            let d = distanceToSegment(points[i], a, b)
            if d > maxDistance {
                maxDistance = d
                farthest = i
            }
        }
        guard maxDistance > epsilon else { return [a, b] }
        let left = rdp(Array(points[...farthest]), epsilon: epsilon)
        let right = rdp(Array(points[farthest...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    /// Splits a closed loop at the point farthest from its start, simplifies both halves.
    private static func simplifyClosed(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard let start = points.first else { return points }
        let far = points.indices.max { distance(points[$0], start) < distance(points[$1], start) } ?? 0
        guard far > 0 else { return points }
        let a = rdp(Array(points[...far]), epsilon: epsilon)
        let b = rdp(Array(points[far...]) + [start], epsilon: epsilon)
        return Array(a.dropLast() + b.dropLast())
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Interior angle at `b` in degrees.
    private static func angle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let dot = v1.x * v2.x + v1.y * v2.y
        let lengths = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
        guard lengths > 0 else { return 180 }
        return acos(min(max(dot / lengths, -1), 1)) * 180 / .pi
    }

    /// Drops near-straight vertices and ones crowding a neighbour.
    private static func removeFlat(_ vertices: [CGPoint], closed: Bool, minEdge: CGFloat) -> [CGPoint] {
        var v = vertices
        var changed = true
        while changed, v.count > (closed ? 3 : 2) {
            changed = false
            let range = closed ? Array(v.indices) : Array(v.indices.dropFirst().dropLast())
            for i in range {
                let prev = v[(i - 1 + v.count) % v.count], next = v[(i + 1) % v.count]
                if angle(prev, v[i], next) > 155 || distance(prev, v[i]) < minEdge {
                    v.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return v
    }

    /// A true rectangle when all four corners are near right angles.
    private static func rectangle(_ q: [CGPoint], bounds: CGRect) -> [CGPoint]? {
        for i in 0..<4 where abs(angle(q[(i + 3) % 4], q[i], q[(i + 1) % 4]) - 90) > 18 {
            return nil
        }
        let tilt = atan2(q[1].y - q[0].y, q[1].x - q[0].x) * 180 / .pi
        let offAxis = abs(tilt.truncatingRemainder(dividingBy: 90))
        if min(offAxis, 90 - offAxis) < 8 {
            return [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                    CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
        }
        let center = CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
        let ux = (q[1].x - q[0].x + q[2].x - q[3].x) / 2, uy = (q[1].y - q[0].y + q[2].y - q[3].y) / 2
        let width = (distance(q[0], q[1]) + distance(q[3], q[2])) / 2
        let height = (distance(q[1], q[2]) + distance(q[0], q[3])) / 2
        let ul = hypot(ux, uy)
        guard ul > 0 else { return nil }
        let u = CGPoint(x: ux / ul, y: uy / ul)
        var n = CGPoint(x: -u.y, y: u.x)
        // keep the corner order the same way round as the drawing
        let drawn = (q[2].x - q[1].x) * n.x + (q[2].y - q[1].y) * n.y
        if drawn < 0 { n = CGPoint(x: -n.x, y: -n.y) }
        func corner(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: center.x + u.x * a * width / 2 + n.x * b * height / 2, y: center.y + u.y * a * width / 2 + n.y * b * height / 2)
        }
        return [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)]
    }

    private static func ellipse(in bounds: CGRect, startingAt start: CGPoint) -> [CGPoint] {
        var rx = bounds.width / 2, ry = bounds.height / 2
        if rx / max(ry, 1) > 0.88, rx / max(ry, 1) < 1.14 {
            rx = (rx + ry) / 2
            ry = rx
        }
        let begin = atan2(start.y - bounds.midY, start.x - bounds.midX)
        return (0...80).map { i in
            let t = begin + CGFloat(i) / 80 * 2 * .pi
            return CGPoint(x: bounds.midX + rx * cos(t), y: bounds.midY + ry * sin(t))
        }
    }

    /// Snaps near-horizontal and near-vertical lines straight.
    static func snapped(_ end: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let degrees = abs(atan2(dy, dx) * 180 / .pi)
        if degrees < 6 || degrees > 174 { return CGPoint(x: end.x, y: start.y) }
        if abs(degrees - 90) < 6 { return CGPoint(x: start.x, y: end.y) }
        return end
    }

    // Stroke

    /// Styled like `template` when PencilKit kept the cut-short stroke, otherwise like the current pen.
    /// PencilKit draws a B-spline through control points; tripling a vertex keeps that corner sharp.
    static func stroke(_ outline: ShapeOutline, like template: PKStroke?, tool: PKTool) -> PKStroke? {
        let ink: PKInk
        let sample: PKStrokePoint
        if let template, !template.path.isEmpty {
            ink = template.ink
            sample = template.path[template.path.count / 2]
        } else if let pen = tool as? PKInkingTool {
            ink = PKInk(pen.inkType, color: pen.color)
            sample = PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: pen.width, height: pen.width),
                                   opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        } else {
            return nil
        }
        let control = outline.sharp ? outline.points.flatMap { [$0, $0, $0] } : outline.points
        let points = control.enumerated().map { i, location in
            PKStrokePoint(location: location, timeOffset: TimeInterval(i) * 0.01, size: sample.size,
                          opacity: sample.opacity, force: sample.force, azimuth: sample.azimuth, altitude: sample.altitude)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()), transform: .identity, mask: nil)
    }
}
