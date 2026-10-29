import UIKit

/// The first 36 elements: enough for every Bohr model a school course draws.
enum Elements {
    static let symbols = ["H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar",
                          "K", "Ca", "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Ga", "Ge", "As", "Se", "Br", "Kr"]
    static let names = ["Hydrogen", "Helium", "Lithium", "Beryllium", "Boron", "Carbon", "Nitrogen", "Oxygen", "Fluorine", "Neon",
                        "Sodium", "Magnesium", "Aluminium", "Silicon", "Phosphorus", "Sulfur", "Chlorine", "Argon", "Potassium", "Calcium",
                        "Scandium", "Titanium", "Vanadium", "Chromium", "Manganese", "Iron", "Cobalt", "Nickel", "Copper", "Zinc",
                        "Gallium", "Germanium", "Arsenic", "Selenium", "Bromine", "Krypton"]
    /// Mass number of the most common isotope.
    static let masses = [1, 4, 7, 9, 11, 12, 14, 16, 19, 20, 23, 24, 27, 28, 31, 32, 35, 40, 39, 40,
                         45, 48, 51, 52, 55, 56, 59, 59, 64, 65, 70, 73, 75, 79, 80, 84]
    static let range = 1...36

    static func symbol(_ z: Int) -> String { symbols[clamp(z) - 1] }
    static func name(_ z: Int) -> String { names[clamp(z) - 1] }
    static func mass(_ z: Int) -> Int { masses[clamp(z) - 1] }

    /// Electrons per shell, filled in Aufbau order (with chromium and copper's half-filled exceptions).
    static func shells(_ z: Int) -> [Int] {
        let z = clamp(z)
        if z == 24 { return [2, 8, 13, 1] }
        if z == 29 { return [2, 8, 18, 1] }
        let order: [(shell: Int, room: Int)] = [(1, 2), (2, 2), (2, 6), (3, 2), (3, 6), (4, 2), (3, 10), (4, 6)]
        var shells = [0, 0, 0, 0]
        var left = z
        for orbital in order where left > 0 {
            let n = min(orbital.room, left)
            shells[orbital.shell - 1] += n
            left -= n
        }
        return shells.filter { $0 > 0 }
    }

    private static func clamp(_ z: Int) -> Int { min(max(z, range.lowerBound), range.upperBound) }
}

/// Draws diagrams in a box centred on the origin; the caller handles placement and rotation.
enum DiagramRenderer {
    static func draw(_ d: Diagram, in r: CGRect, color: UIColor, width: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch d.type {
        case .bohr: bohr(d.element ?? 6, in: r, color: color, width: width, ctx)
        case .benzene: benzene(in: r, ctx)
        case .animalCell, .plantCell: cell(plant: d.type == .plantCell, in: r, color: color, width: width, ctx)
        case .terminal, .process, .decision, .data: flowNode(d, in: r, color: color, ctx)
        case .and, .or, .not, .nand, .nor, .xor, .xnor: gate(d.type, in: r, color: color, ctx)
        case .calendar: calendar(d, in: r, color: color, ctx)
        default: component(d.type, in: r, color: color, ctx)
        }
        ctx.restoreGState()
    }

    // Chemistry

    private static func bohr(_ z: Int, in r: CGRect, color: UIColor, width: CGFloat, _ ctx: CGContext) {
        let shells = Elements.shells(z)
        let caption = r.height * 0.13
        let atom = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - caption)
        let c = CGPoint(x: atom.midX, y: atom.midY)
        let outer = min(atom.width, atom.height) / 2 * 0.94
        let nucleus = outer * 0.26
        ctx.setFillColor(color.withAlphaComponent(0.12).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - nucleus, y: c.y - nucleus, width: nucleus * 2, height: nucleus * 2))
        ctx.strokeEllipse(in: CGRect(x: c.x - nucleus, y: c.y - nucleus, width: nucleus * 2, height: nucleus * 2))
        text(Elements.symbol(z), at: CGPoint(x: c.x, y: c.y - nucleus * 0.32), size: nucleus * 0.62, color: color, weight: .bold)
        text("\(z)p  \(Elements.mass(z) - z)n", at: CGPoint(x: c.x, y: c.y + nucleus * 0.38), size: nucleus * 0.3, color: color)

        let step = (outer - nucleus) / CGFloat(max(shells.count, 1))
        let dot = max(width * 1.5, 4.5)
        for (i, count) in shells.enumerated() {
            let radius = nucleus + step * (CGFloat(i) + 0.75)
            ctx.saveGState()
            ctx.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(max(width * 0.6, 1))
            ctx.strokeEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            ctx.restoreGState()
            // electrons sit in pairs round the shell, like the drawings in a textbook
            let pairs = (count + 1) / 2
            for e in 0..<count {
                // a lone electron in the last pair sits on its own
                let alone = e == count - 1 && count % 2 == 1
                let nudge = alone ? 0 : (e % 2 == 0 ? -1 : 1) * min(0.14, .pi / CGFloat(pairs * 4))
                let t = -CGFloat.pi / 2 + CGFloat(e / 2) / CGFloat(pairs) * 2 * .pi + nudge
                let p = CGPoint(x: c.x + radius * cos(t), y: c.y + radius * sin(t))
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
            }
        }
        let config = shells.map(String.init).joined(separator: ",")
        text("\(Elements.name(z))  \u{00B7}  \(config)", at: CGPoint(x: r.midX, y: r.maxY - caption / 2), size: min(caption * 0.5, 22), color: color, weight: .semibold)
    }

    private static func benzene(in r: CGRect, _ ctx: CGContext) {
        let c = CGPoint(x: r.midX, y: r.midY), radius = min(r.width, r.height) / 2 * 0.92
        ctx.addLines(between: (0...6).map { i in
            let t = -CGFloat.pi / 2 + CGFloat(i) * .pi / 3
            return CGPoint(x: c.x + radius * cos(t), y: c.y + radius * sin(t))
        })
        ctx.strokePath()
        let inner = radius * 0.58
        ctx.strokeEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
    }

    // Biology

    private static func cell(plant: Bool, in r: CGRect, color: UIColor, width: CGFloat, _ ctx: CGContext) {
        let body = CGRect(x: r.minX, y: r.minY, width: r.width * 0.62, height: r.height).insetBy(dx: 6, dy: 6)
        var labels: [(String, CGPoint)] = []
        let soft = color.withAlphaComponent(0.08)
        if plant {
            let wall = UIBezierPath(roundedRect: body, cornerRadius: 18)
            ctx.addPath(wall.cgPath)
            ctx.setLineWidth(width * 2.2)
            ctx.strokePath()
            let membrane = body.insetBy(dx: width * 3 + 4, dy: width * 3 + 4)
            ctx.setFillColor(soft.cgColor)
            ctx.addPath(UIBezierPath(roundedRect: membrane, cornerRadius: 12).cgPath)
            ctx.fillPath()
            ctx.setLineWidth(width * 0.8)
            ctx.addPath(UIBezierPath(roundedRect: membrane, cornerRadius: 12).cgPath)
            ctx.strokePath()
            let vacuole = CGRect(x: membrane.minX + membrane.width * 0.22, y: membrane.minY + membrane.height * 0.16,
                                 width: membrane.width * 0.5, height: membrane.height * 0.6)
            ctx.setFillColor(UIColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 0.35).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: vacuole, cornerRadius: vacuole.height * 0.3).cgPath)
            ctx.fillPath()
            ctx.addPath(UIBezierPath(roundedRect: vacuole, cornerRadius: vacuole.height * 0.3).cgPath)
            ctx.strokePath()
            let nucleus = CGRect(x: membrane.minX + 12, y: membrane.maxY - membrane.height * 0.36, width: membrane.width * 0.2, height: membrane.height * 0.26)
            organelleNucleus(nucleus, color: color, ctx)
            var chloroplasts: [CGPoint] = []
            for (fx, fy) in [(0.82, 0.18), (0.86, 0.55), (0.62, 0.86), (0.12, 0.2), (0.86, 0.85)] as [(CGFloat, CGFloat)] {
                let p = CGPoint(x: membrane.minX + membrane.width * fx, y: membrane.minY + membrane.height * fy)
                chloroplast(at: p, size: membrane.width * 0.11, ctx)
                chloroplasts.append(p)
            }
            labels = [("Cell wall", CGPoint(x: body.maxX, y: body.minY + body.height * 0.08)),
                      ("Cell membrane", CGPoint(x: membrane.maxX, y: membrane.minY + membrane.height * 0.32)),
                      ("Vacuole", CGPoint(x: vacuole.maxX - 10, y: vacuole.midY)),
                      ("Chloroplast", chloroplasts[1]),
                      ("Nucleus", CGPoint(x: nucleus.maxX, y: nucleus.midY)),
                      ("Cytoplasm", CGPoint(x: membrane.maxX - 8, y: membrane.maxY - 10))]
        } else {
            let blob = UIBezierPath()
            let c = CGPoint(x: body.midX, y: body.midY)
            let steps = 64
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let wobble = 1 + 0.05 * sin(3 * t) + 0.03 * cos(5 * t)
                let p = CGPoint(x: c.x + body.width / 2 * wobble * cos(t), y: c.y + body.height / 2 * wobble * 0.95 * sin(t))
                i == 0 ? blob.move(to: p) : blob.addLine(to: p)
            }
            blob.close()
            ctx.setFillColor(soft.cgColor)
            ctx.addPath(blob.cgPath)
            ctx.fillPath()
            ctx.addPath(blob.cgPath)
            ctx.strokePath()
            let nucleus = CGRect(x: c.x - body.width * 0.14, y: c.y - body.height * 0.16, width: body.width * 0.28, height: body.height * 0.32)
            organelleNucleus(nucleus, color: color, ctx)
            var mito: [CGPoint] = []
            for (fx, fy, a) in [(0.27, 0.3, 0.5), (0.72, 0.68, -0.4), (0.3, 0.74, 0.2)] as [(CGFloat, CGFloat, CGFloat)] {
                let p = CGPoint(x: body.minX + body.width * fx, y: body.minY + body.height * fy)
                mitochondrion(at: p, size: body.width * 0.13, angle: a, color: color, ctx)
                mito.append(p)
            }
            ctx.setFillColor(color.withAlphaComponent(0.7).cgColor)
            var ribosome = CGPoint.zero
            for (fx, fy) in [(0.62, 0.25), (0.66, 0.3), (0.58, 0.32), (0.2, 0.52), (0.24, 0.57), (0.78, 0.45), (0.5, 0.82), (0.45, 0.78)] as [(CGFloat, CGFloat)] {
                ribosome = CGPoint(x: body.minX + body.width * fx, y: body.minY + body.height * fy)
                ctx.fillEllipse(in: CGRect(x: ribosome.x - 2.5, y: ribosome.y - 2.5, width: 5, height: 5))
            }
            labels = [("Cell membrane", CGPoint(x: body.maxX, y: c.y - body.height * 0.18)),
                      ("Cytoplasm", CGPoint(x: body.minX + body.width * 0.82, y: body.minY + body.height * 0.3)),
                      ("Nucleus", CGPoint(x: nucleus.maxX, y: nucleus.midY)),
                      ("Mitochondrion", mito[1]),
                      ("Ribosomes", CGPoint(x: body.minX + body.width * 0.78, y: body.minY + body.height * 0.45))]
        }
        // labels down the right, each with a leader line to its part
        let column = r.minX + r.width * 0.68
        let gap = r.height / CGFloat(labels.count + 1)
        for (i, label) in labels.enumerated() {
            let y = r.minY + gap * CGFloat(i + 1)
            ctx.saveGState()
            ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.2)
            ctx.move(to: label.1)
            ctx.addLine(to: CGPoint(x: column - 6, y: y))
            ctx.strokePath()
            ctx.restoreGState()
            ctx.fillEllipse(in: CGRect(x: label.1.x - 2.5, y: label.1.y - 2.5, width: 5, height: 5))
            text(label.0, at: CGPoint(x: column, y: y), size: min(r.height * 0.055, 20), color: color, weight: .semibold, leading: true)
        }
    }

    private static func organelleNucleus(_ rect: CGRect, color: UIColor, _ ctx: CGContext) {
        ctx.setFillColor(color.withAlphaComponent(0.16).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.strokeEllipse(in: rect)
        let n = rect.insetBy(dx: rect.width * 0.36, dy: rect.height * 0.36)
        ctx.setFillColor(color.withAlphaComponent(0.6).cgColor)
        ctx.fillEllipse(in: n)
    }

    private static func mitochondrion(at p: CGPoint, size: CGFloat, angle: CGFloat, color: UIColor, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        let rect = CGRect(x: -size / 2, y: -size / 4, width: size, height: size / 2)
        ctx.setFillColor(UIColor(red: 0.95, green: 0.6, blue: 0.45, alpha: 0.35).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: size / 4).cgPath)
        ctx.fillPath()
        ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: size / 4).cgPath)
        ctx.strokePath()
        // the folded inner membrane
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: -size * 0.38, y: 0))
        for i in 0...7 {
            ctx.addLine(to: CGPoint(x: -size * 0.38 + CGFloat(i) * size * 0.1, y: i % 2 == 0 ? -size * 0.13 : size * 0.13))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func chloroplast(at p: CGPoint, size: CGFloat, _ ctx: CGContext) {
        let rect = CGRect(x: p.x - size / 2, y: p.y - size / 3, width: size, height: size * 0.66)
        ctx.saveGState()
        ctx.setFillColor(UIColor(red: 0.3, green: 0.65, blue: 0.3, alpha: 0.55).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(UIColor(red: 0.15, green: 0.45, blue: 0.2, alpha: 0.9).cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: rect)
        for i in 1...3 {
            let y = rect.minY + rect.height * CGFloat(i) / 4
            ctx.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.25, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Computing

    private static func flowNode(_ d: Diagram, in r: CGRect, color: UIColor, _ ctx: CGContext) {
        let path: UIBezierPath
        switch d.type {
        case .terminal:
            path = UIBezierPath(roundedRect: r, cornerRadius: r.height / 2)
        case .decision:
            path = UIBezierPath()
            path.move(to: CGPoint(x: r.midX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            path.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.midY))
            path.close()
        case .data:
            let slant = r.width * 0.14
            path = UIBezierPath()
            path.move(to: CGPoint(x: r.minX + slant, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - slant, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            path.close()
        default:
            path = UIBezierPath(rect: r)
        }
        ctx.setFillColor(color.withAlphaComponent(0.07).cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
        ctx.addPath(path.cgPath)
        ctx.strokePath()
        let room = d.type == .decision ? r.width * 0.6 : r.width * 0.84
        fitted(d.label ?? "", in: CGSize(width: room, height: r.height * 0.7), at: CGPoint(x: r.midX, y: r.midY), color: color)
    }

    /// Standard gate symbols with their input and output leads.
    private static func gate(_ type: DiagramType, in r: CGRect, color: UIColor, _ ctx: CGContext) {
        let h = r.height * 0.72
        let body = CGRect(x: r.minX + r.width * 0.2, y: r.midY - h / 2, width: r.width * 0.5, height: h)
        let inverted = [.not, .nand, .nor, .xnor].contains(type)
        let bubble = inverted ? h * 0.09 : 0
        let path = UIBezierPath()
        var outX = body.maxX
        switch type {
        case .and, .nand:
            path.move(to: CGPoint(x: body.minX, y: body.minY))
            path.addLine(to: CGPoint(x: body.midX, y: body.minY))
            path.addArc(withCenter: CGPoint(x: body.midX, y: body.midY), radius: h / 2, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
            path.addLine(to: CGPoint(x: body.minX, y: body.maxY))
            path.close()
            outX = body.midX + h / 2
        case .not:
            let tri = body.insetBy(dx: body.width * 0.1, dy: h * 0.08)
            path.move(to: CGPoint(x: tri.minX, y: tri.minY))
            path.addLine(to: CGPoint(x: tri.maxX, y: tri.midY))
            path.addLine(to: CGPoint(x: tri.minX, y: tri.maxY))
            path.close()
            outX = tri.maxX
        default:
            // OR family: a curved back and a pointed nose
            path.move(to: CGPoint(x: body.minX, y: body.minY))
            path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.midY), controlPoint: CGPoint(x: body.minX + body.width * 0.75, y: body.minY))
            path.addQuadCurve(to: CGPoint(x: body.minX, y: body.maxY), controlPoint: CGPoint(x: body.minX + body.width * 0.75, y: body.maxY))
            path.addQuadCurve(to: CGPoint(x: body.minX, y: body.minY), controlPoint: CGPoint(x: body.minX + body.width * 0.25, y: body.midY))
            if type == .xor || type == .xnor {
                let back = UIBezierPath()
                back.move(to: CGPoint(x: body.minX - h * 0.12, y: body.minY))
                back.addQuadCurve(to: CGPoint(x: body.minX - h * 0.12, y: body.maxY), controlPoint: CGPoint(x: body.minX + body.width * 0.25 - h * 0.12, y: body.midY))
                ctx.addPath(back.cgPath)
                ctx.strokePath()
            }
        }
        ctx.setFillColor(color.withAlphaComponent(0.07).cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
        ctx.addPath(path.cgPath)
        ctx.strokePath()
        if inverted {
            ctx.strokeEllipse(in: CGRect(x: outX, y: body.midY - bubble, width: bubble * 2, height: bubble * 2))
        }
        // leads
        let inputs: [CGFloat] = type == .not ? [body.midY] : [body.minY + h * 0.28, body.maxY - h * 0.28]
        let inputEnd = type == .not ? body.minX + body.width * 0.1 : body.minX + (type == .and || type == .nand ? 0 : body.width * 0.12)
        for y in inputs {
            ctx.move(to: CGPoint(x: r.minX, y: y))
            ctx.addLine(to: CGPoint(x: inputEnd, y: y))
        }
        ctx.move(to: CGPoint(x: outX + bubble * 2, y: body.midY))
        ctx.addLine(to: CGPoint(x: r.maxX, y: body.midY))
        ctx.strokePath()
        text(type.rawValue.uppercased(), at: CGPoint(x: body.midX - (type == .not ? body.width * 0.12 : 0), y: body.midY), size: h * 0.2, color: color, weight: .bold)
    }

    // Physics

    /// Circuit symbols on a wire running across the box.
    private static func component(_ type: DiagramType, in r: CGRect, color: UIColor, _ ctx: CGContext) {
        let y = r.midY - r.height * 0.1
        let s = min(r.width * 0.36, r.height * 0.6)
        let left = r.midX - s / 2, right = r.midX + s / 2
        func wire(_ a: CGFloat, _ b: CGFloat) {
            ctx.move(to: CGPoint(x: a, y: y))
            ctx.addLine(to: CGPoint(x: b, y: y))
        }
        switch type {
        case .resistor:
            wire(r.minX, left)
            wire(right, r.maxX)
            ctx.strokePath()
            ctx.stroke(CGRect(x: left, y: y - s * 0.2, width: s, height: s * 0.4))
        case .cell, .battery:
            let cells = type == .battery ? 2 : 1
            let pitch = s * 0.3
            let start = r.midX - CGFloat(cells) * pitch / 2
            wire(r.minX, start)
            wire(start + CGFloat(cells) * pitch - pitch * 0.5, r.maxX)
            ctx.strokePath()
            for i in 0..<cells {
                let x = start + CGFloat(i) * pitch
                ctx.move(to: CGPoint(x: x, y: y - s * 0.38))
                ctx.addLine(to: CGPoint(x: x, y: y + s * 0.38))
                ctx.strokePath()
                ctx.fill(CGRect(x: x + pitch * 0.5 - 2.5, y: y - s * 0.19, width: 5, height: s * 0.38))
                if i < cells - 1 { wire(x + pitch * 0.5, x + pitch) }
            }
            ctx.strokePath()
        case .bulb:
            let radius = s * 0.3
            wire(r.minX, r.midX - radius)
            wire(r.midX + radius, r.maxX)
            ctx.strokePath()
            ctx.strokeEllipse(in: CGRect(x: r.midX - radius, y: y - radius, width: radius * 2, height: radius * 2))
            let k = radius * 0.7
            ctx.move(to: CGPoint(x: r.midX - k, y: y - k))
            ctx.addLine(to: CGPoint(x: r.midX + k, y: y + k))
            ctx.move(to: CGPoint(x: r.midX - k, y: y + k))
            ctx.addLine(to: CGPoint(x: r.midX + k, y: y - k))
            ctx.strokePath()
        case .switchOpen:
            wire(r.minX, left)
            wire(right, r.maxX)
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: left - 4, y: y - 4, width: 8, height: 8))
            ctx.fillEllipse(in: CGRect(x: right - 4, y: y - 4, width: 8, height: 8))
            ctx.move(to: CGPoint(x: left, y: y))
            ctx.addLine(to: CGPoint(x: right - s * 0.05, y: y - s * 0.4))
            ctx.strokePath()
        case .capacitor:
            let gap = s * 0.12
            wire(r.minX, r.midX - gap)
            wire(r.midX + gap, r.maxX)
            for x in [r.midX - gap, r.midX + gap] {
                ctx.move(to: CGPoint(x: x, y: y - s * 0.35))
                ctx.addLine(to: CGPoint(x: x, y: y + s * 0.35))
            }
            ctx.strokePath()
        case .diode:
            let w = s * 0.5
            wire(r.minX, r.midX - w / 2)
            wire(r.midX + w / 2, r.maxX)
            ctx.strokePath()
            ctx.move(to: CGPoint(x: r.midX - w / 2, y: y - w / 2))
            ctx.addLine(to: CGPoint(x: r.midX + w / 2, y: y))
            ctx.addLine(to: CGPoint(x: r.midX - w / 2, y: y + w / 2))
            ctx.closePath()
            ctx.strokePath()
            ctx.move(to: CGPoint(x: r.midX + w / 2, y: y - w / 2))
            ctx.addLine(to: CGPoint(x: r.midX + w / 2, y: y + w / 2))
            ctx.strokePath()
        default:
            // meters: a circle with their letter
            let radius = s * 0.32
            wire(r.minX, r.midX - radius)
            wire(r.midX + radius, r.maxX)
            ctx.strokePath()
            ctx.strokeEllipse(in: CGRect(x: r.midX - radius, y: y - radius, width: radius * 2, height: radius * 2))
            text(type == .ammeter ? "A" : "V", at: CGPoint(x: r.midX, y: y), size: radius, color: color, weight: .bold)
        }
        text(type.title, at: CGPoint(x: r.midX, y: r.maxY - r.height * 0.12), size: min(r.height * 0.16, 18), color: color.withAlphaComponent(0.8))
    }

    // Planning

    private static func calendar(_ d: Diagram, in r: CGRect, color: UIColor, _ ctx: CGContext) {
        let now = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let month = d.month ?? now.month ?? 1, year = d.year ?? now.year ?? 2026
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = cal.range(of: .day, in: .month, for: first)?.count else { return }
        // Monday-first column of the 1st
        let offset = (cal.component(.weekday, from: first) + 5) % 7
        let header = r.height * 0.14, names = r.height * 0.08
        let title = DateFormatter().monthSymbols[month - 1] + " \(year)"
        text(title, at: CGPoint(x: r.midX, y: r.minY + header / 2), size: header * 0.5, color: color, weight: .bold)
        let grid = CGRect(x: r.minX, y: r.minY + header + names, width: r.width, height: r.height - header - names)
        let cw = grid.width / 7, ch = grid.height / 6
        for (i, name) in ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].enumerated() {
            text(name, at: CGPoint(x: grid.minX + cw * (CGFloat(i) + 0.5), y: r.minY + header + names / 2), size: names * 0.5, color: color.withAlphaComponent(0.7), weight: .semibold)
        }
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1)
        for i in 0...7 {
            ctx.move(to: CGPoint(x: grid.minX + cw * CGFloat(i), y: grid.minY))
            ctx.addLine(to: CGPoint(x: grid.minX + cw * CGFloat(i), y: grid.maxY))
        }
        for j in 0...6 {
            ctx.move(to: CGPoint(x: grid.minX, y: grid.minY + ch * CGFloat(j)))
            ctx.addLine(to: CGPoint(x: grid.maxX, y: grid.minY + ch * CGFloat(j)))
        }
        ctx.strokePath()
        ctx.restoreGState()
        for day in 1...days {
            let slot = offset + day - 1
            let cellRect = CGRect(x: grid.minX + cw * CGFloat(slot % 7), y: grid.minY + ch * CGFloat(slot / 7), width: cw, height: ch)
            let corner = CGPoint(x: cellRect.minX + min(cw, ch) * 0.22, y: cellRect.minY + min(cw, ch) * 0.22)
            if day == now.day, month == now.month, year == now.year {
                let ring = min(cw, ch) * 0.18
                ctx.setFillColor(color.withAlphaComponent(0.18).cgColor)
                ctx.fillEllipse(in: CGRect(x: corner.x - ring, y: corner.y - ring, width: ring * 2, height: ring * 2))
            }
            text("\(day)", at: corner, size: min(cw, ch) * 0.2, color: color, weight: .semibold)
        }
    }

    // Text

    static func text(_ string: String, at p: CGPoint, size: CGFloat, color: UIColor, weight: UIFont.Weight = .regular, leading: Bool = false) {
        guard size > 1 else { return }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measured = (string as NSString).size(withAttributes: attrs)
        (string as NSString).draw(at: CGPoint(x: leading ? p.x : p.x - measured.width / 2, y: p.y - measured.height / 2), withAttributes: attrs)
    }

    /// Centred, wrapped text shrunk until it fits.
    private static func fitted(_ string: String, in size: CGSize, at center: CGPoint, color: UIColor) {
        guard !string.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        var points = min(size.height * 0.45, 28)
        while points > 8 {
            let base = UIFont.systemFont(ofSize: points, weight: .semibold)
            let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: points) } ?? base
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            let box = (string as NSString).boundingRect(with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                                                        options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
            if box.height <= size.height || points <= 9 {
                (string as NSString).draw(in: CGRect(x: center.x - size.width / 2, y: center.y - box.height / 2, width: size.width, height: box.height + 2),
                                          withAttributes: attrs)
                return
            }
            points -= 1
        }
    }
}
