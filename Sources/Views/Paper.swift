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
