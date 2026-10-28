import PencilKit
import SwiftUI
import UIKit

/// Lets toolbar actions reach the live canvas (e.g. to place things where the user is looking).
final class CanvasHandle {
    weak var view: NoteCanvasView?
}

struct NoteCanvas: UIViewRepresentable {
    let store: NotebookStore
    let page: NotePage
    @Binding var convertMode: Bool
    let handle: CanvasHandle
    let onOpenLink: (NoteLink) -> Void

    func makeUIView(context: Context) -> NoteCanvasView {
        let view = NoteCanvasView()
        handle.view = view
        return view
    }

    func updateUIView(_ view: NoteCanvasView, context: Context) {
        let id = page.id
        view.onDrawingChange = { [store] in store.setDrawing($0, for: id) }
        view.onEditPage = { [store] change in store.update(id, change) }
        view.onLinkTap = onOpenLink
        view.onConvertDone = { convertMode = false }
        view.convertMode = convertMode
        view.show(page, paper: store.notebook.paper) { store.drawing(for: id) }
    }
}

/// One notebook page: paper, ink, and an overlay of text boxes and link chips, all zooming together.
final class NoteCanvasView: UIView {
    var onDrawingChange: ((PKDrawing) -> Void)?
    var onEditPage: (((inout NotePage) -> Void) -> Void)?
    var onLinkTap: ((NoteLink) -> Void)?
    var onConvertDone: (() -> Void)?

    var convertMode = false {
        didSet {
            guard convertMode != oldValue else { return }
            selectionGesture.isEnabled = convertMode
            canvas.drawingGestureRecognizer.isEnabled = !convertMode
            canvas.isScrollEnabled = !convertMode
        }
    }

    private let ink = InkController()
    private var canvas: PKCanvasView { ink.canvas }
    private let paper = PaperView()
    private let overlay = PassthroughView()
    private let selectionLayer = CAShapeLayer()
    private lazy var selectionGesture = UIPanGestureRecognizer(target: self, action: #selector(selectionPan(_:)))
    private var selectionStart = CGPoint.zero
    private var page: NotePage?
    private var boxViews: [UUID: UIView] = [:]
    private var fittedWidth: CGFloat = 0
    private var pendingMath: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.contentInsetAdjustmentBehavior = .never
        addSubview(canvas)

        paper.bounds = CGRect(origin: .zero, size: notebookPageSize)
        overlay.bounds = paper.bounds
        canvas.insertSubview(paper, at: 0)
        canvas.addSubview(overlay)

        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.lineDashPattern = [6, 4]
        overlay.layer.addSublayer(selectionLayer)

        selectionGesture.isEnabled = false
        canvas.addGestureRecognizer(selectionGesture)

        ink.onChange = { [weak self] drawing in
            self?.onDrawingChange?(drawing)
            self?.scheduleMath()
        }
        ink.onZoom = { [weak self] in self?.syncZoom() }
        ink.extrasHit = { [weak self] area in !(self?.boxes(in: area).isEmpty ?? true) }
        ink.eraseExtras = { [weak self] area in
            guard let self else { return }
            for box in self.boxes(in: area) { self.removeTextBox(box) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ page: NotePage, paper style: PaperStyle, drawing: () -> PKDrawing) {
        if page.id != self.page?.id {
            ink.load(drawing())
            // undo steps belong to the previous page
            canvas.undoManager?.removeAllActions()
            canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: 0), animated: false)
        }
        self.page = page
        paper.style = style
        rebuildOverlay()
    }

    func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addTextBox(TextBox(text: trimmed, origin: visibleCenter()))
    }

    func addLink(_ target: LinkTarget, label: String) {
        let link = NoteLink(target: target, label: label, position: visibleCenter())
        onEditPage?({ page in page.links.append(link) })
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { canvas.becomeFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != fittedWidth else { return }
        fittedWidth = bounds.width
        let fit = bounds.width / notebookPageSize.width
        canvas.minimumZoomScale = fit * 0.5
        canvas.maximumZoomScale = fit * 4
        canvas.zoomScale = fit
        syncZoom()
    }

    private func syncZoom() {
        let zoom = canvas.zoomScale
        let size = CGSize(width: notebookPageSize.width * zoom, height: notebookPageSize.height * zoom)
        canvas.contentSize = size
        for view in [paper, overlay] as [UIView] {
            view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            view.center = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let inset = max(0, (canvas.bounds.width - size.width) / 2)
        canvas.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        // sharper ruling when zoomed, capped to keep the backing store small
        paper.contentScaleFactor = min(traitCollection.displayScale * zoom, 3)
        paper.setNeedsDisplay()
        canvas.bringSubviewToFront(overlay)
    }

    private func visibleCenter() -> CGPoint {
        canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: overlay)
    }

    // Overlay

    private func rebuildOverlay() {
        overlay.subviews.forEach { $0.removeFromSuperview() }
        boxViews.removeAll()
        guard let page else { return }
        for box in page.textBoxes {
            let view = textBoxView(box)
            boxViews[box.id] = view
            overlay.addSubview(view)
        }
        for link in page.links {
            overlay.addSubview(linkChip(link))
        }
        canvas.bringSubviewToFront(overlay)
    }

    private func textBoxView(_ box: TextBox) -> UIView {
        let button = UIButton(type: .custom)
        let font = UIFont(name: "Noteworthy-Light", size: box.fontSize) ?? .systemFont(ofSize: box.fontSize)
        let color: UIColor = box.anchor == nil ? .black : .systemBlue
        button.setAttributedTitle(NSAttributedString(string: box.text, attributes: [.font: font, .foregroundColor: color]), for: .normal)
        button.titleLabel?.numberOfLines = 0
        button.contentHorizontalAlignment = .leading
        button.menu = UIMenu(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = box.text
            },
            UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.edit(box)
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.removeTextBox(box)
            },
        ])
        button.showsMenuAsPrimaryAction = true
        button.sizeToFit()
        if let anchor = box.anchor {
            button.frame.origin = CGPoint(x: anchor.x, y: anchor.y - button.bounds.height / 2)
        } else {
            button.frame.origin = box.origin
        }
        return button
    }

    private func linkChip(_ link: NoteLink) -> UIView {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "link")
        config.imagePadding = 4
        config.title = link.label
        config.cornerStyle = .capsule
        config.buttonSize = .small
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.onLinkTap?(link)
        })
        button.menu = UIMenu(children: [
            UIAction(title: "Remove Link", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.onEditPage?({ page in page.links.removeAll { $0.id == link.id } })
            },
        ])
        button.sizeToFit()
        button.center = link.position
        return button
    }

    private func boxes(in area: CGRect) -> [TextBox] {
        guard let page else { return [] }
        return page.textBoxes.filter { box in
            guard let frame = boxViews[box.id]?.frame else { return false }
            let overlap = frame.intersection(area)
            return !overlap.isNull && overlap.width * overlap.height >= frame.width * frame.height * 0.4
        }
    }

    private func edit(_ box: TextBox) {
        let alert = UIAlertController(title: "Edit Text", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = box.text }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
            var updated = box
            updated.text = text
            self?.replaceTextBox(box, with: updated)
        })
        viewController?.present(alert, animated: true)
    }

    private var viewController: UIViewController? {
        sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
    }

    // Undoable text box edits

    private func addTextBox(_ box: TextBox) {
        onEditPage?({ page in page.textBoxes.append(box) })
        canvas.undoManager?.registerUndo(withTarget: self) { $0.removeTextBox(box) }
    }

    private func removeTextBox(_ box: TextBox) {
        onEditPage?({ page in page.textBoxes.removeAll { $0.id == box.id } })
        canvas.undoManager?.registerUndo(withTarget: self) { $0.addTextBox(box) }
    }

    private func replaceTextBox(_ old: TextBox, with new: TextBox) {
        onEditPage?({ page in
            if let i = page.textBoxes.firstIndex(where: { $0.id == old.id }) { page.textBoxes[i] = new }
        })
        canvas.undoManager?.registerUndo(withTarget: self) { $0.replaceTextBox(new, with: old) }
    }

    // Handwriting to text

    @objc private func selectionPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            let t = gesture.translation(in: overlay)
            selectionStart = CGPoint(x: point.x - t.x, y: point.y - t.y)
        case .changed:
            selectionLayer.path = UIBezierPath(rect: Self.rect(selectionStart, point)).cgPath
        case .ended:
            selectionLayer.path = nil
            convertStrokes(in: Self.rect(selectionStart, point))
            onConvertDone?()
        default:
            selectionLayer.path = nil
        }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func convertStrokes(in rect: CGRect) {
        let drawing = canvas.drawing
        let picked = drawing.strokes.indices.filter {
            let r = drawing.strokes[$0].renderBounds
            return rect.contains(CGPoint(x: r.midX, y: r.midY))
        }
        guard !picked.isEmpty, let pageID = page?.id else { return }
        let chosen = picked.map { drawing.strokes[$0] }
        let bounds = chosen.reduce(CGRect.null) { $0.union($1.renderBounds) }

        HandwritingRecognizer.recognize(InkAnalyzer.image(of: chosen, in: bounds), forMath: false) { [weak self] texts in
            guard let self, self.page?.id == pageID,
                  self.canvas.drawing.strokes.count == drawing.strokes.count,
                  let text = texts.first, !text.isEmpty else { return }
            let lines = CGFloat(max(text.components(separatedBy: "\n").count, 1))
            let box = TextBox(text: text, origin: bounds.origin, fontSize: min(max(bounds.height / lines * 0.7, 14), 64))
            let pickedSet = IndexSet(picked)
            let kept = drawing.strokes.enumerated().filter { !pickedSet.contains($0.offset) }.map(\.element)
            self.ink.commit(PKDrawing(strokes: kept), name: "Convert to Text")
            self.addTextBox(box)
        }
    }

    // Live math

    private func scheduleMath() {
        pendingMath?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.solveMath() }
        pendingMath = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func solveMath() {
        guard let pageID = page?.id else { return }
        let equations = InkAnalyzer.equations(in: canvas.drawing.strokes)
        let hasResults = page?.textBoxes.contains { $0.anchor != nil } ?? false
        guard !equations.isEmpty || hasResults else { return }

        var answers: [Int: String] = [:]
        let group = DispatchGroup()
        for (i, equation) in equations.enumerated() {
            group.enter()
            HandwritingRecognizer.recognize(equation.image, forMath: true) { texts in
                answers[i] = texts.lazy.compactMap(MathEvaluator.evaluate).first
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, let current = self.page, current.id == pageID else { return }
            var updated = current
            Self.reconcileResults(&updated, equations: equations, answers: answers)
            if updated != current {
                self.onEditPage?({ page in page = updated })
            }
        }
    }

    /// Updates answers in place, adds new ones, and drops answers whose "=" is gone.
    private static func reconcileResults(_ page: inout NotePage, equations: [InkAnalyzer.Equation], answers: [Int: String]) {
        var matched = Set<UUID>()
        for (i, equation) in equations.enumerated() {
            let existing = page.textBoxes.firstIndex { box in
                guard let anchor = box.anchor else { return false }
                return abs(anchor.x - equation.anchor.x) < 24 && abs(anchor.y - equation.anchor.y) < 24
            }
            if let existing {
                matched.insert(page.textBoxes[existing].id)
                if let answer = answers[i] {
                    page.textBoxes[existing].text = answer
                    page.textBoxes[existing].anchor = equation.anchor
                }
            } else if let answer = answers[i] {
                let box = TextBox(text: answer, origin: equation.anchor, fontSize: equation.fontSize, anchor: equation.anchor)
                matched.insert(box.id)
                page.textBoxes.append(box)
            }
        }
        page.textBoxes.removeAll { $0.anchor != nil && !matched.contains($0.id) }
    }
}

/// Ruled paper drawn in page coordinates.
final class PaperView: UIView {
    var style: PaperStyle = .lined {
        didSet { if style != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let spacing: CGFloat = 40
        let line = UIColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 0.55)
        switch style {
        case .blank:
            return
        case .lined:
            ctx.setStrokeColor(line.cgColor)
            ctx.setLineWidth(1)
            for y in stride(from: spacing * 2, to: bounds.height, by: spacing) {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            ctx.strokePath()
        case .grid:
            ctx.setStrokeColor(line.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1)
            for x in stride(from: spacing, to: bounds.width, by: spacing) {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            for y in stride(from: spacing, to: bounds.height, by: spacing) {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(line.cgColor)
            for x in stride(from: spacing, to: bounds.width, by: spacing) {
                for y in stride(from: spacing, to: bounds.height, by: spacing) {
                    ctx.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                }
            }
        }
    }
}

/// Only its subviews take touches; everything else falls through to the canvas.
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
