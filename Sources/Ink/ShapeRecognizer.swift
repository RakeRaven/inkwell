import PencilKit

/// A recognised shape as the points PencilKit should draw through.
struct ShapeOutline {
    var points: [CGPoint]
    /// Straight edges with hard corners, as opposed to a smooth curve.
    var sharp: Bool
    var closed = false
    /// Exact geometry when this is an ellipse; `points` holds it sampled.
    var ellipse: (center: CGPoint, radii: CGSize, angle: CGFloat)?

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
        var out = self
        out.points = points.map { CGPoint(x: c.x + ($0.x - c.x) * scale, y: c.y + ($0.y - c.y) * scale) }
        if let e = ellipse {
            out.ellipse = (CGPoint(x: c.x + (e.center.x - c.x) * scale, y: c.y + (e.center.y - c.y) * scale),
                           CGSize(width: e.radii.width * scale, height: e.radii.height * scale), e.angle)
        }
        return out
    }
}

/// Turns a freehand path into a clean line, polyline, polygon, rectangle or ellipse.
enum ShapeRecognizer {
    /// A possibly rotated box: the frame closed shapes are fitted in.
    private struct Frame {
        var center: CGPoint
        var width: CGFloat
        var height: CGFloat
        var angle: CGFloat

        func local(_ p: CGPoint) -> CGPoint {
            let dx = p.x - center.x, dy = p.y - center.y
            return CGPoint(x: dx * cos(angle) + dy * sin(angle), y: -dx * sin(angle) + dy * cos(angle))
        }

        func world(_ p: CGPoint) -> CGPoint {
            CGPoint(x: center.x + p.x * cos(angle) - p.y * sin(angle), y: center.y + p.x * sin(angle) + p.y * cos(angle))
        }

        var corners: [CGPoint] {
            let w = width / 2, h = height / 2
            return [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)].map(world)
        }
    }

    static func outline(for raw: [CGPoint]) -> ShapeOutline? {
        guard raw.count > 4 else { return nil }
        var points = resample(raw, count: 96)
        let bounds = boundingBox(points)
        let size = max(bounds.width, bounds.height)
        guard size > 12, let first = points.first else { return nil }

        // hand-drawn loops overshoot or fall short of the start; find where it comes back round
        let tail = Int(Double(points.count) * 0.6)..<points.count
        let back = tail.min { distance(points[$0], first) < distance(points[$1], first) } ?? points.count - 1
        if distance(points[back], first) < size * 0.3 {
            points = Array(points[...back])
            return closedOutline(resample(points, count: 96), size: size)
        }

        guard let last = points.last else { return nil }
        let length = pathLength(points)
        let gap = distance(first, last)

        if gap / max(length, 1) > 0.92 {
            return ShapeOutline(points: [first, snapped(last, from: first)], sharp: true)
        }
        let corners = removeFlat(rdp(points, epsilon: size * 0.06), closed: false, minEdge: size * 0.08)
        guard (3...5).contains(corners.count) else { return nil }
        return ShapeOutline(points: corners, sharp: true)
    }

    private static func closedOutline(_ points: [CGPoint], size: CGFloat) -> ShapeOutline? {
        guard let first = points.first else { return nil }
        let frame = tightestFrame(points)
        let ellipseError = ellipseFit(points, in: frame)
        let boxError = boxFit(points, in: frame)
        // a circle sits about 0.05 off its own bounding box anyway, so box fit alone can't tell them
        // apart; a loop is round when an ellipse fits it nearly as well as a box does
        let roundish = ellipseError < boxError * 2 && ellipseError < 0.14
        if sharpestTurn(points) < 55 || roundish {
            return ellipseOutline(frame, startingAt: first)
        }
        let corners = removeFlat(simplifyClosed(points, epsilon: size * 0.06), closed: true, minEdge: size * 0.1)
        // a box hugging the stroke beats a lumpy four-corner trace, so wonky squares come out square
        if boxError < 0.06 || (corners.count == 4 && boxError < 0.12) {
            let box = frame.corners
            return ShapeOutline(points: box + [box[0]], sharp: true, closed: true)
        }
        switch corners.count {
        case 3...8:
            return ShapeOutline(points: corners + [corners[0]], sharp: true, closed: true)
        default:
            return ellipseError < 0.18 ? ellipseOutline(frame, startingAt: first) : nil
        }
    }

    private static func ellipseOutline(_ frame: Frame, startingAt start: CGPoint) -> ShapeOutline {
        var rx = frame.width / 2, ry = frame.height / 2
        var angle = frame.angle
        if rx / max(ry, 1) > 0.8, rx / max(ry, 1) < 1.25 {
            rx = (rx + ry) / 2
            ry = rx
            angle = 0
        }
        return ShapeOutline(points: ellipse(in: frame, startingAt: start), sharp: false, closed: true,
                            ellipse: (frame.center, CGSize(width: rx, height: ry), angle))
    }

    /// Biggest change of direction over a short stretch of the loop, in degrees. The seam where
    /// the pen went down and lifted is skipped, since its hooks aren't corners.
    private static func sharpestTurn(_ points: [CGPoint]) -> CGFloat {
        let n = points.count
        let k = 4, seam = max(k, n / 14)
        guard n > seam * 2 + 4 else { return 180 }
        var worst: CGFloat = 0
        for i in seam..<(n - seam) {
            worst = max(worst, 180 - angle(points[i - k], points[i], points[i + k]))
        }
        return worst
    }

    // Fitting

    /// Smallest-area box around the points, tried every degree; near-upright boxes snap upright.
    private static func tightestFrame(_ points: [CGPoint]) -> Frame {
        var best = Frame(center: .zero, width: 0, height: 0, angle: 0)
        var bestArea = CGFloat.infinity
        for degree in 0..<90 {
            let a = CGFloat(degree) * .pi / 180
            let probe = Frame(center: .zero, width: 0, height: 0, angle: a)
            let local = points.map(probe.local)
            let box = boundingBox(local)
            let area = box.width * box.height
            if area < bestArea {
                bestArea = area
                best = Frame(center: probe.world(CGPoint(x: box.midX, y: box.midY)), width: box.width, height: box.height, angle: a)
            }
        }
        let degrees = best.angle * 180 / .pi
        if degrees < 8 || degrees > 82 {
            let box = boundingBox(points)
            best = Frame(center: CGPoint(x: box.midX, y: box.midY), width: box.width, height: box.height, angle: 0)
        }
        return best
    }

    /// Mean distance from the ellipse inscribed in the frame, relative to its size.
    private static func ellipseFit(_ points: [CGPoint], in frame: Frame) -> CGFloat {
        let rx = max(frame.width / 2, 1), ry = max(frame.height / 2, 1)
        let total = points.reduce(CGFloat(0)) { sum, p in
            let l = frame.local(p)
            return sum + abs(hypot(l.x / rx, l.y / ry) - 1)
        }
        return total / CGFloat(points.count)
    }

    /// Mean distance from the frame's edges, relative to its shorter side.
    private static func boxFit(_ points: [CGPoint], in frame: Frame) -> CGFloat {
        let w = frame.width / 2, h = frame.height / 2
        let side = max(min(frame.width, frame.height), 1)
        let total = points.reduce(CGFloat(0)) { sum, p in
            let l = frame.local(p)
            return sum + min(abs(w - abs(l.x)), abs(h - abs(l.y)))
        }
        return total / CGFloat(points.count) / side
    }

    private static func ellipse(in frame: Frame, startingAt start: CGPoint) -> [CGPoint] {
        var rx = frame.width / 2, ry = frame.height / 2
        var frame = frame
        if rx / max(ry, 1) > 0.8, rx / max(ry, 1) < 1.25 {
            rx = (rx + ry) / 2
            ry = rx
            frame.angle = 0
        }
        let s = frame.local(start)
        let begin = atan2(s.y / max(ry, 1), s.x / max(rx, 1))
        return (0...80).map { i in
            let t = begin + CGFloat(i) / 80 * 2 * .pi
            return frame.world(CGPoint(x: rx * cos(t), y: ry * sin(t)))
        }
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
                if angle(prev, v[i], next) > 150 || distance(prev, v[i]) < minEdge {
                    v.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return v
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
