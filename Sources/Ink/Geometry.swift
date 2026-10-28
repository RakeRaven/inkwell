import UIKit

/// Page points to centimetres, taking A4 (820pt wide) as 21cm.
let cmPerPoint = 21.0 / 820.0

extension ShapeItem {
    var closed: Bool { kind == .polygon || kind == .ellipse }

    var center: CGPoint {
        switch kind {
        case .ellipse, .projectile:
            return points.first ?? .zero
        default:
            let b = bounds
            return CGPoint(x: b.midX, y: b.midY)
        }
    }

    /// Points the shape is drawn through; ellipses and trajectories sampled.
    var outline: [CGPoint] {
        switch kind {
        case .polygon:
            return points + (points.first.map { [$0] } ?? [])
        case .polyline, .line:
            return points
        case .ellipse:
            let c = center, r = radii ?? CGSize(width: 40, height: 40), a = CGFloat(rotation ?? 0)
            return (0...96).map { i in
                let t = CGFloat(i) / 96 * 2 * .pi
                let x = r.width * cos(t), y = r.height * sin(t)
                return CGPoint(x: c.x + x * cos(a) - y * sin(a), y: c.y + x * sin(a) + y * cos(a))
            }
        case .projectile:
            return trajectory
        }
    }

    var bounds: CGRect {
        let all = outline + (kind == .projectile ? [arrowTip] : [])
        guard let first = all.first else { return .zero }
        return all.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    func distance(to p: CGPoint) -> CGFloat {
        let line = outline
        var best = CGFloat.infinity
        for (a, b) in zip(line, line.dropFirst()) {
            best = min(best, Self.segmentDistance(p, a, b))
        }
        if kind == .projectile {
            best = min(best, hypot(p.x - center.x, p.y - center.y), Self.segmentDistance(p, center, arrowTip))
        }
        return best
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // Handles

    /// Draggable points: vertices, an ellipse's two radii, a projectile's launch and aim.
    var handles: [CGPoint] {
        switch kind {
        case .polygon, .polyline, .line:
            return points
        case .ellipse:
            let c = center, r = radii ?? .zero, a = CGFloat(rotation ?? 0)
            return [CGPoint(x: c.x + r.width * cos(a), y: c.y + r.width * sin(a)),
                    CGPoint(x: c.x - r.height * sin(a), y: c.y + r.height * cos(a))]
        case .projectile:
            return [center, arrowTip]
        }
    }

    func moving(handle i: Int, to p: CGPoint) -> ShapeItem {
        var s = self
        switch kind {
        case .polygon, .polyline, .line:
            if s.points.indices.contains(i) { s.points[i] = p }
        case .ellipse:
            let c = center
            let d = hypot(p.x - c.x, p.y - c.y)
            var r = radii ?? .zero
            if i == 0 {
                r.width = max(d, 6)
                s.rotation = Double(atan2(p.y - c.y, p.x - c.x))
            } else {
                r.height = max(d, 6)
            }
            s.radii = r
        case .projectile:
            if i == 0 {
                s.points = [p]
            } else if var launch = projectile {
                let dx = p.x - center.x, dy = center.y - p.y
                launch.angle = min(max(Double(atan2(dy, dx)) * 180 / .pi, 0), 90)
                launch.speed = max(Double(hypot(dx, dy)) / (launch.scale * Self.arrowPerSpeed), 1)
                s.projectile = launch
            }
        }
        return s
    }

    func translated(by d: CGSize) -> ShapeItem {
        var s = self
        s.points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return s
    }

    func scaled(by k: CGFloat) -> ShapeItem {
        var s = self
        let c = center
        switch kind {
        case .ellipse:
            s.radii = radii.map { CGSize(width: $0.width * k, height: $0.height * k) }
        case .projectile:
            s.projectile?.scale = (projectile?.scale ?? 12) * Double(k)
        default:
            s.points = points.map { CGPoint(x: c.x + ($0.x - c.x) * k, y: c.y + ($0.y - c.y) * k) }
        }
        return s
    }

    // Measuring

    /// Interior angles in degrees: every corner of a polygon, the inner corners of a polyline.
    var angles: [Double] {
        switch kind {
        case .polygon:
            let n = points.count
            return (0..<n).map { Self.angle(points[($0 - 1 + n) % n], points[$0], points[($0 + 1) % n]) }
        case .polyline:
            guard points.count > 2 else { return [] }
            return (1..<points.count - 1).map { Self.angle(points[$0 - 1], points[$0], points[$0 + 1]) }
        default:
            return []
        }
    }

    static func angle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let lengths = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
        guard lengths > 0 else { return 0 }
        return Double(acos(min(max((v1.x * v2.x + v1.y * v2.y) / lengths, -1), 1))) * 180 / .pi
    }

    /// Side lengths in centimetres.
    var sides: [Double] {
        let line = kind == .polygon ? outline : points
        return zip(line, line.dropFirst()).map { Double(hypot($1.x - $0.x, $1.y - $0.y)) * cmPerPoint }
    }

    /// Angle of a line from horizontal, degrees, counter-clockwise.
    var lineAngle: Double {
        guard points.count == 2 else { return 0 }
        return Double(atan2(points[0].y - points[1].y, points[1].x - points[0].x)) * 180 / .pi
    }

    // Exact shapes

    /// Re-solves a triangle for the given angles (degrees), keeping side AB and which side C is on.
    func withTriangleAngles(_ a: Double, _ b: Double) -> ShapeItem {
        guard kind == .polygon, points.count == 3 else { return self }
        let c = 180 - a - b
        guard a > 0.5, b > 0.5, c > 0.5 else { return self }
        let A = points[0], B = points[1], C = points[2]
        let base = hypot(B.x - A.x, B.y - A.y)
        guard base > 0 else { return self }
        let u = CGPoint(x: (B.x - A.x) / base, y: (B.y - A.y) / base)
        var n = CGPoint(x: -u.y, y: u.x)
        if (C.x - A.x) * n.x + (C.y - A.y) * n.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
        let rad = Double.pi / 180
        let ac = Double(base) * sin(b * rad) / sin(c * rad)
        let along = CGFloat(ac * cos(a * rad)), up = CGFloat(ac * sin(a * rad))
        var s = self
        s.points[2] = CGPoint(x: A.x + u.x * along + n.x * up, y: A.y + u.y * along + n.y * up)
        return s
    }

    /// Sets one triangle angle; the other two keep their proportions.
    func settingTriangleAngle(_ i: Int, to value: Double) -> ShapeItem {
        var t = angles
        guard t.count == 3, (1...178).contains(value) else { return self }
        let others = [0, 1, 2].filter { $0 != i }
        let rest = t[others[0]] + t[others[1]]
        guard rest > 0 else { return self }
        for j in others { t[j] = t[j] / rest * (180 - value) }
        t[i] = value
        return withTriangleAngles(t[0], t[1])
    }

    /// Same corner count, all sides and angles equal, keeping the centre, size and first corner.
    func regularized() -> ShapeItem {
        guard kind == .polygon, points.count >= 3 else { return self }
        let c = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        let r = points.map { hypot($0.x - c.x, $0.y - c.y) }.reduce(0, +) / CGFloat(points.count)
        let start = atan2(points[0].y - c.y, points[0].x - c.x)
        // keep the drawing's winding direction
        let cross = (points[1].x - points[0].x) * (points[2].y - points[1].y) - (points[1].y - points[0].y) * (points[2].x - points[1].x)
        let step = (cross >= 0 ? 1 : -1) * 2 * CGFloat.pi / CGFloat(points.count)
        var s = self
        s.points = (0..<points.count).map { i in
            let t = start + CGFloat(i) * step
            return CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
        }
        return s
    }

    func circled() -> ShapeItem {
        var s = self
        if let r = radii {
            let m = (r.width + r.height) / 2
            s.radii = CGSize(width: m, height: m)
        }
        return s
    }

    /// The triangle snapped to the nearest right angle: the biggest corner becomes 90.
    func rightAngled() -> ShapeItem {
        let t = angles
        guard t.count == 3, let big = t.indices.max(by: { t[$0] < t[$1] }) else { return self }
        return settingTriangleAngle(big, to: 90)
    }

    func isosceles() -> ShapeItem {
        let t = angles
        guard t.count == 3 else { return self }
        let base = (t[0] + t[1]) / 2
        return withTriangleAngles(base, base)
    }

    // Projectiles

    static let arrowPerSpeed = 0.25

    var arrowTip: CGPoint {
        guard let p = projectile else { return center }
        let length = CGFloat(p.speed * p.scale * Self.arrowPerSpeed)
        let a = CGFloat(p.angle * .pi / 180)
        return CGPoint(x: center.x + length * cos(a), y: center.y - length * sin(a))
    }

    /// Flight time, range, peak height (all above ground) and time to peak.
    var flight: (time: Double, range: Double, peak: Double, peakTime: Double) {
        guard let p = projectile, p.gravity > 0 else { return (0, 0, 0, 0) }
        let a = p.angle * .pi / 180
        let vx = p.speed * cos(a), vy = p.speed * sin(a)
        let time = (vy + (vy * vy + 2 * p.gravity * p.height).squareRoot()) / p.gravity
        let peakTime = max(vy / p.gravity, 0)
        return (time, vx * time, p.height + vy * peakTime - p.gravity * peakTime * peakTime / 2, peakTime)
    }

    /// Page point at time t.
    func position(at t: Double) -> CGPoint {
        guard let p = projectile else { return center }
        let a = p.angle * .pi / 180
        let x = p.speed * cos(a) * t
        let y = p.speed * sin(a) * t - p.gravity * t * t / 2
        return CGPoint(x: center.x + CGFloat(x * p.scale), y: center.y - CGFloat(y * p.scale))
    }

    var trajectory: [CGPoint] {
        let time = flight.time
        guard time > 0 else { return [center] }
        return (0...80).map { position(at: time * Double($0) / 80) }
    }

    var groundY: CGFloat {
        center.y + CGFloat((projectile?.height ?? 0) * (projectile?.scale ?? 12))
    }
}

/// Draws a page's vector shapes, with measurements and physics labels.
final class ShapeLayerView: UIView {
    var shapes: [ShapeItem] = [] { didSet { setNeedsDisplay() } }
    /// A shape being drawn or dragged, shown in place of its saved copy.
    var preview: ShapeItem? { didSet { setNeedsDisplay() } }
    var selected: UUID? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        var list = shapes.filter { $0.id != preview?.id }
        if let preview { list.append(preview) }
        for shape in list {
            draw(shape, in: ctx)
        }
    }

    private func draw(_ shape: ShapeItem, in ctx: CGContext) {
        let color = UIColor(hex: shape.color).withAlphaComponent(CGFloat(shape.opacity ?? 1))
        if shape.id == selected {
            stroke(shape.outline, color: Theme.uiAccent.withAlphaComponent(0.25), width: shape.width + 10, in: ctx)
        }
        if shape.kind == .projectile {
            drawProjectile(shape, color: color, in: ctx)
            return
        }
        stroke(shape.outline, color: color, width: shape.width, in: ctx)
        guard shape.measures == true else { return }
        let label = Theme.uiAccent
        switch shape.kind {
        case .polygon, .polyline:
            let n = shape.points.count
            let corners: [Int] = shape.kind == .polygon ? Array(0..<n) : Array(1..<max(n - 1, 1))
            let centroid = shape.center
            for (k, i) in corners.enumerated() where k < shape.angles.count {
                let p = shape.points[i]
                let prev = shape.points[(i - 1 + n) % n], next = shape.points[(i + 1) % n]
                arc(at: p, from: prev, to: next, color: label, in: ctx)
                // label sits inside the corner
                let mid = CGPoint(x: (prev.x + next.x) / 2, y: (prev.y + next.y) / 2)
                let toward = shape.kind == .polygon ? centroid : mid
                let d = max(hypot(toward.x - p.x, toward.y - p.y), 1)
                text(String(format: "%.0f\u{00B0}", shape.angles[k]), at: CGPoint(x: p.x + (toward.x - p.x) / d * 34, y: p.y + (toward.y - p.y) / d * 34), color: label)
            }
            let line = shape.kind == .polygon ? shape.outline : shape.points
            for (j, (a, b)) in zip(line, line.dropFirst()).enumerated() where j < shape.sides.count {
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let len = max(hypot(b.x - a.x, b.y - a.y), 1)
                var normal = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
                // push side labels away from the middle
                if shape.kind == .polygon, (mid.x - centroid.x) * normal.x + (mid.y - centroid.y) * normal.y < 0 {
                    normal = CGPoint(x: -normal.x, y: -normal.y)
                }
                text(String(format: "%.1f cm", shape.sides[j]), at: CGPoint(x: mid.x + normal.x * 18, y: mid.y + normal.y * 18), color: label)
            }
        case .line:
            guard shape.points.count == 2 else { return }
            let a = shape.points[0], b = shape.points[1]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 18)
            text(String(format: "%.1f cm \u{00B7} %.0f\u{00B0}", shape.sides.first ?? 0, shape.lineAngle), at: mid, color: label)
        case .ellipse:
            let r = shape.radii ?? .zero
            let c = shape.center
            if abs(r.width - r.height) < 0.5 {
                stroke([c, shape.handles[0]], color: label.withAlphaComponent(0.6), width: 1.5, dash: [5, 4], in: ctx)
                text(String(format: "r = %.1f cm", Double(r.width) * cmPerPoint), at: CGPoint(x: c.x, y: c.y - 16), color: label)
            } else {
                text(String(format: "a = %.1f cm  b = %.1f cm", Double(r.width) * cmPerPoint, Double(r.height) * cmPerPoint), at: c, color: label)
            }
        case .projectile:
            break
        }
    }

    private func drawProjectile(_ shape: ShapeItem, color: UIColor, in ctx: CGContext) {
        guard let p = shape.projectile else { return }
        let label = Theme.uiAccent
        let f = shape.flight
        let launch = shape.center
        let landing = shape.position(at: f.time)
        let ground = shape.groundY
        stroke([CGPoint(x: min(launch.x, landing.x) - 30, y: ground), CGPoint(x: max(launch.x, landing.x) + 30, y: ground)],
               color: color.withAlphaComponent(0.5), width: 1.5, in: ctx)
        if p.height > 0 {
            stroke([launch, CGPoint(x: launch.x, y: ground)], color: color.withAlphaComponent(0.4), width: 1.5, dash: [4, 4], in: ctx)
        }
        stroke(shape.trajectory, color: color, width: shape.width, dash: [10, 6], in: ctx)

        // velocity arrow
        let tip = shape.arrowTip
        stroke([launch, tip], color: label, width: 3, in: ctx)
        let a = atan2(tip.y - launch.y, tip.x - launch.x)
        stroke([CGPoint(x: tip.x - 12 * cos(a - 0.45), y: tip.y - 12 * sin(a - 0.45)), tip,
                CGPoint(x: tip.x - 12 * cos(a + 0.45), y: tip.y - 12 * sin(a + 0.45))], color: label, width: 3, in: ctx)
        text(String(format: "v = %.1f m/s  \u{03B8} = %.0f\u{00B0}", p.speed, p.angle), at: CGPoint(x: tip.x + 10, y: tip.y - 14), color: label, leading: true)

        // peak marker and readouts
        let peak = shape.position(at: f.peakTime)
        stroke([peak, CGPoint(x: peak.x, y: ground)], color: label.withAlphaComponent(0.5), width: 1, dash: [3, 4], in: ctx)
        ctx.setFillColor(label.cgColor)
        ctx.fillEllipse(in: CGRect(x: peak.x - 4, y: peak.y - 4, width: 8, height: 8))
        text(String(format: "H = %.1f m", f.peak), at: CGPoint(x: peak.x, y: peak.y - 16), color: label)
        text(String(format: "R = %.1f m  \u{00B7}  T = %.2f s", f.range, f.time), at: CGPoint(x: (launch.x + landing.x) / 2, y: ground + 16), color: label)
        ctx.fillEllipse(in: CGRect(x: landing.x - 4, y: landing.y - 4, width: 8, height: 8))
    }

    private func stroke(_ line: [CGPoint], color: UIColor, width: CGFloat, dash: [CGFloat] = [], in ctx: CGContext) {
        guard let first = line.first else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineDash(phase: 0, lengths: dash)
        ctx.move(to: first)
        for p in line.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func arc(at p: CGPoint, from a: CGPoint, to b: CGPoint, color: UIColor, in ctx: CGContext) {
        let start = atan2(a.y - p.y, a.x - p.x), end = atan2(b.y - p.y, b.x - p.x)
        var sweep = end - start
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addArc(center: p, radius: 16, startAngle: start, endAngle: start + sweep, clockwise: sweep < 0)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func text(_ string: String, at point: CGPoint, color: UIColor, leading: Bool = false) {
        let base = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 13) } ?? base
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: leading ? point.x : point.x - size.width / 2, y: point.y - size.height / 2)
        let bubble = CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -2)
        UIColor.white.withAlphaComponent(0.75).setFill()
        UIBezierPath(roundedRect: bubble, cornerRadius: 5).fill()
        (string as NSString).draw(at: origin, withAttributes: attrs)
    }
}
