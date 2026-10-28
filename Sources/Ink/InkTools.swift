import Observation
import PencilKit
import UIKit

enum PenKind: String, Codable, CaseIterable, Identifiable {
    case fountain, ball, brush, pencil, highlighter, eraser, lasso

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fountain: "Fountain Pen"
        case .ball: "Ball Pen"
        case .brush: "Brush Pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        }
    }

    var symbol: String {
        switch self {
        case .fountain: "pencil.tip"
        case .ball: "pencil.line"
        case .brush: "paintbrush.pointed"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }

    var inkType: PKInkingTool.InkType? {
        switch self {
        case .fountain: .fountainPen
        case .ball: .monoline
        case .brush: .pen
        case .pencil: .pencil
        case .highlighter: .marker
        case .eraser, .lasso: nil
        }
    }

    var widths: [CGFloat] {
        switch self {
        case .fountain: [1.5, 3, 5]
        case .ball: [1, 2, 3.5]
        case .brush: [3, 6, 11]
        case .pencil: [1.5, 3, 6]
        case .highlighter: [10, 18, 30]
        case .eraser: [8, 20, 40]
        case .lasso: []
        }
    }

    /// Range for the fine-tune slider.
    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .fountain: 0.5...12
        case .ball: 0.5...8
        case .brush: 1...24
        case .pencil: 0.5...16
        case .highlighter: 4...50
        case .eraser: 4...80
        case .lasso: 1...1
        }
    }

    var defaultColors: [String] {
        switch self {
        case .highlighter: ["FFE45C", "8EF08A", "FF9ECF", "8CCBFF"]
        case .eraser, .lasso: []
        default: ["1C1C1E", "1F4E9C", "C8322D", "2E8B57"]
        }
    }
}

struct PenSettings: Codable, Equatable {
    var colors: [String]
    var colorIndex = 0
    var widthIndex = 1
    /// Older saves kept three preset sizes; `width` replaces them.
    var widths: [CGFloat]?
    var width: CGFloat?
}

/// Pen state shared by every canvas, plus the compact toolbar's preferences.
@Observable
final class InkTools {
    static let shared = InkTools()
    private static let key = "inkTools"

    private struct Saved: Codable {
        var pen: PenKind
        var settings: [String: PenSettings]
        var pixelEraser: Bool
        var fingerDraws: Bool
        var systemPicker: Bool
        var autoHide: Bool
        var atBottom: Bool
        var holdShapes: Bool?
    }

    private(set) var pen: PenKind = .fountain
    private(set) var settings: [String: PenSettings] = [:]
    private(set) var pixelEraser = false
    private(set) var fingerDraws = false
    /// Undocked: Apple's own tool picker instead of the strip.
    private(set) var systemPicker = false
    private(set) var autoHide = true
    private(set) var atBottom = false
    /// Hold the pencil still at the end of a stroke to snap it into a shape.
    private(set) var holdShapes = true
    /// PencilKit's ruler: two fingers move and turn it, strokes along its edge come out straight.
    private(set) var ruler = false
    /// Strip folded into a small pill (grip button or Pencil squeeze).
    var collapsed = false
    private(set) var hiddenWhileDrawing = false

    @ObservationIgnored private var previousPen: PenKind = .fountain
    @ObservationIgnored private let canvases = NSHashTable<InkController>.weakObjects()
    @ObservationIgnored private var reveal: DispatchWorkItem?
    /// Canvas that last took the pencil; undo/redo go to it.
    @ObservationIgnored weak var active: InkController?

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        pen = saved.pen
        settings = saved.settings
        pixelEraser = saved.pixelEraser
        fingerDraws = saved.fingerDraws
        systemPicker = saved.systemPicker
        autoHide = saved.autoHide
        atBottom = saved.atBottom
        holdShapes = saved.holdShapes ?? true
    }

    func settings(for pen: PenKind) -> PenSettings {
        settings[pen.rawValue] ?? PenSettings(colors: pen.defaultColors)
    }

    var current: PenSettings { settings(for: pen) }

    var widths: [CGFloat] {
        let custom = current.widths ?? []
        return custom.count == pen.widths.count ? custom : pen.widths
    }

    var width: CGFloat {
        if let width = current.width { return width }
        let all = widths
        return all.indices.contains(current.widthIndex) ? all[current.widthIndex] : all.first ?? 1
    }

    var tool: PKTool {
        let s = current
        switch pen {
        case .eraser:
            return pixelEraser ? PKEraserTool(.bitmap, width: width) : PKEraserTool(.vector)
        case .lasso:
            return PKLassoTool()
        default:
            let hex = s.colors.indices.contains(s.colorIndex) ? s.colors[s.colorIndex] : "000000"
            return PKInkingTool(pen.inkType ?? .pen, color: UIColor(hex: hex), width: width)
        }
    }

    func register(_ ink: InkController) {
        canvases.add(ink)
    }

    func select(_ newPen: PenKind) {
        change {
            guard newPen != pen else { return }
            previousPen = pen
            pen = newPen
        }
    }

    func setColor(index: Int) {
        change { settings[pen.rawValue] = with(current) { $0.colorIndex = index } }
    }

    /// Replaces the selected color slot.
    func setCustomColor(_ color: UIColor) {
        change {
            settings[pen.rawValue] = with(current) {
                if $0.colors.indices.contains($0.colorIndex) { $0.colors[$0.colorIndex] = color.hex }
            }
        }
    }

    func setWidthValue(_ value: CGFloat) {
        let range = pen.widthRange
        let clamped = min(max((value * 10).rounded() / 10, range.lowerBound), range.upperBound)
        change { settings[pen.rawValue] = with(current) { $0.width = clamped } }
    }

    func setPixelEraser(_ on: Bool) { change { pixelEraser = on } }
    func setFingerDraws(_ on: Bool) { change { fingerDraws = on } }
    func setSystemPicker(_ on: Bool) { change { systemPicker = on } }
    func setAutoHide(_ on: Bool) { change { autoHide = on } }
    func setAtBottom(_ on: Bool) { change { atBottom = on } }
    func setHoldShapes(_ on: Bool) { change { holdShapes = on } }
    func toggleRuler() { change { ruler.toggle() } }

    func undo() { active?.canvas.undoManager?.undo() }
    func redo() { active?.canvas.undoManager?.redo() }

    func strokeBegan() {
        reveal?.cancel()
        if autoHide, !systemPicker, !hiddenWhileDrawing { hiddenWhileDrawing = true }
    }

    func strokeEnded() {
        guard hiddenWhileDrawing else { return }
        reveal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hiddenWhileDrawing = false }
        reveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Pencil double-tap, following the user's system setting.
    func pencilTapped() {
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser: select(pen == .eraser ? previousPen : .eraser)
        case .switchPrevious: select(previousPen)
        case .ignore: break
        default: collapsed.toggle()
        }
    }

    private func with(_ value: PenSettings, _ edit: (inout PenSettings) -> Void) -> PenSettings {
        var copy = value
        edit(&copy)
        return copy
    }

    private func change(_ edit: () -> Void) {
        edit()
        let saved = Saved(pen: pen, settings: settings, pixelEraser: pixelEraser, fingerDraws: fingerDraws,
                          systemPicker: systemPicker, autoHide: autoHide, atBottom: atBottom, holdShapes: holdShapes)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        for ink in canvases.allObjects { ink.applyTools() }
    }
}
