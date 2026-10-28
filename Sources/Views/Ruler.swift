import PencilKit
import UIKit

/// A see-through ruler lying on the page: centimetres along the top edge, inches along the bottom.
/// One finger slides it, two fingers turn it, and pencil lines drawn against an edge come out straight.
final class RulerView: UIView, UIGestureRecognizerDelegate {
    static let length: CGFloat = 1000
    static let depth: CGFloat = 70
    /// Page points per millimetre and per inch, from the same A4 scale as shape measurements.
    static let pointsPerMM = 0.1 / cmPerPoint
    static let pointsPerInch = 2.54 / cmPerPoint

    /// Middle of the ruler and its turn (radians), in page points.
    private(set) var middle = CGPoint.zero
    private(set) var angle: CGFloat = 0
    var onMove: ((CGPoint, CGFloat) -> Void)?

    private var start: (middle: CGPoint, angle: CGFloat)?
    private var turning = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        bounds = CGRect(x: 0, y: 0, width: Self.length, height: Self.depth)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        // the pencil writes straight through it
        tag = PassthroughView.pencilThroughTag
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
        pan.maximumNumberOfTouches = 2
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(turned(_:)))
        for gesture in [pan, rotate] as [UIGestureRecognizer] {
            gesture.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func place(at middle: CGPoint, angle: CGFloat) {
        self.middle = middle
        self.angle = angle
        center = middle
        transform = CGAffineTransform(rotationAngle: angle)
        setNeedsDisplay()
    }

    @objc private func moved(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch gesture.state {
        case .began:
            if start == nil { start = (middle, angle) }
        case .changed:
            guard let start else { return }
            let t = gesture.translation(in: parent)
            place(at: CGPoint(x: start.middle.x + t.x, y: start.middle.y + t.y), angle: angle)
        default:
            finish(gesture)
        }
    }

    @objc private func turned(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            if start == nil { start = (middle, angle) }
            turning = true
        case .changed:
            guard let start else { return }
            place(at: middle, angle: Self.snapped(start.angle + gesture.rotation))
        default:
            turning = false
            finish(gesture)
        }
    }

    private func finish(_ gesture: UIGestureRecognizer) {
        // the move ends when both gestures have
        let others = gestureRecognizers?.filter { $0 !== gesture && ($0.state == .began || $0.state == .changed) } ?? []
        guard others.isEmpty else { return }
        start = nil
        setNeedsDisplay()
        onMove?(middle, angle)
    }

    /// Clicks onto every 15 degrees when close.
    private static func snapped(_ angle: CGFloat) -> CGFloat {
        let step = CGFloat.pi / 12
        let nearest = (angle / step).rounded() * step
        return abs(angle - nearest) < 0.035 ? nearest : angle
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }

    // scrolling and page turns wait while a finger is on the ruler
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view !== self
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let body = bounds.insetBy(dx: 1, dy: 1)
        let shape = UIBezierPath(roundedRect: body, cornerRadius: 8)
        UIColor.white.withAlphaComponent(0.72).setFill()
        shape.fill()
        Theme.uiAccent.withAlphaComponent(0.55).setStroke()
        shape.lineWidth = 1.5
        shape.stroke()

        let ink = UIColor(white: 0.15, alpha: 0.85)
        ink.setStroke()
        ctx.setLineWidth(1)
        let label: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: ink]

        // millimetres from the left end, along the top
        var mm = 0
        while CGFloat(mm) * Self.pointsPerMM < bounds.width - 4 {
            let x = 4 + CGFloat(mm) * Self.pointsPerMM
            let tick: CGFloat = mm % 10 == 0 ? 16 : mm % 5 == 0 ? 11 : 6
            ctx.move(to: CGPoint(x: x, y: 1))
            ctx.addLine(to: CGPoint(x: x, y: 1 + tick))
            if mm % 10 == 0 {
                let text = "\(mm / 10)" as NSString
                let size = text.size(withAttributes: label)
                text.draw(at: CGPoint(x: x - size.width / 2, y: 19), withAttributes: label)
            }
            mm += 1
        }
        // eighths of an inch along the bottom
        var eighth = 0
        while CGFloat(eighth) * Self.pointsPerInch / 8 < bounds.width - 4 {
            let x = 4 + CGFloat(eighth) * Self.pointsPerInch / 8
            let tick: CGFloat = eighth % 8 == 0 ? 16 : eighth % 4 == 0 ? 11 : eighth % 2 == 0 ? 8 : 5
            ctx.move(to: CGPoint(x: x, y: bounds.height - 1))
            ctx.addLine(to: CGPoint(x: x, y: bounds.height - 1 - tick))
            if eighth % 8 == 0 {
                let text = "\(eighth / 8)" as NSString
                let size = text.size(withAttributes: label)
                text.draw(at: CGPoint(x: x - size.width / 2, y: bounds.height - 31), withAttributes: label)
            }
            eighth += 1
        }
        ctx.strokePath()

        let units: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: ink.withAlphaComponent(0.6)]
        ("cm" as NSString).draw(at: CGPoint(x: bounds.width - 24, y: 19), withAttributes: units)
        ("in" as NSString).draw(at: CGPoint(x: bounds.width - 20, y: bounds.height - 31), withAttributes: units)

        // how far it's turned, the way a protractor reads it
        var degrees = (-angle * 180 / .pi).truncatingRemainder(dividingBy: 180)
        if degrees < 0 { degrees += 180 }
        let reading = String(format: "%.0f\u{00B0}", degrees.rounded() == 180 ? 0 : degrees) as NSString
        let big: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold), .foregroundColor: Theme.uiAccent]
        let size = reading.size(withAttributes: big)
        reading.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: big)
    }

    /// A stroke drawn along one edge, laid flat against that edge; nil when it wasn't following the ruler.
    func straightened(_ stroke: PKStroke) -> PKStroke? {
        let points = stroke.path.map { $0.location.applying(stroke.transform) }
        guard points.count > 2 else { return nil }
        let along = CGPoint(x: cos(angle), y: sin(angle))
        let across = CGPoint(x: -sin(angle), y: cos(angle))
        func local(_ p: CGPoint) -> CGPoint {
            let d = CGPoint(x: p.x - middle.x, y: p.y - middle.y)
            return CGPoint(x: d.x * along.x + d.y * along.y, y: d.x * across.x + d.y * across.y)
        }
        let locals = points.map(local)
        let span = (locals.map(\.x).max() ?? 0) - (locals.map(\.x).min() ?? 0)
        guard span > 20, locals.allSatisfy({ abs($0.x) < Self.length / 2 + 30 }) else { return nil }
        let halfWidth = (stroke.path.first?.size.width ?? 2) / 2
        for side: CGFloat in [-1, 1] {
            let edge = side * Self.depth / 2
            let near = locals.filter { abs($0.y - edge) < 24 && ($0.y - edge) * side > -12 }
            guard Double(near.count) >= Double(locals.count) * 0.9 else { continue }
            // sit just outside the edge, like a pen run along a real ruler
            let line = edge + side * halfWidth
            let flat = zip(stroke.path, locals).map { point, l -> PKStrokePoint in
                let x = l.x
                let p = CGPoint(x: middle.x + along.x * x + across.x * line, y: middle.y + along.y * x + across.y * line)
                return PKStrokePoint(location: p, timeOffset: point.timeOffset, size: point.size, opacity: point.opacity,
                                     force: point.force, azimuth: point.azimuth, altitude: point.altitude)
            }
            let path = PKStrokePath(controlPoints: flat, creationDate: stroke.path.creationDate)
            return PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: nil)
        }
        return nil
    }
}
