import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Owns one PKCanvasView: shared tools, finger-tap undo/redo, scribble-to-erase and hold-to-shape.
final class InkController: NSObject, PKCanvasViewDelegate {
    static let toolPicker = PKToolPicker()

    let canvas = PKCanvasView()
    var onChange: ((PKDrawing) -> Void)?
    var onZoom: (() -> Void)?
    /// Whether a scribble over this area would erase non-ink content (e.g. text boxes).
    var extrasHit: ((CGRect) -> Bool)?
    var eraseExtras: ((CGRect) -> Void)?
    /// Takes over a snapped shape as an editable vector shape; returns false to keep it as ink.
    var onShapeBegin: ((ShapeOutline, PKTool) -> Bool)?
    var onShapeChange: ((ShapeOutline) -> Void)?
    var onShapeEnd: (() -> Void)?
    /// False keeps fingers for scrolling whatever the settings say (PDF pages).
    var fingerAllowed = true {
        didSet { applyTools() }
    }
    /// Sticks with our pen strip even when Apple's picker is chosen (covers).
    var ownStrip = false {
        didSet { applyTools() }
    }

    private var suppress = false
    private var strokeCount = 0
    private var usedSystemPicker: Bool?
    private var holdWork: DispatchWorkItem?
    private var lastMove: CGPoint?
    private let tracker = TouchTracker(target: nil, action: nil)
    /// The current stroke's path in drawing coordinates, recorded ourselves since PencilKit hides it until lift.
    private var trace: [CGPoint] = []
    private var tracing = false
    private var live: LiveShape?
    /// Stroke count right after a snap, to catch PencilKit committing the stroke we cut short.
    private var snapCount: Int?

    /// A shape snapped mid-stroke that follows the pencil until it lifts.
    private struct LiveShape {
        var base: [PKStroke]
        var outline: ShapeOutline
        var template: PKStroke?
        var tool: PKTool
        var anchor: CGPoint
        /// Handed to `onShapeBegin` rather than drawn as a stroke.
        var vector: Bool
    }

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
        tracker.onMove = { [weak self] point in self?.pencilMoved(to: point) }
        tracker.onEnd = { [weak self] in self?.pencilLifted() }
        canvas.addGestureRecognizer(tracker)

        InkTools.shared.register(self)
        applyTools()
    }

    /// Picks up the current pen, or hands the canvas to Apple's tool picker when undocked.
    func applyTools() {
        let tools = InkTools.shared
        let picker = Self.toolPicker
        if tools.systemPicker && !ownStrip {
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.tool = picker.selectedTool
            canvas.drawingPolicy = fingerAllowed ? .default : .pencilOnly
        } else {
            picker.setVisible(false, forFirstResponder: canvas)
            picker.removeObserver(canvas)
            canvas.tool = tools.tool
            canvas.drawingPolicy = fingerAllowed && tools.fingerDraws ? .anyInput : .pencilOnly
            canvas.isRulerActive = tools.ruler
        }
        // the picker only shows or hides when the first responder changes
        let system = tools.systemPicker && !ownStrip
        if usedSystemPicker != nil, usedSystemPicker != system, canvas.isFirstResponder {
            canvas.resignFirstResponder()
            canvas.becomeFirstResponder()
        }
        usedSystemPicker = system
        let types: [UITouch.TouchType] = pencilOnly ? [.pencil] : [.pencil, .direct]
        tracker.allowedTouchTypes = types.map { $0.rawValue as NSNumber }
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
        guard let added, !replaying else { return }
        if let snapCount, strokes.count == snapCount + 1 {
            // PencilKit kept the stroke we cut short; the shape already replaced it
            self.snapCount = nil
            DispatchQueue.main.async { [weak self] in self?.dropPencilKitStep(leaving: snapCount) }
        } else if added.ink.inkType != .marker, InkAnalyzer.isScribble(added) {
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

        dropPencilKitStep(leaving: strokes.count)
        let kept = strokes.enumerated().filter { !hit.contains($0.offset) }.map(\.element)
        commit(PKDrawing(strokes: kept), name: "Scribble Erase")
        eraseExtras?(area)
    }

    /// Undoes PencilKit's own "add stroke" step so our replacement undoes cleanly.
    private func dropPencilKitStep(leaving count: Int) {
        suppress = true
        canvas.undoManager?.undo()
        if canvas.drawing.strokes.count != count {
            canvas.undoManager?.redo()
        }
        suppress = false
        strokeCount = canvas.drawing.strokes.count
    }

    @objc private func drawingGesture(_ gesture: UIGestureRecognizer) {
        switch gesture.state {
        case .began:
            // whichever canvas the pencil touches gets the tools and undo
            activate()
            let point = gesture.location(in: canvas)
            live = nil
            snapCount = nil
            tracing = true
            trace = [drawingPoint(point)]
            lastMove = point
            scheduleHold()
        case .ended, .cancelled, .failed:
            if live == nil {
                tracing = false
                holdWork?.cancel()
            }
        default:
            break
        }
    }

    private func drawingPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / canvas.zoomScale, y: point.y / canvas.zoomScale)
    }

    private func pencilMoved(to point: CGPoint) {
        if live != nil {
            reshape(to: drawingPoint(point))
            return
        }
        guard tracing else { return }
        trace.append(drawingPoint(point))
        guard let last = lastMove, hypot(point.x - last.x, point.y - last.y) > 5 else { return }
        lastMove = point
        scheduleHold()
    }

    private func pencilLifted() {
        tracing = false
        holdWork?.cancel()
        if live?.vector == true { onShapeEnd?() }
        live = nil
    }

    /// Restarts the stillness timer; half a second without moving snaps the stroke.
    private func scheduleHold() {
        holdWork?.cancel()
        guard InkTools.shared.holdShapes, canvas.tool is PKInkingTool else { return }
        let work = DispatchWorkItem { [weak self] in self?.snapLive() }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func snapLive() {
        guard tracing, let outline = ShapeRecognizer.outline(for: trace) else { return }
        let base = canvas.drawing.strokes
        let tool = canvas.tool
        // end PencilKit's stroke here; from now on the pencil drives the shape
        suppress = true
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.drawingGestureRecognizer.isEnabled = true
        suppress = false
        tracing = false

        // PencilKit may keep the cut-short stroke or drop it; either way the shape takes its place
        var template: PKStroke?
        if canvas.drawing.strokes.count == base.count + 1 {
            template = canvas.drawing.strokes.last
            dropPencilKitStep(leaving: base.count)
        }
        let anchor = trace.last ?? .zero
        if onShapeBegin?(outline, tool) == true {
            snapCount = base.count
            live = LiveShape(base: base, outline: outline, template: template, tool: tool, anchor: anchor, vector: true)
        } else {
            guard let shape = ShapeRecognizer.stroke(outline, like: template, tool: tool) else { return }
            commit(PKDrawing(strokes: base + [shape]), name: "Shape")
            snapCount = base.count + 1
            live = LiveShape(base: base, outline: outline, template: template, tool: tool, anchor: anchor, vector: false)
        }
        // a tick on Pencil Pro so you feel the snap
        UICanvasFeedbackGenerator(view: canvas).alignmentOccurred(at: lastMove ?? .zero)
    }

    private func reshape(to point: CGPoint) {
        guard let live else { return }
        if live.vector {
            onShapeChange?(live.outline.adjusted(from: live.anchor, to: point))
            return
        }
        guard let shape = ShapeRecognizer.stroke(live.outline.adjusted(from: live.anchor, to: point), like: live.template, tool: live.tool) else { return }
        // the snap's undo step restores the drawing from before the shape, so tweaks need no steps of their own
        let drawing = PKDrawing(strokes: live.base + [shape])
        load(drawing)
        onChange?(drawing)
    }

    @objc private func undoTap() {
        canvas.undoManager?.undo()
    }

    @objc private func redoTap() {
        canvas.undoManager?.redo()
    }
}

/// Follows the drawing touch without claiming it, so a snapped shape keeps tracking the pencil.
final class TouchTracker: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onMove: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    private weak var touch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touch == nil { touch = touches.first }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        onMove?(touch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        onEnd?()
        state = .failed
    }

    override func reset() {
        touch = nil
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
