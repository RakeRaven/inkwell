import PencilKit
import UIKit

/// Owns one PKCanvasView: shared tools, finger-tap undo/redo, and scribble-to-erase.
final class InkController: NSObject, PKCanvasViewDelegate {
    static let toolPicker = PKToolPicker()

    let canvas = PKCanvasView()
    var onChange: ((PKDrawing) -> Void)?
    var onZoom: (() -> Void)?
    /// Whether a scribble over this area would erase non-ink content (e.g. text boxes).
    var extrasHit: ((CGRect) -> Bool)?
    var eraseExtras: ((CGRect) -> Void)?
    /// False keeps fingers for scrolling whatever the settings say (PDF pages).
    var fingerAllowed = true {
        didSet { applyTools() }
    }

    private var suppress = false
    private var strokeCount = 0

    override init() {
        super.init()
        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // pages are white paper, so keep ink colors un-inverted in dark mode
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(drawingGesture(_:)))

        let undo = UITapGestureRecognizer(target: self, action: #selector(undoTap))
        undo.numberOfTouchesRequired = 2
        let redo = UITapGestureRecognizer(target: self, action: #selector(redoTap))
        redo.numberOfTouchesRequired = 3
        for tap in [undo, redo] {
            tap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            canvas.addGestureRecognizer(tap)
        }
        InkTools.shared.register(self)
        applyTools()
    }

    /// Picks up the current pen, or hands the canvas to Apple's tool picker when undocked.
    func applyTools() {
        let tools = InkTools.shared
        let picker = Self.toolPicker
        if tools.systemPicker {
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.tool = picker.selectedTool
            canvas.drawingPolicy = fingerAllowed ? .default : .pencilOnly
        } else {
            picker.setVisible(false, forFirstResponder: canvas)
            picker.removeObserver(canvas)
            canvas.tool = tools.tool
            canvas.drawingPolicy = fingerAllowed && tools.fingerDraws ? .anyInput : .pencilOnly
        }
    }

    /// Whether fingers are free for gestures instead of drawing.
    var pencilOnly: Bool {
        canvas.drawingPolicy == .pencilOnly || (canvas.drawingPolicy == .default && UIPencilInteraction.prefersPencilOnlyDrawing)
    }

    func activate() {
        InkTools.shared.active = self
        if !canvas.isFirstResponder { canvas.becomeFirstResponder() }
    }

    /// Shows a drawing without notifying or recording undo.
    func load(_ drawing: PKDrawing) {
        suppress = true
        canvas.drawing = drawing
        suppress = false
        strokeCount = drawing.strokes.count
    }

    /// Replaces the drawing as one undoable step.
    func commit(_ drawing: PKDrawing, name: String) {
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { $0.commit(old, name: name) }
        canvas.undoManager?.setActionName(name)
        load(drawing)
        onChange?(drawing)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !suppress else { return }
        let strokes = canvasView.drawing.strokes
        let added = strokes.count == strokeCount + 1 ? strokes.last : nil
        strokeCount = strokes.count
        onChange?(canvasView.drawing)

        let replaying = canvasView.undoManager.map { $0.isUndoing || $0.isRedoing } ?? false
        if let added, !replaying, added.ink.inkType != .marker, InkAnalyzer.isScribble(added) {
            // let PencilKit finish registering the stroke before touching undo
            DispatchQueue.main.async { [weak self] in self?.eraseScribble(expectedCount: strokes.count) }
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        InkTools.shared.active = self
        InkTools.shared.strokeBegan()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        InkTools.shared.strokeEnded()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        onZoom?()
    }

    private func eraseScribble(expectedCount: Int) {
        var strokes = canvas.drawing.strokes
        guard strokes.count == expectedCount, let scribble = strokes.popLast() else { return }
        let area = scribble.renderBounds
        let hit = InkAnalyzer.covered(by: scribble, in: strokes)
        guard !hit.isEmpty || extrasHit?(area) == true else { return }

        // drop PencilKit's own "add stroke" step so undo restores cleanly
        suppress = true
        canvas.undoManager?.undo()
        if canvas.drawing.strokes.count != strokes.count {
            canvas.undoManager?.redo()
        }
        suppress = false

        let kept = strokes.enumerated().filter { !hit.contains($0.offset) }.map(\.element)
        commit(PKDrawing(strokes: kept), name: "Scribble Erase")
        eraseExtras?(area)
    }

    @objc private func drawingGesture(_ gesture: UIGestureRecognizer) {
        // whichever canvas the pencil touches gets the tools and undo
        if gesture.state == .began { activate() }
    }

    @objc private func undoTap() {
        canvas.undoManager?.undo()
    }

    @objc private func redoTap() {
        canvas.undoManager?.redo()
    }
}
