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

    static func image(_ style: PaperStyle, color: PaperColor, width: CGFloat) -> UIImage {
        let scale = width / notebookPageSize.width
        let size = CGSize(width: width, height: notebookPageSize.height * scale)
        return UIGraphicsImageRenderer(size: size).image { r in
            color.fill.setFill()
            r.fill(CGRect(origin: .zero, size: size))
            r.cgContext.scaleBy(x: scale, y: scale)
            draw(style, color: color, in: r.cgContext, size: notebookPageSize, weight: max(1, 0.6 / scale))
        }
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
        PaperRenderer.draw(style, color: color, in: ctx, size: bounds.size)
    }
}
