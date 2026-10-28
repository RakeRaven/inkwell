import PencilKit
import UIKit

/// Geometry heuristics over strokes: scribbles, "=" signs, and the expressions before them.
enum InkAnalyzer {
    struct Equation {
        /// Just right of the "=", where the answer goes.
        let anchor: CGPoint
        let image: UIImage
        let fontSize: CGFloat
    }

    static func points(of stroke: PKStroke) -> [CGPoint] {
        stroke.path.interpolatedPoints(by: .distance(4)).map { $0.location.applying(stroke.transform) }
    }

    /// A dense back-and-forth zigzag along the stroke's long axis.
    static func isScribble(_ stroke: PKStroke) -> Bool {
        let pts = points(of: stroke)
        let bounds = stroke.renderBounds
        let long = max(bounds.width, bounds.height)
        guard pts.count > 8, long > 20 else { return false }
        var length: CGFloat = 0
        for i in 1..<pts.count {
            length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        let axis = bounds.width >= bounds.height ? pts.map(\.x) : pts.map(\.y)
        return reversals(in: axis, threshold: max(8, long * 0.25)) >= 4 && length > long * 3
    }

    /// Strokes lying mostly inside the scribble's bounds.
    static func covered(by scribble: PKStroke, in strokes: [PKStroke]) -> IndexSet {
        let area = scribble.renderBounds.insetBy(dx: -4, dy: -4)
        var hit = IndexSet()
        for (i, stroke) in strokes.enumerated() where stroke.renderBounds.intersects(area) {
            let pts = points(of: stroke)
            guard !pts.isEmpty else { continue }
            let inside = pts.filter { area.contains($0) }.count
            if CGFloat(inside) >= CGFloat(pts.count) * 0.6 { hit.insert(i) }
        }
        return hit
    }

    /// Every "=" (two consecutive stacked dashes) that has handwriting to its left.
    static func equations(in strokes: [PKStroke]) -> [Equation] {
        guard strokes.count >= 3 else { return [] }
        var used = IndexSet()
        var result: [Equation] = []
        for i in 1..<strokes.count where !used.contains(i - 1) {
            let a = strokes[i - 1].renderBounds
            let b = strokes[i].renderBounds
            guard isDash(a), isDash(b), stacked(a, b) else { continue }
            used.insert(integersIn: (i - 1)...i)
            let sign = a.union(b)
            let expr = expression(leftOf: sign, in: strokes, excluding: used)
            guard !expr.isEmpty else { continue }
            let rect = expr.reduce(CGRect.null) { $0.union($1.renderBounds) }
            result.append(Equation(
                anchor: CGPoint(x: sign.maxX + 10, y: sign.midY),
                image: image(of: expr, in: rect),
                fontSize: min(max(rect.height * 0.8, 18), 64)
            ))
        }
        return result
    }

    /// Black ink on white, the way Vision reads best.
    static func image(of strokes: [PKStroke], in rect: CGRect) -> UIImage {
        let frame = rect.insetBy(dx: -16, dy: -16)
        let black = strokes.map { PKStroke(ink: PKInk($0.ink.inkType, color: .black), path: $0.path, transform: $0.transform, mask: $0.mask) }
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = PKDrawing(strokes: black).image(from: frame, scale: 2)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: frame.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: frame.size))
            ink.draw(in: CGRect(origin: .zero, size: frame.size))
        }
    }

    private static func isDash(_ r: CGRect) -> Bool {
        r.width >= 8 && r.width <= 140 && r.height <= max(r.width * 0.35, 6)
    }

    private static func stacked(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let narrow = min(a.width, b.width)
        let wide = max(a.width, b.width)
        let gap = abs(a.midY - b.midY)
        return overlap >= narrow * 0.5 && narrow >= wide * 0.5 && gap >= 3 && gap <= wide * 0.7
    }

    /// Strokes on the sign's line, walking left until a big gap.
    private static func expression(leftOf sign: CGRect, in strokes: [PKStroke], excluding: IndexSet) -> [PKStroke] {
        let reach = max(sign.width * 1.5, 40)
        let candidates = strokes.indices
            .filter { !excluding.contains($0) }
            .map { strokes[$0] }
            .filter { stroke in
                let r = stroke.renderBounds
                return r.maxX <= sign.minX + 6 && abs(r.midY - sign.midY) <= reach && r.height <= reach * 2
            }
            .sorted { $0.renderBounds.maxX > $1.renderBounds.maxX }
        var left = sign.minX
        var picked: [PKStroke] = []
        for stroke in candidates {
            let r = stroke.renderBounds
            guard r.maxX >= left - reach else { break }
            picked.append(stroke)
            left = min(left, r.minX)
        }
        return picked
    }

    /// Direction changes larger than threshold.
    private static func reversals(in values: [CGFloat], threshold: CGFloat) -> Int {
        guard var extreme = values.first else { return 0 }
        var direction: CGFloat = 0
        var count = 0
        for value in values.dropFirst() {
            let delta = value - extreme
            if direction == 0 {
                if abs(delta) > threshold {
                    direction = delta > 0 ? 1 : -1
                    extreme = value
                }
            } else if delta * direction > 0 {
                extreme = value
            } else if abs(delta) > threshold {
                count += 1
                direction = -direction
                extreme = value
            }
        }
        return count
    }
}
