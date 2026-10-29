import Observation
import SwiftUI

/// The shape being edited, shared by the canvas (handles) and the inspector (numbers).
@Observable
final class ShapeEditor {
    var shape: ShapeItem
    @ObservationIgnored var onCommit: ((ShapeItem) -> Void)?
    @ObservationIgnored var onDelete: (() -> Void)?

    init(shape: ShapeItem) {
        self.shape = shape
    }

    func apply(_ edit: (ShapeItem) -> ShapeItem) {
        let edited = edit(shape)
        guard edited != shape else { return }
        shape = edited
        onCommit?(shape)
    }
}

struct ShapeInspector: View {
    let editor: ShapeEditor
    private var shape: ShapeItem { editor.shape }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                switch shape.kind {
                case .polygon where shape.points.count == 3: triangle
                case .polygon: polygon
                case .polyline: polyline
                case .line: line
                case .ellipse: ellipse
                case .projectile: projectile
                case .graph: graph
                case .diagram: diagram
                }
                if shape.kind == .line || shape.kind == .polyline {
                    Toggle("Arrowhead", isOn: Binding(get: { shape.arrow ?? false }, set: { on in
                        editor.apply { var s = $0; s.arrow = on ? true : nil; return s }
                    }))
                    .font(.system(size: 15, weight: .semibold))
                }
                if shape.kind != .projectile, shape.kind != .graph, shape.kind != .diagram {
                    Toggle("Show Measurements", isOn: Binding(get: { shape.measures ?? false }, set: { on in
                        editor.apply { var s = $0; s.measures = on; return s }
                    }))
                    .font(.system(size: 15, weight: .semibold))
                }
                style
                Button(role: .destructive) { editor.onDelete?() } label: {
                    Label("Delete Shape", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
        }
        .frame(width: 340)
        .frame(minHeight: 300, maxHeight: 620)
        .background(Theme.paper)
    }

    private var title: String {
        switch shape.kind {
        case .polygon:
            switch shape.points.count {
            case 3: "Triangle"
            case 4: "Quadrilateral"
            case 5: "Pentagon"
            case 6: "Hexagon"
            default: "Polygon"
            }
        case .polyline: "Angle"
        case .line: shape.arrow == true ? "Arrow" : "Line"
        case .ellipse: (shape.radii.map { abs($0.width - $0.height) < 0.5 } ?? false) ? "Circle" : "Ellipse"
        case .projectile: "Projectile"
        case .graph: "Graph"
        case .diagram: shape.diagram?.type.title ?? "Diagram"
        }
    }

    // Kinds

    private var diagram: some View {
        let d = shape.diagram ?? Diagram(type: .process)
        return VStack(alignment: .leading, spacing: 12) {
            if d.type == .bohr {
                sectionTitle("Element")
                Picker("Element", selection: Binding(get: { d.element ?? 6 }, set: { z in setDiagram { $0.element = z } })) {
                    ForEach(Array(Elements.range), id: \.self) { z in
                        Text("\(z)  \(Elements.symbol(z))  \(Elements.name(z))").tag(z)
                    }
                }
                .pickerStyle(.menu)
                let z = d.element ?? 6
                Text("\(z) protons, \(Elements.mass(z) - z) neutrons, shells \(Elements.shells(z).map(String.init).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            if DiagramType.flowchart.contains(d.type) {
                sectionTitle("Text")
                TextField("Text", text: Binding(get: { d.label ?? "" }, set: { text in setDiagram { $0.label = text } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                typePicker(DiagramType.flowchart, current: d.type)
            }
            if DiagramType.gates.contains(d.type) {
                sectionTitle("Gate")
                typePicker(DiagramType.gates, current: d.type)
            }
            if DiagramType.circuit.contains(d.type) {
                sectionTitle("Component")
                typePicker(DiagramType.circuit, current: d.type)
            }
            if d.type == .calendar {
                let now = Calendar.current.dateComponents([.year, .month], from: Date())
                sectionTitle("Month")
                Picker("Month", selection: Binding(get: { d.month ?? now.month ?? 1 }, set: { m in setDiagram { $0.month = m } })) {
                    ForEach(1...12, id: \.self) { Text(DateFormatter().monthSymbols[$0 - 1]).tag($0) }
                }
                .pickerStyle(.menu)
                Stepper("Year \(String(d.year ?? now.year ?? 2026))", value: Binding(get: { d.year ?? now.year ?? 2026 }, set: { y in setDiagram { $0.year = y } }), in: 1900...2200)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text("Drag the round knobs to resize and turn it.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private func typePicker(_ types: [DiagramType], current: DiagramType) -> some View {
        Picker("Type", selection: Binding(get: { current }, set: { type in setDiagram { $0.type = type } })) {
            ForEach(types) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
    }

    private func setDiagram(_ edit: @escaping (inout Diagram) -> Void) {
        editor.apply { shape in
            var s = shape
            if var d = s.diagram {
                edit(&d)
                s.diagram = d
            }
            return s
        }
    }

    private var triangle: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Angles")
            ForEach(0..<3, id: \.self) { i in
                angleRow(["A", "B", "C"][i], value: shape.angles[safe: i] ?? 60) { value in
                    editor.apply { $0.settingTriangleAngle(i, to: value) }
                }
            }
            Text("Changing one angle keeps the other two in proportion, and side AB stays put.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
            sectionTitle("Make it")
            HStack(spacing: 8) {
                preset("Equilateral") { $0.withTriangleAngles(60, 60) }
                preset("Isosceles") { $0.isosceles() }
                preset("Right") { $0.rightAngled() }
            }
            sides
        }
    }

    private var polygon: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Angles")
            Text(shape.angles.enumerated().map { "\(Self.letter($0.offset)) \(Int($0.element.rounded()))\u{00B0}" }.joined(separator: "   "))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink)
            sectionTitle("Make it")
            HStack(spacing: 8) {
                preset(shape.points.count == 4 ? "Square" : "Regular") { $0.regularized() }
            }
            sides
        }
    }

    private var polyline: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Angles")
            ForEach(Array(shape.angles.enumerated()), id: \.offset) { i, value in
                Text("Corner \(i + 1): \(String(format: "%.1f", value))\u{00B0}")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
            }
            sides
        }
    }

    private var line: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Line")
            numberRow("Length", value: shape.sides.first ?? 0, unit: "cm", range: 0.2...80, step: 0.1) { length in
                editor.apply { s in
                    guard s.points.count == 2 else { return s }
                    var out = s
                    let a = s.points[0], b = s.points[1]
                    let current = hypot(b.x - a.x, b.y - a.y)
                    guard current > 0 else { return s }
                    let k = CGFloat(length / cmPerPoint) / current
                    out.points[1] = CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
                    return out
                }
            }
            angleRow("Angle", value: shape.lineAngle, range: -180...180) { degrees in
                editor.apply { s in
                    guard s.points.count == 2 else { return s }
                    var out = s
                    let a = s.points[0], b = s.points[1]
                    let length = hypot(b.x - a.x, b.y - a.y)
                    let r = CGFloat(degrees * .pi / 180)
                    out.points[1] = CGPoint(x: a.x + length * cos(r), y: a.y - length * sin(r))
                    return out
                }
            }
        }
    }

    private var ellipse: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Size")
            let r = shape.radii ?? .zero
            numberRow("Width", value: Double(r.width * 2) * cmPerPoint, unit: "cm", range: 0.2...80, step: 0.1) { value in
                editor.apply { var s = $0; s.radii?.width = CGFloat(value / cmPerPoint / 2); return s }
            }
            numberRow("Height", value: Double(r.height * 2) * cmPerPoint, unit: "cm", range: 0.2...80, step: 0.1) { value in
                editor.apply { var s = $0; s.radii?.height = CGFloat(value / cmPerPoint / 2); return s }
            }
            HStack(spacing: 8) {
                preset("Make Circle") { $0.circled() }
            }
        }
    }

    private var projectile: some View {
        let p = shape.projectile ?? Projectile()
        let f = shape.flight
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Launch")
            numberRow("Speed", value: p.speed, unit: "m/s", range: 1...200, step: 0.5) { v in setProjectile { $0.speed = v } }
            angleRow("Angle", value: p.angle, range: 0...90) { v in setProjectile { $0.angle = v } }
            numberRow("Height", value: p.height, unit: "m", range: 0...500, step: 0.5) { v in setProjectile { $0.height = v } }
            sectionTitle("Gravity")
            Picker("Gravity", selection: Binding(get: { p.gravity }, set: { g in setProjectile { $0.gravity = g } })) {
                Text("Earth").tag(9.81)
                Text("Moon").tag(1.62)
                Text("Mars").tag(3.71)
                Text("Jupiter").tag(24.79)
            }
            .pickerStyle(.segmented)
            numberRow("g", value: p.gravity, unit: "m/s\u{00B2}", range: 0.1...50, step: 0.01) { v in setProjectile { $0.gravity = v } }
            sectionTitle("Scale")
            numberRow("Drawing", value: p.scale, unit: "pt/m", range: 0.5...80, step: 0.5) { v in setProjectile { $0.scale = v } }
            sectionTitle("Results")
            VStack(alignment: .leading, spacing: 6) {
                result("Range", String(format: "%.2f m", f.range))
                result("Peak height", String(format: "%.2f m", f.peak))
                result("Time of flight", String(format: "%.2f s", f.time))
                result("Time to peak", String(format: "%.2f s", f.peakTime))
                let a = p.angle * .pi / 180
                result("Velocity x / y", String(format: "%.2f / %.2f m/s", p.speed * cos(a), p.speed * sin(a)))
            }
            Text("Drag the arrow to aim, drag the start point to move it.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private var graph: some View {
        let g = shape.graph ?? GraphSpec()
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Functions")
            ForEach(Array(g.functions.enumerated()), id: \.offset) { i, text in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: ShapeLayerView.curveColors[i % ShapeLayerView.curveColors.count]))
                        .frame(width: 10, height: 10)
                    Text("y =").foregroundStyle(Theme.muted)
                    TextField("2x^2 - 3", text: Binding(get: { text }, set: { value in setGraph { $0.functions[i] = value } }))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(FunctionParser.parse(text) == nil ? Color.red : Theme.ink)
                    Button(role: .destructive) { setGraph { $0.functions.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button { setGraph { $0.functions.append("x") } } label: { Label("Add Function", systemImage: "plus") }
                .buttonStyle(.bordered)
            Text("Use x, + - * / ^, sin cos tan, sqrt, abs, ln, log, exp, pi and e. 2x and 3sin(x) work too.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
            sectionTitle("Window")
            numberRow("x from", value: g.xMin, unit: "", range: -10000...10000, step: 1) { v in setGraph { $0.xMin = min(v, $0.xMax - 0.1) } }
            numberRow("x to", value: g.xMax, unit: "", range: -10000...10000, step: 1) { v in setGraph { $0.xMax = max(v, $0.xMin + 0.1) } }
            numberRow("y from", value: g.yMin, unit: "", range: -10000...10000, step: 1) { v in setGraph { $0.yMin = min(v, $0.yMax - 0.1) } }
            numberRow("y to", value: g.yMax, unit: "", range: -10000...10000, step: 1) { v in setGraph { $0.yMax = max(v, $0.yMin + 0.1) } }
            HStack(spacing: 8) {
                preset("Fit y") { s in
                    var out = s
                    if let fit = s.graph?.fittedY() {
                        out.graph?.yMin = fit.0
                        out.graph?.yMax = fit.1
                    }
                    return out
                }
                preset("Equal Scale") { s in
                    // same units per point on both axes, keeping y centred
                    var out = s
                    guard var g = s.graph else { return s }
                    let f = s.graphFrame
                    let perPoint = (g.xMax - g.xMin) / Double(f.width)
                    let mid = (g.yMin + g.yMax) / 2, half = perPoint * Double(f.height) / 2
                    g.yMin = mid - half
                    g.yMax = mid + half
                    out.graph = g
                    return out
                }
            }
            Text("Drag the corner handle to resize, drag the graph to move it.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private func setGraph(_ edit: @escaping (inout GraphSpec) -> Void) {
        editor.apply { s in
            var out = s
            var g = s.graph ?? GraphSpec()
            edit(&g)
            out.graph = g
            return out
        }
    }

    private func setProjectile(_ edit: @escaping (inout Projectile) -> Void) {
        editor.apply { s in
            var out = s
            var p = s.projectile ?? Projectile()
            edit(&p)
            out.projectile = p
            return out
        }
    }

    // Pieces

    private var sides: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Sides")
            Text(shape.sides.enumerated().map { i, len in
                let a = Self.letter(i), b = Self.letter((i + 1) % max(shape.points.count, 1))
                return "\(a)\(b) \(String(format: "%.1f", len)) cm"
            }.joined(separator: "   "))
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.ink)
        }
    }

    private var style: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Style")
            HStack {
                ColorPicker("Colour", selection: Binding(get: { Color(hex: shape.color) }, set: { c in
                    editor.apply { var s = $0; s.color = UIColor(c).hex; return s }
                }), supportsOpacity: false)
            }
            HStack {
                Text("Width").font(.system(size: 15))
                Slider(value: Binding(get: { Double(shape.width) }, set: { w in
                    editor.apply { var s = $0; s.width = CGFloat(w); return s }
                }), in: 0.5...16)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.muted)
            .textCase(.uppercase)
    }

    private func preset(_ title: String, _ edit: @escaping (ShapeItem) -> ShapeItem) -> some View {
        Button(title) { editor.apply(edit) }
            .buttonStyle(.bordered)
            .font(.system(size: 14, weight: .semibold))
    }

    private func result(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).foregroundStyle(Theme.ink).monospacedDigit()
        }
        .font(.system(size: 15, weight: .semibold, design: .rounded))
    }

    private func angleRow(_ name: String, value: Double, range: ClosedRange<Double> = 1...178, set: @escaping (Double) -> Void) -> some View {
        numberRow(name, value: value, unit: "\u{00B0}", range: range, step: 1, set: set)
    }

    /// Label, typed value and a stepper.
    private func numberRow(_ name: String, value: Double, unit: String, range: ClosedRange<Double>, step: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 70, alignment: .leading)
            // the field writes back its own rounded value when the shape redraws; only real changes count
            TextField(name, value: Binding(get: { (value / step).rounded() * step }, set: { typed in
                let clamped = min(max(typed, range.lowerBound), range.upperBound)
                if abs(clamped - value) >= step / 2 { set(clamped) }
            }),
                      format: .number.precision(.fractionLength(step < 1 ? (step < 0.1 ? 2 : 1) : 0)))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
            Text(unit).foregroundStyle(Theme.muted).font(.system(size: 14))
            Spacer()
            Stepper(name, onIncrement: { set(min(value + step, range.upperBound)) }, onDecrement: { set(max(value - step, range.lowerBound)) })
                .labelsHidden()
        }
    }

    private static func letter(_ i: Int) -> String {
        String(Character(UnicodeScalar(UInt8(65 + i % 26))))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
