import PDFKit
import SwiftUI
import UIKit

extension PaperColor {
    var fill: UIColor {
        switch self {
        case .white: .white
        case .cream: UIColor(hex: "FBF6E9")
        case .yellow: UIColor(hex: "FDF3B8")
        case .dark: UIColor(hex: "2A2A2D")
        }
    }
}

/// Draws page templates in page coordinates (see `notebookPageSize`).
enum PaperRenderer {
    /// `weight` thickens lines so tiny thumbnails stay readable.
    static func draw(_ style: PaperStyle, color: PaperColor, in ctx: CGContext, size: CGSize, weight: CGFloat = 1) {
        let dark = color == .dark
        let line = dark ? UIColor(white: 1, alpha: 0.22) : UIColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 0.55)
        let faint = line.withAlphaComponent(dark ? 0.12 : 0.3)
        let accent = UIColor(red: 0.9, green: 0.35, blue: 0.35, alpha: dark ? 0.5 : 0.6)
        let w = size.width, h = size.height

        func stroke(_ color: UIColor, width: CGFloat = 1, dash: [CGFloat] = [], _ build: (CGMutablePath) -> Void) {
            let path = CGMutablePath()
            build(path)
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width * weight)
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
        func hline(_ p: CGMutablePath, _ y: CGFloat, _ x0: CGFloat = 0, _ x1: CGFloat? = nil) {
            p.move(to: CGPoint(x: x0, y: y))
            p.addLine(to: CGPoint(x: x1 ?? w, y: y))
        }
        func vline(_ p: CGMutablePath, _ x: CGFloat, _ y0: CGFloat = 0, _ y1: CGFloat? = nil) {
            p.move(to: CGPoint(x: x, y: y0))
            p.addLine(to: CGPoint(x: x, y: y1 ?? h))
        }

        switch style {
        case .blank:
            break
        case .lined, .narrow, .wide, .margin:
            let spacing: CGFloat = style == .narrow ? 30 : style == .wide ? 52 : 40
            stroke(line) { p in for y in stride(from: 80, to: h - 20, by: spacing) { hline(p, y) } }
            if style == .margin { stroke(accent) { p in vline(p, 100) } }
        case .doubleLine:
            stroke(line) { p in
                for y in stride(from: 80, to: h - 40, by: 64) {
                    hline(p, y)
                    hline(p, y + 20)
                }
            }
        case .handwriting:
            let tops = Array(stride(from: CGFloat(80), to: h - 60, by: 88))
            stroke(line) { p in for y in tops { hline(p, y); hline(p, y + 48) } }
            stroke(faint, dash: [6 * weight, 5 * weight]) { p in for y in tops { hline(p, y + 24) } }
        case .grid, .smallGrid:
            let spacing: CGFloat = style == .grid ? 40 : 20
            stroke(faint) { p in
                for x in stride(from: spacing, to: w, by: spacing) { vline(p, x) }
                for y in stride(from: spacing, to: h, by: spacing) { hline(p, y) }
            }
            if style == .smallGrid {
                stroke(line.withAlphaComponent(dark ? 0.2 : 0.4)) { p in
                    for x in stride(from: 100, to: w, by: 100) { vline(p, x) }
                    for y in stride(from: 100, to: h, by: 100) { hline(p, y) }
                }
            }
        case .dotted:
            ctx.setFillColor(line.cgColor)
            let r = 1.5 * weight
            for x in stride(from: CGFloat(40), to: w, by: 40) {
                for y in stride(from: CGFloat(40), to: h, by: 40) {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            }
        case .cornell:
            stroke(line) { p in
                for y in stride(from: CGFloat(160), to: 900, by: 40) { hline(p, y, 230) }
                for y in stride(from: 960, to: h - 20, by: 40) { hline(p, y) }
            }
            stroke(accent, width: 1.5) { p in
                hline(p, 120)
                vline(p, 230, 120, 920)
                hline(p, 920)
            }
        case .music:
            stroke(line.withAlphaComponent(dark ? 0.35 : 0.8)) { p in
                for top in stride(from: CGFloat(100), to: h - 80, by: 104) {
                    for i in 0..<5 { hline(p, top + CGFloat(i) * 11, 50, w - 50) }
                }
            }
        }
    }

    static func image(_ style: PaperStyle, color: PaperColor, width: CGFloat, pageSize: CGSize = notebookPageSize) -> UIImage {
        let scale = width / pageSize.width
        let size = CGSize(width: width, height: pageSize.height * scale)
        return UIGraphicsImageRenderer(size: size).image { r in
            color.fill.setFill()
            r.fill(CGRect(origin: .zero, size: size))
            r.cgContext.scaleBy(x: scale, y: scale)
            draw(style, color: color, in: r.cgContext, size: pageSize, weight: max(1, 0.6 / scale))
        }
    }

    /// Draws a PDF page fitted into `size`, on white.
    static func draw(_ page: PDFPage, in ctx: CGContext, size: CGSize) {
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let box = page.bounds(for: .cropBox)
        let scale = min(size.width / box.width, size.height / box.height)
        ctx.saveGState()
        // PDF space is y-up
        ctx.translateBy(x: (size.width - box.width * scale) / 2, y: (size.height + box.height * scale) / 2)
        ctx.scaleBy(x: scale, y: -scale)
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
    }
}

/// A page template drawn in page coordinates.
final class PaperView: UIView {
    var style: PaperStyle = .lined {
        didSet { if style != oldValue { setNeedsDisplay() } }
    }
    var color: PaperColor = .white {
        didSet {
            guard color != oldValue else { return }
            backgroundColor = color.fill
            setNeedsDisplay()
        }
    }
    /// An inserted PDF page replaces the template.
    var pdfPage: PDFPage? {
        didSet { if pdfPage !== oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = color.fill
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if let pdfPage {
            PaperRenderer.draw(pdfPage, in: ctx, size: bounds.size)
        } else {
            PaperRenderer.draw(style, color: color, in: ctx, size: bounds.size)
        }
    }
}

/// Small vector page icon: folded corner plus a hint of the template.
struct PaperGlyph: View {
    let style: PaperStyle
    let color: PaperColor
    var pdf = false

    var body: some View {
        Canvas { ctx, size in
            let fold = size.width * 0.32
            var page = Path()
            page.move(to: CGPoint(x: 1, y: 1))
            page.addLine(to: CGPoint(x: size.width - fold, y: 1))
            page.addLine(to: CGPoint(x: size.width - 1, y: fold))
            page.addLine(to: CGPoint(x: size.width - 1, y: size.height - 1))
            page.addLine(to: CGPoint(x: 1, y: size.height - 1))
            page.closeSubpath()
            ctx.fill(page, with: .color(Color(uiColor: color.fill)))

            let ink = GraphicsContext.Shading.color(color == .dark ? .white.opacity(0.7) : Theme.accent.opacity(0.8))
            let left: CGFloat = 4, right = size.width - 4
            var marks = Path()
            if pdf {
                for y in stride(from: size.height * 0.4, to: size.height - 4, by: 3.5) {
                    marks.move(to: CGPoint(x: left, y: y))
                    marks.addLine(to: CGPoint(x: y.truncatingRemainder(dividingBy: 7) < 3.5 ? right : right - 4, y: y))
                }
            } else {
                switch style {
                case .blank:
                    break
                case .grid, .smallGrid:
                    let step: CGFloat = style == .grid ? 4 : 3
                    for x in stride(from: left, through: right, by: step) {
                        marks.move(to: CGPoint(x: x, y: fold))
                        marks.addLine(to: CGPoint(x: x, y: size.height - 3))
                    }
                    for y in stride(from: fold, through: size.height - 3, by: step) {
                        marks.move(to: CGPoint(x: left, y: y))
                        marks.addLine(to: CGPoint(x: right, y: y))
                    }
                case .dotted:
                    for x in stride(from: left, through: right, by: 3.5) {
                        for y in stride(from: fold, through: size.height - 3, by: 3.5) {
                            marks.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
                        }
                    }
                case .music:
                    for i in 0..<5 {
                        let y = fold + CGFloat(i) * 1.8
                        marks.move(to: CGPoint(x: left, y: y))
                        marks.addLine(to: CGPoint(x: right, y: y))
                    }
                default:
                    let step: CGFloat = style == .narrow ? 2.6 : style == .wide ? 4.4 : 3.4
                    for y in stride(from: fold, through: size.height - 3, by: step) {
                        marks.move(to: CGPoint(x: left, y: y))
                        marks.addLine(to: CGPoint(x: right, y: y))
                    }
                }
            }
            if style == .dotted && !pdf {
                ctx.fill(marks, with: ink)
            } else {
                ctx.stroke(marks, with: ink, lineWidth: 0.7)
            }
            if style == .margin || style == .cornell, !pdf {
                var margin = Path()
                margin.move(to: CGPoint(x: size.width * 0.32, y: 2))
                margin.addLine(to: CGPoint(x: size.width * 0.32, y: size.height - 2))
                ctx.stroke(margin, with: .color(.red.opacity(0.6)), lineWidth: 0.8)
            }

            var corner = Path()
            corner.move(to: CGPoint(x: size.width - fold, y: 1))
            corner.addLine(to: CGPoint(x: size.width - fold, y: fold))
            corner.addLine(to: CGPoint(x: size.width - 1, y: fold))
            ctx.stroke(page, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            ctx.stroke(corner, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
        .frame(width: 16, height: 21)
    }
}

/// Dog-eared corners: the tip folded over onto the page, showing the paper's back.
final class FoldView: UIView {
    /// How far a bookmark fold reaches along each edge.
    static let size: CGFloat = 80

    var folds: [PageCorner] = [] {
        didSet { if folds != oldValue { setNeedsDisplay() } }
    }
    /// A fold following a finger: the corner and where its tip has been pulled to.
    var live: (corner: PageCorner, tip: CGPoint)? {
        didSet { setNeedsDisplay() }
    }
    var paperColor: UIColor = .white {
        didSet { setNeedsDisplay() }
    }
    /// What shows where the tip was turned away.
    var behind: UIColor = .clear {
        didSet { setNeedsDisplay() }
    }
    private var link: CADisplayLink?
    private var settle: (from: CGPoint, start: CFTimeInterval, done: () -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Where a saved fold's tip lands.
    static func tip(of corner: PageCorner, in rect: CGRect) -> CGPoint {
        let c = corner.point(in: rect)
        return CGPoint(x: c.x + (corner.isLeft ? size : -size), y: c.y + (corner.isTop ? size : -size))
    }

    /// Lets go of the live fold: the paper springs back flat.
    func release(completion: @escaping () -> Void = {}) {
        guard let live else { return completion() }
        settle = (live.tip, CACurrentMediaTime(), completion)
        link?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(springBack))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func springBack() {
        guard let settle, let corner = live?.corner else {
            link?.invalidate()
            return
        }
        let u = min((CACurrentMediaTime() - settle.start) / 0.22, 1)
        let ease = 1 - pow(1 - u, 3)
        let c = corner.point(in: bounds)
        live = (corner, CGPoint(x: settle.from.x + (c.x - settle.from.x) * ease, y: settle.from.y + (c.y - settle.from.y) * ease))
        if u >= 1 {
            link?.invalidate()
            link = nil
            self.settle = nil
            live = nil
            settle.done()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for corner in folds where corner != live?.corner {
            drawFold(corner.point(in: bounds), tip: Self.tip(of: corner, in: bounds), in: ctx)
        }
        if let live {
            drawFold(live.corner.point(in: bounds), tip: live.tip, in: ctx)
        }
    }

    /// Folds the paper so `corner` lands on `tip`: the crease is the line halfway between them.
    private func drawFold(_ corner: CGPoint, tip: CGPoint, in ctx: CGContext) {
        let d = CGPoint(x: tip.x - corner.x, y: tip.y - corner.y)
        let length = hypot(d.x, d.y)
        guard length > 1 else { return }
        let n = CGPoint(x: d.x / length, y: d.y / length)
        let mid = CGPoint(x: (corner.x + tip.x) / 2, y: (corner.y + tip.y) / 2)
        // signed distance past the crease, towards the corner
        func side(_ p: CGPoint) -> CGFloat { -((p.x - mid.x) * n.x + (p.y - mid.y) * n.y) }
        let page = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                    CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
        var turned: [CGPoint] = []
        for (i, a) in page.enumerated() {
            let b = page[(i + 1) % page.count]
            let sa = side(a), sb = side(b)
            if sa >= 0 { turned.append(a) }
            if (sa >= 0) != (sb >= 0) {
                let t = sa / (sa - sb)
                turned.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        guard turned.count >= 3 else { return }
        let flapPoints = turned.map { p -> CGPoint in
            let k = 2 * side(p)
            return CGPoint(x: p.x + n.x * k, y: p.y + n.y * k)
        }
        func path(_ points: [CGPoint]) -> UIBezierPath {
            let path = UIBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            return path
        }
        let gone = path(turned), flap = path(flapPoints)
        behind.setFill()
        gone.fill()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: -n.x * 3, height: -n.y * 3 + 2), blur: 9, color: UIColor.black.withAlphaComponent(0.3).cgColor)
        paperColor.setFill()
        flap.fill()
        ctx.restoreGState()

        // darker along the crease, catching light towards the tip, like the curl of real paper
        ctx.saveGState()
        flap.addClip()
        let colors = [UIColor.black.withAlphaComponent(0.2).cgColor, UIColor.black.withAlphaComponent(0.04).cgColor,
                      UIColor.white.withAlphaComponent(0.18).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 1]) {
            ctx.drawLinearGradient(gradient, start: mid, end: tip, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
        UIColor.black.withAlphaComponent(0.12).setStroke()
        flap.lineWidth = 0.75
        flap.stroke()
    }
}
