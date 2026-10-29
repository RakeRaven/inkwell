import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// What a finger or pencil does on the page besides drawing.
enum CanvasMode {
    case draw
    /// Drag a box over handwriting to restyle it or turn it into text.
    case convert
    /// Drag a box over handwriting or text to link it.
    case link
    /// Move, resize and delete images, text and links.
    case arrange
}

/// Ready-made shapes for the insert menu.
enum ShapePreset {
    case equilateral, rightTriangle, square, circle, line, arrow, angle, projectile, graph
    case diagram(DiagramType)
}

/// Lets toolbar actions reach the live canvas (e.g. to place things where the user is looking).
final class CanvasHandle {
    weak var view: NoteCanvasView?
}

struct NoteCanvas: UIViewRepresentable {
    let store: NotebookStore
    let page: NotePage
    @Binding var mode: CanvasMode
    let handle: CanvasHandle
    let onOpenLink: (NoteLink) -> Void
    /// Swipe by -1/+1 page; returns whether the page turned.
    let onSwipe: (Int) -> Bool
    /// A box was dragged in link mode; the caller picks the target.
    let onLinkArea: (CGRect) -> Void

    func makeUIView(context: Context) -> NoteCanvasView {
        let view = NoteCanvasView()
        handle.view = view
        return view
    }

    func updateUIView(_ view: NoteCanvasView, context: Context) {
        view.onModeDone = { mode = .draw }
        view.onSwipe = onSwipe
        view.mode = mode
        view.bind(store: store, page: page, onOpenLink: onOpenLink, onLinkArea: onLinkArea)
    }
}

/// One notebook page: paper, pictures, ink, and an overlay of text boxes and links, all zooming together.
final class NoteCanvasView: UIView, UIEditMenuInteractionDelegate, UITextViewDelegate {
    var onDrawingChange: ((PKDrawing) -> Void)?
    var onEditPage: (((inout NotePage) -> Void) -> Void)?
    var onLinkTap: ((NoteLink) -> Void)?
    var onModeDone: (() -> Void)?
    var onSwipe: ((Int) -> Bool)?
    var onLinkArea: ((CGRect) -> Void)?
    var imageProvider: ((String) -> UIImage?)?

    var mode: CanvasMode = .draw {
        didSet {
            guard mode != oldValue else { return }
            selectionGesture.isEnabled = mode == .convert || mode == .link
            for gesture in [arrangePan, arrangePinch, arrangeTap] as [UIGestureRecognizer] {
                gesture.isEnabled = mode == .arrange
            }
            applyDrawing()
            // arranging keeps two-finger scrolling; one finger moves things
            canvas.panGestureRecognizer.minimumNumberOfTouches = mode == .arrange ? 2 : 1
            overlay.isUserInteractionEnabled = mode != .arrange
            applyScrolling()
            rebuildOverlay()
        }
    }

    /// Whole page fitted on screen, no scrolling, fingers left free to turn pages.
    var bookMode = false {
        didSet {
            guard bookMode != oldValue else { return }
            ink.fingerAllowed = !bookMode
            // book pages are paper edge to edge, and a spread's blank end page stays white
            backgroundColor = bookMode ? .clear : Theme.uiPaper
            spine.isHidden = !bookMode
            // books curl from the corners, so folding one starts with a hold
            cornerPull.isEnabled = !bookMode
            cornerHold.isEnabled = bookMode
            // the whole book shrinks when zooming out, never one page inside its half
            canvas.bouncesZoom = !bookMode
            applyScrolling()
            fittedSize = .zero
            setNeedsLayout()
        }
    }

    /// Shared by the pages of a book so they zoom together.
    weak var bookZoom: BookZoom? {
        didSet { bookZoom?.add(self) }
    }
    let spine = SpineShade()
    private var applyingBookZoom = false
    private let foldView = FoldView()
    private lazy var cornerPress = UILongPressGestureRecognizer(target: self, action: #selector(cornerPressed(_:)))
    private lazy var cornerPull = UIPanGestureRecognizer(target: self, action: #selector(cornerPulled(_:)))
    private lazy var cornerHold = UILongPressGestureRecognizer(target: self, action: #selector(cornerPulled(_:)))
    private lazy var typeTap = UITapGestureRecognizer(target: self, action: #selector(typeTapped(_:)))
    /// Text being typed or written in place, and whether it's a new box.
    private var typing: (view: UITextView, box: TextBox, isNew: Bool)?
    private var checklistViews: [UUID: UIView] = [:]
    private var voiceViews: [UUID: UIView] = [:]
    private var rotateKnob: UIView?
    private var scaleKnob: UIView?
    /// Handwriting picked out in select mode, waiting on the menu.
    private var inkSelection: CGRect?
    var audioURL: ((String) -> URL)?
    private let cornerGate = FoldGate()
    /// The corner being pulled, where the finger last settled, and whether holding still there has made it a bookmark.
    private var pull: (corner: PageCorner, rest: CGPoint, armed: Bool, still: DispatchWorkItem?)?
    /// Old page and direction, waiting for the new page to arrive so it can flip over.
    private var pendingFlip: (old: UIImage, delta: Int, cover: UIView)?

    private func raiseLayers() {
        canvas.bringSubviewToFront(overlay)
        canvas.bringSubviewToFront(foldView)
    }

    /// Corners on the page's open side, away from the binding.
    private var outerCorners: [PageCorner] {
        bookMode && spine.edge == .right ? [.topLeft, .bottomLeft] : [.topRight, .bottomRight]
    }

    /// Folds or flattens the top outer corner, for the bookmark button.
    func toggleBookmark() {
        let corner = outerCorners[0]
        let marked = page?.bookmarked == true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        editPage(marked ? "Remove Bookmark" : "Bookmark") { page in
            page.folds = marked ? nil : [corner]
        }
    }

    /// The outer corner a finger is holding, in a zone that stays the same size on screen.
    private func corner(at point: CGPoint) -> PageCorner? {
        let reach = max(FoldView.size, 60 / max(canvas.zoomScale, 0.1))
        let page = CGRect(origin: .zero, size: pageSize)
        return outerCorners.first { corner in
            let c = corner.point(in: page)
            return hypot(point.x - c.x, point.y - c.y) < reach
        }
    }

    /// Holding a folded corner flattens it out again.
    @objc private func cornerPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let corner = corner(at: gesture.location(in: overlay)),
              (page?.folds ?? []).contains(corner) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        foldView.layer.add(fade, forKey: "fold")
        editPage("Unfold Corner") { page in
            page.folds?.removeAll { $0 == corner }
            if page.folds?.isEmpty == true { page.folds = nil }
        }
    }

    /// Pull a corner over by hand; hold it still to keep the fold as a bookmark, or let go and it falls back.
    @objc private func cornerPulled(_ gesture: UIGestureRecognizer) {
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            let t = (gesture as? UIPanGestureRecognizer)?.translation(in: overlay) ?? .zero
            guard let corner = corner(at: CGPoint(x: point.x - t.x, y: point.y - t.y)) else { return }
            if gesture === cornerHold { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            pull = (corner, point, false, nil)
            fallthrough
        case .changed:
            guard let current = pull else { return }
            let c = current.corner.point(in: CGRect(origin: .zero, size: pageSize))
            // never pulled further than most of the page
            let reach = min(pageSize.width, pageSize.height) * 0.8
            let d = CGPoint(x: point.x - c.x, y: point.y - c.y), length = hypot(d.x, d.y)
            let tip = length > reach ? CGPoint(x: c.x + d.x / length * reach, y: c.y + d.y / length * reach) : point
            foldView.live = (current.corner, tip)
            // a fingertip never keeps perfectly still; only real moves restart the hold
            let wobble = 10 / max(canvas.zoomScale, 0.1)
            guard !current.armed, current.still == nil || hypot(point.x - current.rest.x, point.y - current.rest.y) > wobble else { return }
            current.still?.cancel()
            pull?.rest = point
            let still = DispatchWorkItem { [weak self] in
                guard let self, self.pull?.corner == current.corner else { return }
                self.pull?.armed = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            pull?.still = still
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: still)
        default:
            guard let current = pull else { return }
            current.still?.cancel()
            pull = nil
            if current.armed {
                foldView.live = nil
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.18
                foldView.layer.add(fade, forKey: "fold")
                editPage("Fold Corner") { page in
                    page.folds = (page.folds ?? []).filter { $0 != current.corner } + [current.corner]
                }
            } else {
                foldView.release()
            }
        }
    }

    func applyScrolling() {
        // a book page only pans once zoomed in, otherwise fingers turn pages
        let pans = bookMode ? bookZoom?.zoomed == true : true
        canvas.isScrollEnabled = pans && (mode == .draw || mode == .arrange)
        // while the whole book is shrunk, pinching resizes the book instead
        let shrunk = bookMode && (bookZoom?.outScale ?? 1) < 0.999
        canvas.pinchGestureRecognizer?.isEnabled = mode != .arrange && !shrunk
    }

    /// Takes the book's shared zoom and position.
    func applyBookZoom() {
        guard bookMode, let zoom = bookZoom, fitScale > 0 else { return }
        applyingBookZoom = true
        canvas.zoomScale = fitScale * zoom.scale
        syncZoom()
        let size = canvas.contentSize, inset = canvas.contentInset, view = canvas.bounds.size
        let x = min(max(zoom.center.x * size.width - view.width / 2, -inset.left), max(size.width + inset.right - view.width, -inset.left))
        let y = min(max(zoom.center.y * size.height - view.height / 2, -inset.top), max(size.height + inset.bottom - view.height, -inset.top))
        canvas.contentOffset = CGPoint(x: x, y: y)
        applyScrolling()
        applyingBookZoom = false
    }

    /// Passes this page's zoom to the rest of the book while a finger moves it, and once more when it settles.
    private func reportBookZoom(settled: Bool = false) {
        guard bookMode, let zoom = bookZoom, !applyingBookZoom, fitScale > 0 else { return }
        guard settled || canvas.isZooming || canvas.isZoomBouncing || canvas.isDragging || canvas.isDecelerating else { return }
        let size = canvas.contentSize
        guard size.width > 0, size.height > 0 else { return }
        let offset = canvas.contentOffset, view = canvas.bounds.size
        var scale = canvas.zoomScale / fitScale
        var center = CGPoint(x: (offset.x + view.width / 2) / size.width, y: (offset.y + view.height / 2) / size.height)
        if abs(scale - 1) < 0.04 {
            // close to the whole page: settle exactly on it
            scale = 1
            center = CGPoint(x: 0.5, y: 0.5)
            if settled, abs(canvas.zoomScale - fitScale) > 0.0001 { canvas.setZoomScale(fitScale, animated: true) }
        }
        zoom.update(scale: scale, center: center, from: self)
        applyScrolling()
    }

    private let ink = InkController()
    private var canvas: PKCanvasView { ink.canvas }
    private let paper = PaperView()
    private let media = UIView()
    private let shapesView = ShapeLayerView()
    private var liveShape: ShapeItem?
    private var selectedShape: UUID?
    private var editor: ShapeEditor?
    private weak var inspector: FloatingPanel?
    private var handleViews: [UIView] = []
    /// A handle or the whole selected shape is being dragged; the page copy is stale till it ends.
    private var shapeDrag: (start: CGPoint, base: ShapeItem)?
    private lazy var shapeTap = UITapGestureRecognizer(target: self, action: #selector(shapeTapped(_:)))
    private lazy var shapeMove = UIPanGestureRecognizer(target: self, action: #selector(shapeMoved(_:)))
    private let shapeGate = GestureGate()
    private let overlay = PassthroughView()
    private let selectionLayer = CAShapeLayer()
    private lazy var selectionGesture = UIPanGestureRecognizer(target: self, action: #selector(selectionPan(_:)))
    private lazy var arrangePan = UIPanGestureRecognizer(target: self, action: #selector(arrangePan(_:)))
    private lazy var arrangePinch = UIPinchGestureRecognizer(target: self, action: #selector(arrangePinch(_:)))
    private lazy var arrangeTap = UITapGestureRecognizer(target: self, action: #selector(arrangeTap(_:)))
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var selectionStart = CGPoint.zero
    private var page: NotePage?
    private var pageSize = notebookPageSize
    private var boxViews: [UUID: UIView] = [:]
    private var linkViews: [UUID: UIView] = [:]
    private var imageViews: [UUID: UIView] = [:]
    private var fittedSize = CGSize.zero
    private var fitScale: CGFloat = 1
    /// How much of the page the keyboard covers, so typing near the bottom can scroll up.
    private var keyboardOverlap: CGFloat = 0
    private var pendingMath: DispatchWorkItem?
    private let swipeGate = SwipeGate()
    private var pushDirection = 0
    private var dragging: (item: Item, start: CGPoint)?
    private var pinching: Item?
    private var menuItem: Item?

    private enum Item: Equatable {
        case text(UUID), link(UUID), image(UUID), shape(UUID), checklist(UUID), voice(UUID)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.uiPaper
        // keeps the page-turn slide inside this pane
        clipsToBounds = true
        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.contentInsetAdjustmentBehavior = .never
        addSubview(canvas)
        spine.isHidden = true
        addSubview(spine)

        for view in [paper, media, shapesView, overlay, foldView] as [UIView] {
            view.bounds = CGRect(origin: .zero, size: pageSize)
        }
        media.isUserInteractionEnabled = false
        // pictures sit between the paper and the ink so you can write on them
        canvas.insertSubview(paper, at: 0)
        canvas.insertSubview(media, aboveSubview: paper)
        canvas.insertSubview(shapesView, aboveSubview: media)
        canvas.addSubview(overlay)
        canvas.addSubview(foldView)

        // pull a page corner over to fold it; holding a folded one flattens it
        cornerPress.minimumPressDuration = 0.45
        cornerPull.maximumNumberOfTouches = 1
        cornerHold.minimumPressDuration = 0.3
        cornerHold.isEnabled = false
        for gesture in [cornerPress, cornerPull, cornerHold] as [UIGestureRecognizer] {
            gesture.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            gesture.delegate = cornerGate
            canvas.addGestureRecognizer(gesture)
        }
        cornerGate.shouldBegin = { [weak self] gesture in
            guard let self, self.mode == .draw else { return false }
            var point = gesture.location(in: self.overlay)
            if let pan = gesture as? UIPanGestureRecognizer {
                let t = pan.translation(in: self.overlay)
                point = CGPoint(x: point.x - t.x, y: point.y - t.y)
            }
            guard let corner = self.corner(at: point) else { return false }
            let folded = (self.page?.folds ?? []).contains(corner)
            return gesture === self.cornerPress ? folded : !folded
        }

        // the text pen: tap to type, or write and Scribble turns it into text
        typeTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        typeTap.isEnabled = false
        canvas.addGestureRecognizer(typeTap)
        addInteraction(UIIndirectScribbleInteraction(delegate: self))
        NotificationCenter.default.addObserver(forName: VoicePlayer.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildOverlay()
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            self?.keyboardMoved(note)
        }

        selectionLayer.fillColor = Theme.uiAccent.withAlphaComponent(0.08).cgColor
        selectionLayer.strokeColor = Theme.uiAccent.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.lineDashPattern = [6, 4]
        overlay.layer.addSublayer(selectionLayer)

        arrangePan.maximumNumberOfTouches = 1
        for gesture in [selectionGesture, arrangePan, arrangePinch, arrangeTap] as [UIGestureRecognizer] {
            gesture.isEnabled = false
            canvas.addGestureRecognizer(gesture)
        }
        addInteraction(editMenu)

        // fingers select shapes and move them; the pencil keeps drawing
        for gesture in [shapeTap, shapeMove] as [UIGestureRecognizer] {
            gesture.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            gesture.delegate = shapeGate
            canvas.addGestureRecognizer(gesture)
        }
        shapeMove.maximumNumberOfTouches = 1
        canvas.panGestureRecognizer.require(toFail: shapeMove)
        shapeGate.shouldBegin = { [weak self] gesture in
            guard let self, self.mode == .draw else { return false }
            let point = gesture.location(in: self.overlay)
            if gesture === self.shapeTap {
                return self.shape(at: point) != nil || self.selectedShape != nil
            }
            guard let id = self.selectedShape, let shape = self.page?.shapes.first(where: { $0.id == id }) else { return false }
            return shape.hit(point, reach: self.reach)
        }

        // one finger turns pages when fingers don't draw, two fingers when they do
        for touches in [1, 2] {
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
                swipe.direction = direction
                swipe.numberOfTouchesRequired = touches
                swipe.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
                swipe.delegate = swipeGate
                canvas.addGestureRecognizer(swipe)
            }
        }
        swipeGate.canBegin = { [weak self] swipe in
            guard let self, self.mode == .draw, !self.bookMode, self.canvas.zoomScale <= self.fitScale * 1.05 else { return false }
            return swipe.numberOfTouchesRequired == 2 || self.ink.pencilOnly
        }

        ink.onChange = { [weak self] drawing in
            self?.onDrawingChange?(drawing)
            self?.scheduleMath()
        }
        ink.onZoom = { [weak self] in
            self?.syncZoom()
            self?.reportBookZoom()
        }
        ink.onScroll = { [weak self] in self?.reportBookZoom() }
        ink.onScrollEnd = { [weak self] in self?.reportBookZoom(settled: true) }
        ink.onToolsChanged = { [weak self] in
            self?.shareRulerScale()
            self?.applyDrawing()
        }
        ink.adjustStroke = { [weak self] stroke in
            guard let self, InkTools.shared.ruler else { return nil }
            return RulerView.shared?.straightened(stroke, in: self.overlay)
        }
        ink.extrasHit = { [weak self] area in
            guard let self else { return false }
            return !self.boxes(in: area).isEmpty || !self.shapes(in: area).isEmpty
        }
        ink.eraseExtras = { [weak self] area in
            guard let self else { return }
            let ids = Set(self.boxes(in: area).map(\.id)), shapeIDs = Set(self.shapes(in: area).map(\.id))
            self.editPage("Scribble Erase") { page in
                page.textBoxes.removeAll { ids.contains($0.id) }
                page.shapes.removeAll { shapeIDs.contains($0.id) }
            }
        }
        ink.onShapeBegin = { [weak self] outline, tool in self?.beginLiveShape(outline, tool: tool) ?? false }
        ink.onShapeChange = { [weak self] outline in self?.updateLiveShape(outline) }
        ink.onShapeEnd = { [weak self] in self?.endLiveShape() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ page: NotePage, paper style: PaperStyle, color: PaperColor, size: CGSize, background: PDFPage?, drawing: () -> PKDrawing) {
        if size != pageSize {
            pageSize = size
            for view in [paper, media, shapesView, overlay, foldView] as [UIView] {
                view.bounds = CGRect(origin: .zero, size: size)
            }
            fittedSize = .zero
            setNeedsLayout()
        }
        if page.id != self.page?.id {
            ink.load(drawing())
            // undo steps belong to the previous page
            canvas.undoManager?.removeAllActions()
            canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top), animated: false)
            if let flip = pendingFlip {
                pendingFlip = nil
                // let the new page draw, then turn the old one over it
                DispatchQueue.main.async { [weak self] in self?.flip(from: flip.old, delta: flip.delta, cover: flip.cover) }
            } else if pushDirection != 0 {
                let push = CATransition()
                push.type = .push
                push.subtype = pushDirection > 0 ? .fromRight : .fromLeft
                push.duration = 0.25
                push.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // on the canvas, not self, so this view's bounds clip the slide
                canvas.layer.add(push, forKey: "pageTurn")
                pushDirection = 0
            }
        }
        self.page = page
        paper.style = style
        paper.color = color
        paper.pdfPage = background
        rebuildOverlay()
    }

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        let delta = swipe.direction == .left ? 1 : -1
        guard pendingFlip == nil, !subviews.contains(where: { $0 is PageFlipView }) else { return }
        if Appearance.shared.pageTurn == .flip {
            let old = PageFlipView.snapshot(canvas)
            // hold the old page on screen until the flip takes over
            let cover = UIImageView(image: old)
            cover.frame = bounds
            addSubview(cover)
            pendingFlip = (old, delta, cover)
            if onSwipe?(delta) != true {
                cover.removeFromSuperview()
                pendingFlip = nil
            }
        } else {
            pushDirection = delta
            if onSwipe?(delta) != true { pushDirection = 0 }
        }
    }

    /// Turns the page like paper: forward lifts the old page away, back lays the new one down over it.
    /// Only the sheet turns; the desk around it stays.
    private func flip(from old: UIImage, delta: Int, cover: UIView) {
        let new = PageFlipView.snapshot(canvas, afterUpdates: true)
        let forward = delta > 0
        let sheet = overlay.convert(overlay.bounds, to: self).intersection(bounds)
        guard !sheet.isNull, sheet.width > 1 else { return cover.removeFromSuperview() }
        let flip = PageFlipView(frame: bounds, under: forward ? new : old, leaf: sheet,
                                front: PageFlipView.crop(forward ? old : new, to: sheet),
                                back: nil, backColor: paper.color.fill, forward: forward, push: forward ? 0.12 : 0, sweep: .away)
        addSubview(flip)
        cover.removeFromSuperview()
        flip.animate(to: 1, duration: 0.62) { [weak flip] in flip?.removeFromSuperview() }
    }

    /// Wires the view to a notebook page and shows it.
    func bind(store: NotebookStore, page: NotePage, onOpenLink: @escaping (NoteLink) -> Void, onLinkArea: @escaping (CGRect) -> Void) {
        let id = page.id
        onDrawingChange = { [store] in store.setDrawing($0, for: id) }
        onEditPage = { [store] change in store.update(id, change) }
        onLinkTap = onOpenLink
        self.onLinkArea = onLinkArea
        imageProvider = { [store] in store.image($0) }
        audioURL = { [store] in store.audioURL($0) }
        let notebook = store.notebook
        show(page, paper: notebook.style(of: page), color: notebook.color(of: page), size: notebook.size(of: page),
             background: page.background.flatMap { store.pdfPage(for: $0) }) { store.drawing(for: id) }
    }

    func beginNewText() {
        let origin = visibleCenter()
        beginTyping(TextBox(text: "", origin: CGPoint(x: max(origin.x - 160, 20), y: origin.y), fontSize: 24), isNew: true)
    }

    func addSticky(_ color: String) {
        let c = visibleCenter()
        beginTyping(TextBox(text: "", origin: CGPoint(x: c.x - 120, y: c.y - 110), fontSize: 22, sticky: color), isNew: true)
    }

    func addChecklist() {
        let c = visibleCenter()
        let list = Checklist(title: "To Do", items: [], origin: CGPoint(x: c.x - 180, y: c.y - 80))
        editChecklist(list, isNew: true)
    }

    func addVoiceNote(file: String, duration: TimeInterval) {
        let note = VoiceNote(file: file, position: visibleCenter(), duration: duration,
                             title: "Voice note " + Date().formatted(date: .omitted, time: .shortened))
        editPage("Add Voice Note") { $0.voiceNotes.append(note) }
    }

    /// Picks something out briefly, for search results.
    func flash(_ rect: CGRect) {
        let target = overlay.convert(rect.insetBy(dx: -30, dy: -60), to: canvas)
        canvas.scrollRectToVisible(target, animated: true)
        let mark = CAShapeLayer()
        mark.path = UIBezierPath(roundedRect: rect.insetBy(dx: -6, dy: -4), cornerRadius: 6).cgPath
        mark.fillColor = Theme.uiAccent.withAlphaComponent(0.28).cgColor
        overlay.layer.addSublayer(mark)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 1.4
        fade.duration = 0.8
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        mark.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { mark.removeFromSuperlayer() }
    }

    /// Pen strokes while drawing; with the text pen the pencil writes text instead.
    private func applyDrawing() {
        let text = InkTools.shared.writesText
        canvas.drawingGestureRecognizer.isEnabled = mode == .draw && !text
        typeTap.isEnabled = mode == .draw && text
        if !text, typing != nil, mode == .draw, !(typing?.view.isFirstResponder ?? false) { endTyping() }
    }

    func addLink(_ target: LinkTarget, label: String) {
        let link = NoteLink(target: target, label: label, position: visibleCenter())
        editPage("Add Link") { $0.links.append(link) }
    }

    func addAreaLink(_ target: LinkTarget, label: String, area: CGRect) {
        let link = NoteLink(target: target, label: label, position: CGPoint(x: area.midX, y: area.midY), area: area)
        editPage("Add Link") { $0.links.append(link) }
    }

    func addImage(file: String, size imageSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(1, pageSize.width * 0.6 / imageSize.width, pageSize.height * 0.5 / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        let c = visibleCenter()
        let box = ImageBox(file: file, frame: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
        editPage("Add Image") { $0.images.append(box) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { ink.activate() }
    }

    /// The ruler's marks follow the zoom of the page being written on.
    private func shareRulerScale() {
        guard InkTools.shared.active === ink, window != nil else { return }
        let a = overlay.convert(CGPoint.zero, to: nil), b = overlay.convert(CGPoint(x: 1, y: 0), to: nil)
        InkTools.shared.rulerScale = hypot(b.x - a.x, b.y - a.y)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spine.place(in: bounds)
        bringSubviewToFront(spine)
        guard bounds.width > 0, bounds.height > 0, bounds.size != fittedSize else { return }
        // only a change of width refits; a height change keeps the zoom the user had
        let keep = fittedSize.width == bounds.width
        fittedSize = bounds.size
        // the whole page fits, so landscape doesn't open zoomed in
        let fit = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        fitScale = fit
        // a book page never shrinks below the paper
        canvas.minimumZoomScale = bookMode ? fit : fit * 0.3
        canvas.maximumZoomScale = fit * 4
        canvas.zoomScale = keep ? max(canvas.zoomScale, canvas.minimumZoomScale) : fit
        syncZoom()
        applyBookZoom()
    }

    private func keyboardMoved(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let window else { return }
        let keyboard = convert(frame, from: window.screen.coordinateSpace)
        keyboardOverlap = max(0, bounds.maxY - keyboard.minY)
        syncZoom()
        if keyboardOverlap > 0, let view = typing?.view {
            canvas.scrollRectToVisible(view.convert(view.bounds, to: canvas).insetBy(dx: 0, dy: -24), animated: true)
        }
    }

    private func syncZoom() {
        let zoom = canvas.zoomScale
        let size = CGSize(width: pageSize.width * zoom, height: pageSize.height * zoom)
        canvas.contentSize = size
        for view in [paper, media, shapesView, overlay, foldView] as [UIView] {
            view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            view.center = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let inset = max(0, (canvas.bounds.width - size.width) / 2)
        // a page smaller than the view sits in the middle, not at the top
        let top = max(0, (canvas.bounds.height - size.height) / 2)
        canvas.contentInset = UIEdgeInsets(top: top, left: inset, bottom: top + keyboardOverlap, right: inset)
        // sharper paper when zoomed, but only redrawn on real changes and capped to keep memory down
        let scale = min(traitCollection.displayScale * zoom, 3)
        if abs(scale - paper.contentScaleFactor) / scale > 0.15 {
            for view in [paper, shapesView] as [UIView] {
                view.contentScaleFactor = scale
                view.setNeedsDisplay()
            }
        }
        layoutHandles()
        raiseLayers()
        shareRulerScale()
    }

    /// Draws everything now, so a page curl snapshot isn't blank.
    func prepareForSnapshot() {
        layoutIfNeeded()
        paper.layer.displayIfNeeded()
        shapesView.layer.displayIfNeeded()
    }

    private func visibleCenter() -> CGPoint {
        canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: overlay)
    }

    private var viewController: UIViewController? {
        sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
    }

    // Undoable page edits

    /// Applies an edit now and records the page as it was, so undo puts it back whole.
    private func editPage(_ name: String, _ change: @escaping (inout NotePage) -> Void) {
        guard let before = page else { return }
        var after = before
        change(&after)
        page = after
        onEditPage?(change)
        canvas.undoManager?.registerUndo(withTarget: self) { $0.restore(before, name: name) }
        canvas.undoManager?.setActionName(name)
        rebuildOverlay()
    }

    private func restore(_ snapshot: NotePage, name: String) {
        guard let current = page else { return }
        page = snapshot
        onEditPage?({ $0 = snapshot })
        canvas.undoManager?.registerUndo(withTarget: self) { $0.restore(current, name: name) }
        canvas.undoManager?.setActionName(name)
        rebuildOverlay()
    }

    // Overlay

    private func rebuildOverlay() {
        // the box being typed in stays put, or the keyboard would drop
        overlay.subviews.filter { $0 !== typing?.view }.forEach { $0.removeFromSuperview() }
        media.subviews.forEach { $0.removeFromSuperview() }
        checklistViews.removeAll()
        voiceViews.removeAll()
        boxViews.removeAll()
        linkViews.removeAll()
        imageViews.removeAll()
        guard let page else { return }
        shapesView.shapes = page.shapes
        if let id = selectedShape {
            if let current = page.shapes.first(where: { $0.id == id }) {
                if shapeDrag == nil, editor?.shape != current { editor?.shape = current }
            } else {
                deselectShape()
            }
        }
        shapesView.selected = selectedShape
        foldView.folds = page.folds ?? []
        foldView.paperColor = paper.color.fill
        foldView.behind = Theme.uiPaper
        for image in page.images {
            let view = UIImageView(image: imageProvider?(image.file))
            view.frame = image.frame
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = 4
            if mode == .arrange {
                view.layer.borderColor = Theme.uiAccent.withAlphaComponent(0.6).cgColor
                view.layer.borderWidth = 2
            }
            imageViews[image.id] = view
            media.addSubview(view)
        }
        for box in page.textBoxes where box.id != typing?.box.id {
            let view = textBoxView(box)
            boxViews[box.id] = view
            overlay.addSubview(view)
        }
        for list in page.checklists {
            let view = checklistView(list)
            checklistViews[list.id] = view
            overlay.addSubview(view)
        }
        for note in page.voiceNotes {
            let view = voiceChip(note)
            voiceViews[note.id] = view
            overlay.addSubview(view)
        }
        if let typing { overlay.bringSubviewToFront(typing.view) }
        for link in page.links {
            let view = link.area == nil ? linkChip(link) : areaLink(link)
            linkViews[link.id] = view
            overlay.addSubview(view)
        }
        if mode == .arrange {
            for view in Array(boxViews.values) + Array(linkViews.values) + Array(checklistViews.values) + Array(voiceViews.values) {
                view.layer.borderColor = Theme.uiAccent.withAlphaComponent(0.6).cgColor
                view.layer.borderWidth = 1.5
            }
        }
        overlay.layer.addSublayer(selectionLayer)
        handleViews = []
        layoutHandles()
        raiseLayers()
        shareRulerScale()
    }

    private var inkColor: UIColor {
        paper.color == .dark ? .white : .black
    }

    private func textBoxView(_ box: TextBox) -> UIView {
        let label = UILabel()
        label.numberOfLines = 0
        if box.anchor != nil {
            let font = UIFont(name: "Noteworthy-Light", size: box.fontSize) ?? .systemFont(ofSize: box.fontSize)
            label.attributedText = NSAttributedString(string: box.text, attributes: [.font: font, .foregroundColor: Theme.uiAccent])
        } else {
            label.attributedText = Markdown.render(box.text, size: box.fontSize, color: box.sticky == nil ? inkColor : .black)
        }
        let button = UIButton(type: .custom)
        button.addSubview(label)
        label.isUserInteractionEnabled = false
        // the pencil writes over text (or Scribbles into it with the text pen); fingers open its menu
        button.tag = PassthroughView.pencilThroughTag
        if let sticky = box.sticky {
            // a square paper note with a soft shadow
            let inner = label.sizeThatFits(CGSize(width: Self.stickyWidth - 32, height: .greatestFiniteMagnitude))
            label.frame = CGRect(x: 16, y: 16, width: Self.stickyWidth - 32, height: inner.height)
            button.frame = CGRect(origin: box.origin, size: CGSize(width: Self.stickyWidth, height: max(Self.stickyWidth * 0.86, inner.height + 32)))
            button.backgroundColor = UIColor(hex: sticky)
            button.layer.cornerRadius = 3
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.2
            button.layer.shadowRadius = 6
            button.layer.shadowOffset = CGSize(width: 0, height: 4)
        } else {
            let size = label.sizeThatFits(CGSize(width: min(560, pageSize.width - 40), height: .greatestFiniteMagnitude))
            label.frame = CGRect(origin: .zero, size: size)
            if let anchor = box.anchor {
                button.frame = CGRect(x: anchor.x, y: anchor.y - size.height / 2, width: size.width, height: size.height)
            } else {
                button.frame = CGRect(origin: box.origin, size: size)
            }
        }

        var actions: [UIMenuElement] = [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = box.text
            },
        ]
        if box.anchor == nil {
            actions.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.edit(box) })
            actions.append(UIAction(title: "Edit as Markdown", image: UIImage(systemName: "text.badge.star")) { [weak self] _ in self?.editMarkdown(box) })
            if box.sticky != nil {
                actions.append(UIMenu(title: "Colour", image: UIImage(systemName: "paintpalette"), children: Self.stickyColors.map { name, hex in
                    UIAction(title: name, state: box.sticky == hex ? .on : .off) { [weak self] _ in
                        self?.editPage("Note Colour") { page in
                            if let i = page.textBoxes.firstIndex(where: { $0.id == box.id }) { page.textBoxes[i].sticky = hex }
                        }
                    }
                }))
            }
            actions.append(UIAction(title: "Link This Text", image: UIImage(systemName: "link")) { [weak self, weak button] _ in
                guard let frame = button?.frame else { return }
                self?.onLinkArea?(frame)
            })
        }
        for url in Markdown.links(in: box.text) {
            actions.append(UIAction(title: "Open \(url.host() ?? url.absoluteString)", image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            })
        }
        actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.editPage("Delete Text") { page in page.textBoxes.removeAll { $0.id == box.id } }
        })
        button.menu = UIMenu(children: actions)
        button.showsMenuAsPrimaryAction = true
        // the text pen taps straight through to type
        button.isUserInteractionEnabled = !InkTools.shared.writesText
        return button
    }

    static let stickyWidth: CGFloat = 240
    static let stickyColors: [(String, String)] = [("Yellow", "FFE98A"), ("Pink", "FFC6DA"), ("Blue", "C4E4FF"), ("Green", "CDEFC4"), ("Lilac", "E2D4FF")]

    private func linkChip(_ link: NoteLink) -> UIView {
        var config = UIButton.Configuration.filled()
        let symbol: String
        switch link.target {
        case .web: symbol = "safari"
        case .voice: symbol = "waveform"
        default: symbol = "link"
        }
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 4
        config.title = link.label
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.baseBackgroundColor = Theme.uiAccent
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.onLinkTap?(link)
        })
        button.menu = removeMenu(link)
        button.sizeToFit()
        button.center = link.position
        return button
    }

    /// A tinted, underlined patch over linked handwriting or text. The pencil writes straight through it.
    private func areaLink(_ link: NoteLink) -> UIView {
        let area = link.area ?? .zero
        let button = UIButton(type: .custom, primaryAction: UIAction { [weak self] _ in self?.onLinkTap?(link) })
        button.frame = area.insetBy(dx: -4, dy: -4)
        button.backgroundColor = Theme.uiAccent.withAlphaComponent(0.1)
        button.layer.cornerRadius = 6
        let underline = CALayer()
        underline.backgroundColor = Theme.uiAccent.withAlphaComponent(0.8).cgColor
        underline.frame = CGRect(x: 4, y: button.bounds.height - 3, width: button.bounds.width - 8, height: 2)
        button.layer.addSublayer(underline)
        button.tag = PassthroughView.pencilThroughTag
        button.menu = removeMenu(link)
        button.accessibilityLabel = link.label
        return button
    }

    private func removeMenu(_ link: NoteLink) -> UIMenu {
        UIMenu(title: link.label, children: [
            UIAction(title: "Remove Link", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.editPage("Remove Link") { page in page.links.removeAll { $0.id == link.id } }
            },
        ])
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
        beginTyping(box, isNew: false)
    }

    private func editMarkdown(_ box: TextBox) {
        guard let presenter = viewController else { return }
        TextBoxEditor.present(from: presenter, text: box.text, title: "Edit Text") { [weak self] text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.editPage(trimmed.isEmpty ? "Delete Text" : "Edit Text") { page in
                guard let i = page.textBoxes.firstIndex(where: { $0.id == box.id }) else { return }
                if trimmed.isEmpty { page.textBoxes.remove(at: i) } else { page.textBoxes[i].text = trimmed }
            }
        }
    }

    // Arrange mode

    private func item(at point: CGPoint) -> Item? {
        guard let page else { return nil }
        for link in page.links.reversed() where linkViews[link.id]?.frame.insetBy(dx: -8, dy: -8).contains(point) == true {
            return .link(link.id)
        }
        for note in page.voiceNotes.reversed() where voiceViews[note.id]?.frame.insetBy(dx: -8, dy: -8).contains(point) == true {
            return .voice(note.id)
        }
        for list in page.checklists.reversed() where checklistViews[list.id]?.frame.insetBy(dx: -8, dy: -8).contains(point) == true {
            return .checklist(list.id)
        }
        for box in page.textBoxes.reversed() where box.anchor == nil && boxViews[box.id]?.frame.insetBy(dx: -8, dy: -8).contains(point) == true {
            return .text(box.id)
        }
        if let hit = shape(at: point) {
            return .shape(hit.id)
        }
        for image in page.images.reversed() where image.frame.contains(point) {
            return .image(image.id)
        }
        return nil
    }

    private func view(for item: Item) -> UIView? {
        switch item {
        case .text(let id): boxViews[id]
        case .link(let id): linkViews[id]
        case .image(let id): imageViews[id]
        case .checklist(let id): checklistViews[id]
        case .voice(let id): voiceViews[id]
        case .shape: nil
        }
    }

    @objc private func arrangePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            guard let item = item(at: point) else { return }
            dragging = (item, point)
        case .changed:
            guard let dragging else { return }
            let d = CGSize(width: point.x - dragging.start.x, height: point.y - dragging.start.y)
            if case .shape(let id) = dragging.item {
                shapesView.preview = page?.shapes.first { $0.id == id }?.translated(by: d)
            } else if let view = view(for: dragging.item) {
                view.transform = CGAffineTransform(translationX: d.width, y: d.height)
            }
        case .ended:
            guard let dragging else { return }
            self.dragging = nil
            let dx = point.x - dragging.start.x, dy = point.y - dragging.start.y
            editPage("Move") { page in
                switch dragging.item {
                case .text(let id):
                    if let i = page.textBoxes.firstIndex(where: { $0.id == id }) {
                        page.textBoxes[i].origin.x += dx
                        page.textBoxes[i].origin.y += dy
                    }
                case .link(let id):
                    if let i = page.links.firstIndex(where: { $0.id == id }) {
                        page.links[i].position.x += dx
                        page.links[i].position.y += dy
                        page.links[i].area = page.links[i].area?.offsetBy(dx: dx, dy: dy)
                    }
                case .image(let id):
                    if let i = page.images.firstIndex(where: { $0.id == id }) {
                        page.images[i].frame = page.images[i].frame.offsetBy(dx: dx, dy: dy)
                    }
                case .shape(let id):
                    if let i = page.shapes.firstIndex(where: { $0.id == id }) {
                        page.shapes[i] = page.shapes[i].translated(by: CGSize(width: dx, height: dy))
                    }
                case .checklist(let id):
                    if let i = page.checklists.firstIndex(where: { $0.id == id }) {
                        page.checklists[i].origin.x += dx
                        page.checklists[i].origin.y += dy
                    }
                case .voice(let id):
                    if let i = page.voiceNotes.firstIndex(where: { $0.id == id }) {
                        page.voiceNotes[i].position.x += dx
                        page.voiceNotes[i].position.y += dy
                    }
                }
            }
            shapesView.preview = nil
        default:
            dragging = nil
            rebuildOverlay()
        }
    }

    /// Pinch scales a picture, or a text box's font.
    @objc private func arrangePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinching = item(at: gesture.location(in: overlay))
            if case .link = pinching { pinching = nil }
            if case .voice = pinching { pinching = nil }
        case .changed:
            guard let pinching else { return }
            if case .shape(let id) = pinching {
                shapesView.preview = page?.shapes.first { $0.id == id }?.scaled(by: gesture.scale)
            } else if let view = view(for: pinching) {
                view.transform = CGAffineTransform(scaleX: gesture.scale, y: gesture.scale)
            }
        case .ended:
            guard let pinching else { return }
            self.pinching = nil
            let scale = gesture.scale
            editPage("Resize") { page in
                switch pinching {
                case .text(let id):
                    if let i = page.textBoxes.firstIndex(where: { $0.id == id }) {
                        page.textBoxes[i].fontSize = min(max(page.textBoxes[i].fontSize * scale, 10), 160)
                    }
                case .image(let id):
                    if let i = page.images.firstIndex(where: { $0.id == id }) {
                        let f = page.images[i].frame
                        let w = max(f.width * scale, 40), h = max(f.height * scale, 40)
                        page.images[i].frame = CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
                    }
                case .shape(let id):
                    if let i = page.shapes.firstIndex(where: { $0.id == id }) {
                        page.shapes[i] = page.shapes[i].scaled(by: scale)
                    }
                case .checklist(let id):
                    if let i = page.checklists.firstIndex(where: { $0.id == id }) {
                        page.checklists[i].fontSize = min(max(page.checklists[i].fontSize * scale, 12), 60)
                    }
                case .link, .voice:
                    break
                }
            }
            shapesView.preview = nil
        default:
            pinching = nil
            shapesView.preview = nil
            rebuildOverlay()
        }
    }

    @objc private func arrangeTap(_ gesture: UITapGestureRecognizer) {
        guard let item = item(at: gesture.location(in: overlay)) else { return }
        menuItem = item
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: gesture.location(in: self)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        if let rect = inkSelection { return inkMenu(rect) }
        guard let item = menuItem else { return nil }
        var actions: [UIMenuElement] = []
        if case .text(let id) = item, let box = page?.textBoxes.first(where: { $0.id == id }) {
            actions.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.edit(box) })
        }
        if case .shape(let id) = item {
            actions.append(UIAction(title: "Edit Shape", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                self?.onModeDone?()
                self?.selectShape(id)
            })
        }
        actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.editPage("Delete") { page in
                switch item {
                case .text(let id): page.textBoxes.removeAll { $0.id == id }
                case .link(let id): page.links.removeAll { $0.id == id }
                case .image(let id): page.images.removeAll { $0.id == id }
                case .shape(let id): page.shapes.removeAll { $0.id == id }
                case .checklist(let id): page.checklists.removeAll { $0.id == id }
                case .voice(let id): page.voiceNotes.removeAll { $0.id == id }
                }
            }
        })
        return UIMenu(children: actions)
    }

    // Shapes

    private func shape(at point: CGPoint) -> ShapeItem? {
        page?.shapes.reversed().first { $0.hit(point, reach: reach) }
    }

    /// A fingertip's worth of page, whatever the zoom.
    private var reach: CGFloat { max(16, 26 / max(canvas.zoomScale, 0.1)) }

    private func shapes(in area: CGRect) -> [ShapeItem] {
        (page?.shapes ?? []).filter { shape in
            let b = shape.bounds.insetBy(dx: -2, dy: -2)
            let overlap = b.intersection(area)
            return !overlap.isNull && overlap.width * overlap.height >= b.width * b.height * 0.5
        }
    }

    private static func style(from tool: PKTool) -> ShapeItem? {
        guard let pen = tool as? PKInkingTool else { return nil }
        var shape = ShapeItem(kind: .line, points: [])
        shape.color = pen.color.hex
        shape.width = max(pen.width, 1.5)
        if pen.inkType == .marker { shape.opacity = 0.4 }
        return shape
    }

    private static func shape(from outline: ShapeOutline, style: ShapeItem) -> ShapeItem {
        var shape = style
        if let e = outline.ellipse {
            shape.kind = .ellipse
            shape.points = [e.center]
            shape.radii = e.radii
            shape.rotation = Double(e.angle)
        } else if outline.isLine {
            shape.kind = .line
            shape.points = outline.points
        } else if outline.closed {
            shape.kind = .polygon
            shape.points = Array(outline.points.dropLast())
        } else {
            shape.kind = .polyline
            shape.points = outline.points
        }
        return shape
    }

    private func beginLiveShape(_ outline: ShapeOutline, tool: PKTool) -> Bool {
        guard let style = Self.style(from: tool) else { return false }
        liveShape = Self.shape(from: outline, style: style)
        shapesView.preview = liveShape
        return true
    }

    private func updateLiveShape(_ outline: ShapeOutline) {
        guard let live = liveShape else { return }
        liveShape = Self.shape(from: outline, style: live)
        shapesView.preview = liveShape
    }

    private func endLiveShape() {
        guard let live = liveShape else { return }
        liveShape = nil
        shapesView.preview = nil
        editPage("Shape") { $0.shapes.append(live) }
        // a fresh triangle opens its angles straight away
        if live.kind == .polygon, live.points.count == 3 { selectShape(live.id) }
    }

    func insertShape(_ preset: ShapePreset) {
        let c = visibleCenter()
        let tools = InkTools.shared
        let settings = tools.settings(for: .ball)
        var shape = ShapeItem(kind: .polygon, points: [])
        shape.color = settings.colors[safe: settings.colorIndex] ?? "1C1C1E"
        shape.width = 3
        shape.measures = true
        let r: CGFloat = 110
        switch preset {
        case .equilateral:
            shape.points = (0..<3).map { i in
                let t = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 3
                return CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
            }
        case .rightTriangle:
            shape.points = [CGPoint(x: c.x - r, y: c.y + r * 0.6), CGPoint(x: c.x + r, y: c.y + r * 0.6), CGPoint(x: c.x - r, y: c.y - r * 0.8)]
        case .square:
            shape.points = [CGPoint(x: c.x - r, y: c.y - r), CGPoint(x: c.x + r, y: c.y - r), CGPoint(x: c.x + r, y: c.y + r), CGPoint(x: c.x - r, y: c.y + r)]
        case .circle:
            shape.kind = .ellipse
            shape.points = [c]
            shape.radii = CGSize(width: r, height: r)
        case .line:
            shape.kind = .line
            shape.points = [CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x + r, y: c.y)]
        case .angle:
            shape.kind = .polyline
            shape.points = [CGPoint(x: c.x + r, y: c.y - r * 0.9), CGPoint(x: c.x - r * 0.6, y: c.y + r * 0.4), CGPoint(x: c.x + r * 1.2, y: c.y + r * 0.4)]
        case .projectile:
            shape.kind = .projectile
            shape.points = [CGPoint(x: c.x - 240, y: c.y + 120)]
            shape.projectile = Projectile()
            shape.width = 2.5
            shape.measures = nil
        case .graph:
            shape.kind = .graph
            shape.points = [CGPoint(x: c.x - 240, y: c.y - 170)]
            shape.radii = CGSize(width: 480, height: 340)
            shape.graph = GraphSpec(functions: ["sin(x)", "x^2/5 - 3"])
            shape.width = 2.5
            shape.measures = nil
        case .arrow:
            shape.kind = .line
            shape.points = [CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x + r, y: c.y)]
            shape.arrow = true
            shape.measures = nil
        case .diagram(let type):
            let size = type.size
            shape.kind = .diagram
            shape.points = [c]
            shape.radii = CGSize(width: size.width / 2, height: size.height / 2)
            shape.width = 2.5
            shape.measures = nil
            let now = Calendar.current.dateComponents([.year, .month], from: Date())
            shape.diagram = Diagram(type: type, label: Self.startLabel(type), element: type == .bohr ? 6 : nil,
                                    month: type == .calendar ? now.month : nil, year: type == .calendar ? now.year : nil)
        }
        let id = shape.id
        editPage("Add Shape") { $0.shapes.append(shape) }
        selectShape(id)
    }

    private static func startLabel(_ type: DiagramType) -> String? {
        switch type {
        case .terminal: "Start"
        case .process: "Do something"
        case .decision: "Yes or no?"
        case .data: "Input"
        default: nil
        }
    }

    /// Round knobs on a selected shape: one turns it, one resizes it.
    private func layoutKnobs() {
        guard let editor, selectedShape != nil, mode == .draw else {
            rotateKnob?.removeFromSuperview()
            scaleKnob?.removeFromSuperview()
            return
        }
        let shape = editor.shape
        let size = 30 / max(canvas.zoomScale, 0.1)
        let b = shape.bounds
        func knob(_ existing: UIView?, symbol: String, tag: Int) -> UIView {
            let view = existing ?? {
                let v = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .bold)))
                v.tintColor = .white
                v.backgroundColor = Theme.uiAccent
                v.contentMode = .center
                v.isUserInteractionEnabled = true
                v.tag = tag
                v.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(knobDragged(_:))))
                return v
            }()
            if view.superview !== overlay { overlay.addSubview(view) }
            view.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            view.layer.cornerRadius = size / 2
            overlay.bringSubviewToFront(view)
            return view
        }
        if shape.turnable {
            rotateKnob = knob(rotateKnob, symbol: "arrow.clockwise", tag: 1)
            rotateKnob?.center = CGPoint(x: b.midX, y: b.minY - size * 1.4)
        } else {
            rotateKnob?.removeFromSuperview()
        }
        if shape.kind != .graph, shape.kind != .projectile {
            scaleKnob = knob(scaleKnob, symbol: "arrow.up.left.and.arrow.down.right", tag: 2)
            scaleKnob?.center = CGPoint(x: b.maxX + size * 0.9, y: b.maxY + size * 0.9)
        } else {
            scaleKnob?.removeFromSuperview()
        }
    }

    @objc private func knobDragged(_ gesture: UIPanGestureRecognizer) {
        guard let editor, let tag = gesture.view?.tag else { return }
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            shapeDrag = (point, editor.shape)
        case .changed:
            guard let drag = shapeDrag else { return }
            let c = drag.base.center
            if tag == 1 {
                var turn = atan2(point.y - c.y, point.x - c.x) - atan2(drag.start.y - c.y, drag.start.x - c.x)
                // clicks onto every 15 degrees when close
                let step = CGFloat.pi / 12, nearest = (turn / step).rounded() * step
                if abs(turn - nearest) < 0.04 { turn = nearest }
                editor.shape = drag.base.rotated(by: turn)
            } else {
                let k = hypot(point.x - c.x, point.y - c.y) / max(hypot(drag.start.x - c.x, drag.start.y - c.y), 1)
                // never shrinks to a speck or past the page; diagrams need room for their detail
                let b = drag.base.bounds, side = max(b.width, b.height, 1)
                let smallest: CGFloat = drag.base.kind == .diagram ? 90 : 24
                editor.shape = drag.base.scaled(by: min(max(k, smallest / side), pageSize.width * 1.5 / side))
            }
            shapesView.preview = editor.shape
            layoutHandles()
        default:
            shapeDrag = nil
            commitShape(editor.shape)
        }
    }

    @objc private func shapeTapped(_ gesture: UITapGestureRecognizer) {
        if let hit = shape(at: gesture.location(in: overlay)) {
            selectShape(hit.id)
        } else {
            deselectShape()
        }
    }

    private func selectShape(_ id: UUID) {
        guard let shape = page?.shapes.first(where: { $0.id == id }) else { return }
        if selectedShape == id, inspector != nil { return }
        deselectShape(animated: false)
        selectedShape = id
        let editor = ShapeEditor(shape: shape)
        editor.onCommit = { [weak self] in self?.commitShape($0) }
        editor.onDelete = { [weak self] in
            self?.editPage("Delete Shape") { page in page.shapes.removeAll { $0.id == id } }
            self?.deselectShape()
        }
        self.editor = editor
        shapesView.selected = id
        rebuildOverlay()
        presentInspector(for: shape, editor: editor)
    }

    private func deselectShape(animated: Bool = true) {
        guard selectedShape != nil else { return }
        selectedShape = nil
        editor = nil
        shapesView.selected = nil
        handleViews.forEach { $0.removeFromSuperview() }
        handleViews = []
        layoutKnobs()
        inspector?.close(animated: animated)
        inspector = nil
    }

    private func presentInspector(for shape: ShapeItem, editor: ShapeEditor) {
        // floats on the top screen rather than presenting, so the shape stays draggable underneath
        guard var top = window?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let tall = shape.kind == .projectile || shape.kind == .graph
        let panel = FloatingPanel(ShapeInspector(editor: editor), size: CGSize(width: 340, height: tall ? 620 : 470))
        panel.onClose = { [weak self] in self?.deselectShape() }
        panel.show(in: top, avoiding: overlay.convert(shape.bounds, to: top.view))
        inspector = panel
    }

    private func commitShape(_ shape: ShapeItem) {
        shapesView.preview = nil
        editPage("Edit Shape") { page in
            if let i = page.shapes.firstIndex(where: { $0.id == shape.id }) { page.shapes[i] = shape }
        }
    }

    /// Round grab handles on the selected shape, kept the same size on screen at any zoom.
    private func layoutHandles() {
        layoutKnobs()
        guard let editor, selectedShape != nil else { return }
        let points = editor.shape.handles
        if handleViews.count != points.count {
            handleViews.forEach { $0.removeFromSuperview() }
            handleViews = points.indices.map { i in
                let handle = UIView()
                handle.backgroundColor = .white
                handle.layer.borderColor = Theme.uiAccent.cgColor
                handle.tag = i
                handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDragged(_:))))
                overlay.addSubview(handle)
                return handle
            }
        }
        let size = 26 / max(canvas.zoomScale, 0.1)
        for (handle, p) in zip(handleViews, points) {
            handle.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            handle.center = p
            handle.layer.cornerRadius = size / 2
            handle.layer.borderWidth = 3 / max(canvas.zoomScale, 0.1)
        }
    }

    @objc private func handleDragged(_ gesture: UIPanGestureRecognizer) {
        guard let editor, let index = gesture.view?.tag else { return }
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            shapeDrag = (point, editor.shape)
        case .changed:
            guard let base = shapeDrag?.base else { return }
            editor.shape = base.moving(handle: index, to: point)
            shapesView.preview = editor.shape
            layoutHandles()
        default:
            shapeDrag = nil
            commitShape(editor.shape)
        }
    }

    @objc private func shapeMoved(_ gesture: UIPanGestureRecognizer) {
        guard let editor else { return }
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            shapeDrag = (point, editor.shape)
        case .changed:
            guard let drag = shapeDrag else { return }
            editor.shape = drag.base.translated(by: CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y))
            shapesView.preview = editor.shape
            layoutHandles()
        default:
            shapeDrag = nil
            commitShape(editor.shape)
        }
    }

    // Box selection: handwriting to text, or linking

    @objc private func selectionPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            let t = gesture.translation(in: overlay)
            selectionStart = CGPoint(x: point.x - t.x, y: point.y - t.y)
        case .changed:
            selectionLayer.path = UIBezierPath(roundedRect: Self.rect(selectionStart, point), cornerRadius: 6).cgPath
        case .ended:
            selectionLayer.path = nil
            let rect = Self.rect(selectionStart, point)
            if mode == .link {
                if rect.width > 8, rect.height > 8 { onLinkArea?(rect) }
                onModeDone?()
            } else if !strokes(in: rect).isEmpty {
                // keep the box showing while the menu decides what to do with it
                inkSelection = rect
                selectionLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 6).cgPath
                let source = overlay.convert(CGPoint(x: rect.midX, y: rect.minY), to: self)
                editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: source))
            } else {
                onModeDone?()
            }
        default:
            selectionLayer.path = nil
        }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func convertStrokes(in rect: CGRect) {
        let drawing = canvas.drawing
        let picked = strokes(in: rect)
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
            self.editPage("Convert to Text") { $0.textBoxes.append(box) }
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
                self.page = updated
                self.onEditPage?({ page in page = updated })
                self.rebuildOverlay()
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

extension NoteCanvasView {
    // Typing in place

    /// Opens a text box for typing (or Scribble) right on the page.
    func beginTyping(_ box: TextBox, isNew: Bool) {
        endTyping()
        let view = UITextView()
        view.text = box.text
        view.font = Self.typingFont(box.fontSize)
        view.textColor = box.sticky == nil ? inkColor : .black
        view.backgroundColor = box.sticky.map { UIColor(hex: $0) } ?? Theme.uiAccent.withAlphaComponent(0.06)
        view.layer.cornerRadius = box.sticky == nil ? 6 : 3
        view.layer.borderColor = Theme.uiAccent.withAlphaComponent(0.6).cgColor
        view.layer.borderWidth = 1.5
        view.isScrollEnabled = false
        view.textContainerInset = box.sticky == nil ? UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2) : UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.delegate = self
        let bar = UIToolbar()
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
                     UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.endTyping() })]
        bar.sizeToFit()
        view.inputAccessoryView = bar
        typing = (view, box, isNew)
        sizeTyping()
        overlay.addSubview(view)
        boxViews[box.id]?.isHidden = true
        view.becomeFirstResponder()
    }

    static func typingFont(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
    }

    private func sizeTyping() {
        guard let typing else { return }
        let origin = typing.box.origin
        let width = typing.box.sticky != nil ? Self.stickyWidth : max(min(560, pageSize.width - origin.x - 20), 200)
        let fit = typing.view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let minimum = typing.box.sticky != nil ? Self.stickyWidth * 0.86 : typing.box.fontSize * 1.6
        typing.view.frame = CGRect(origin: origin, size: CGSize(width: width, height: max(fit.height, minimum)))
    }

    func textViewDidChange(_ textView: UITextView) {
        sizeTyping()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        // Scribble hands focus around while writing; only a real finish closes the box
        DispatchQueue.main.async { [weak self] in
            guard let self, let typing = self.typing, typing.view === textView, !textView.isFirstResponder else { return }
            self.endTyping()
        }
    }

    /// Saves what was typed: a new box, an edit, or nothing when it's empty.
    func endTyping() {
        guard let typing else { return }
        self.typing = nil
        let text = typing.view.text.trimmingCharacters(in: .whitespacesAndNewlines)
        typing.view.removeFromSuperview()
        let box = typing.box
        if typing.isNew {
            if text.isEmpty {
                rebuildOverlay()
            } else {
                var added = box
                added.text = text
                editPage(box.sticky == nil ? "Add Text" : "Add Note") { $0.textBoxes.append(added) }
            }
        } else if text != box.text {
            editPage(text.isEmpty ? "Delete Text" : "Edit Text") { page in
                guard let i = page.textBoxes.firstIndex(where: { $0.id == box.id }) else { return }
                if text.isEmpty { page.textBoxes.remove(at: i) } else { page.textBoxes[i].text = text }
            }
        } else {
            rebuildOverlay()
        }
        ink.activate()
    }

    /// The text pen: a finger tap types at that spot, or into the text that's there.
    @objc func typeTapped(_ gesture: UITapGestureRecognizer) {
        if typing != nil {
            endTyping()
            return
        }
        let point = gesture.location(in: overlay)
        if let box = page?.textBoxes.reversed().first(where: { $0.anchor == nil && boxViews[$0.id]?.frame.contains(point) == true }) {
            beginTyping(box, isNew: false)
        } else {
            beginTyping(TextBox(text: "", origin: CGPoint(x: point.x, y: point.y - 18), fontSize: 24), isNew: true)
        }
    }

    // To-do lists

    func checklistView(_ list: Checklist) -> UIView {
        let width: CGFloat = 380
        let container = UIView()
        var y: CGFloat = 0
        var titleConfig = UIButton.Configuration.plain()
        titleConfig.attributedTitle = AttributedString(list.title, attributes: AttributeContainer([
            .font: Self.typingFont(list.fontSize * 1.1).withWeight(.bold), .foregroundColor: inkColor,
        ]))
        titleConfig.contentInsets = .zero
        let title = UIButton(configuration: titleConfig)
        title.contentHorizontalAlignment = .leading
        title.menu = UIMenu(children: [
            UIAction(title: "Edit List", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.editChecklist(list, isNew: false) },
            UIAction(title: "Clear Ticked", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                self?.editPage("Clear Ticked") { page in
                    if let i = page.checklists.firstIndex(where: { $0.id == list.id }) { page.checklists[i].items.removeAll { $0.done } }
                }
            },
            UIAction(title: "Delete List", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.editPage("Delete List") { page in page.checklists.removeAll { $0.id == list.id } }
            },
        ])
        title.showsMenuAsPrimaryAction = true
        title.frame = CGRect(x: 0, y: 0, width: width, height: list.fontSize * 1.8)
        container.addSubview(title)
        y += title.frame.height + 4
        for item in list.items {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: item.done ? "checkmark.square.fill" : "square",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: list.fontSize * 0.9))
            config.imagePadding = 10
            config.contentInsets = .zero
            config.baseForegroundColor = item.done ? Theme.uiAccent : inkColor
            var attrs: [NSAttributedString.Key: Any] = [.font: Self.typingFont(list.fontSize),
                                                        .foregroundColor: item.done ? inkColor.withAlphaComponent(0.45) : inkColor]
            if item.done { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            config.attributedTitle = AttributedString(NSAttributedString(string: item.text, attributes: attrs))
            let row = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                UISelectionFeedbackGenerator().selectionChanged()
                self?.editPage(item.done ? "Untick" : "Tick") { page in
                    guard let i = page.checklists.firstIndex(where: { $0.id == list.id }),
                          let j = page.checklists[i].items.firstIndex(where: { $0.id == item.id }) else { return }
                    page.checklists[i].items[j].done.toggle()
                }
            })
            row.contentHorizontalAlignment = .leading
            row.titleLabel?.numberOfLines = 0
            let height = max(list.fontSize * 1.7, row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            row.frame = CGRect(x: 0, y: y, width: width, height: height)
            container.addSubview(row)
            y += height
        }
        container.frame = CGRect(origin: list.origin, size: CGSize(width: width, height: y))
        return container
    }

    /// One line per item, "[x]" in front marking it done; the first line is the title.
    func editChecklist(_ list: Checklist, isNew: Bool) {
        guard let presenter = viewController else { return }
        let lines = [list.title] + list.items.map { ($0.done ? "[x] " : "") + $0.text }
        let start = isNew ? list.title + "\n" : lines.joined(separator: "\n")
        TextBoxEditor.present(from: presenter, text: start, title: isNew ? "New To-Do List" : "Edit To-Do List") { [weak self] text in
            var rows = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !rows.isEmpty else {
                if !isNew { self?.editPage("Delete List") { page in page.checklists.removeAll { $0.id == list.id } } }
                return
            }
            var edited = list
            edited.title = rows.removeFirst()
            edited.items = rows.map { row in
                var line = row
                for prefix in ["- ", "* "] where line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
                let done = line.lowercased().hasPrefix("[x]")
                if done || line.hasPrefix("[ ]") { line = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                return ChecklistItem(id: list.items.first { $0.text == line }?.id ?? UUID(), text: line, done: done)
            }
            self?.editPage(isNew ? "Add To-Do List" : "Edit To-Do List") { page in
                if let i = page.checklists.firstIndex(where: { $0.id == list.id }) { page.checklists[i] = edited } else { page.checklists.append(edited) }
            }
        }
    }

    // Voice notes

    func voiceChip(_ note: VoiceNote) -> UIView {
        let url = audioURL?(note.file)
        let playing = url != nil && VoicePlayer.shared.playing == url
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: playing ? "stop.fill" : "waveform")
        config.imagePadding = 6
        config.title = note.title + "  " + VoiceRecorderSheet.clock(note.duration)
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.baseBackgroundColor = playing ? Theme.uiAccent : Theme.uiAccent.withAlphaComponent(0.85)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in
            if let url { VoicePlayer.shared.toggle(url) }
        })
        button.menu = UIMenu(title: note.title, children: [
            UIAction(title: "Delete Voice Note", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                VoicePlayer.shared.stop()
                self?.editPage("Delete Voice Note") { page in page.voiceNotes.removeAll { $0.id == note.id } }
            },
        ])
        button.sizeToFit()
        button.center = note.position
        return button
    }

    // Handwriting selection

    func strokes(in rect: CGRect) -> [Int] {
        let drawing = canvas.drawing
        return drawing.strokes.indices.filter {
            let r = drawing.strokes[$0].renderBounds
            return rect.contains(CGPoint(x: r.midX, y: r.midY))
        }
    }

    func inkMenu(_ rect: CGRect) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Turn into Typed Text", image: UIImage(systemName: "textformat")) { [weak self] _ in self?.convertStrokes(in: rect) },
            UIAction(title: "Restyle with Current Pen", image: UIImage(systemName: "paintbrush.pointed")) { [weak self] _ in self?.restyle(in: rect, width: nil) },
            UIAction(title: "Thicker", image: UIImage(systemName: "lineweight")) { [weak self] _ in self?.restyle(in: rect, width: 1.4) },
            UIAction(title: "Thinner", image: UIImage(systemName: "line.3.horizontal")) { [weak self] _ in self?.restyle(in: rect, width: 0.7) },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                let gone = Set(self.strokes(in: rect))
                let kept = self.canvas.drawing.strokes.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
                self.ink.commit(PKDrawing(strokes: kept), name: "Delete Handwriting")
            },
        ])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        guard inkSelection != nil else { return }
        inkSelection = nil
        selectionLayer.path = nil
        onModeDone?()
    }

    /// Redraws the picked strokes with the current pen's ink and colour, or just scales their width.
    func restyle(in rect: CGRect, width factor: CGFloat?) {
        let picked = Set(strokes(in: rect))
        guard !picked.isEmpty else { return }
        let pen = InkTools.shared.tool as? PKInkingTool
        if factor == nil, pen == nil { return }
        let strokes = canvas.drawing.strokes.enumerated().map { i, stroke -> PKStroke in
            guard picked.contains(i) else { return stroke }
            let sizes = stroke.path.map(\.size.width)
            let average = sizes.reduce(0, +) / CGFloat(max(sizes.count, 1))
            let k = factor ?? min(max((pen?.width ?? average) / max(average, 0.1), 0.2), 5)
            let points = stroke.path.map { p in
                PKStrokePoint(location: p.location, timeOffset: p.timeOffset, size: CGSize(width: p.size.width * k, height: p.size.height * k),
                              opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude)
            }
            var inked = stroke.ink
            if factor == nil, let pen { inked = PKInk(pen.inkType, color: pen.color) }
            return PKStroke(ink: inked, path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
                            transform: stroke.transform, mask: stroke.mask)
        }
        ink.commit(PKDrawing(strokes: strokes), name: "Restyle Handwriting")
    }
}

/// With the text pen, writing anywhere on the page becomes typed text through Scribble, Apple's own handwriting engine.
extension NoteCanvasView: UIIndirectScribbleInteractionDelegate {
    private static let newText = "new"

    func indirectScribbleInteraction(_ interaction: UIInteraction, requestElementsIn rect: CGRect, completion: @escaping ([String]) -> Void) {
        guard InkTools.shared.writesText, mode == .draw, let page else { return completion([]) }
        // writing over existing text goes into it; a new box only where there's none, or the two fight
        var ids = page.textBoxes.filter { $0.anchor == nil }.map(\.id.uuidString)
        if let typing, typing.isNew { ids.insert(typing.box.id.uuidString, at: 0) }
        let near = ids.filter { frame(of: $0)?.intersects(rect) == true }
        completion(near.isEmpty ? [Self.newText] : near)
    }

    /// Where writing goes into a box: the box, plus room to carry on along the line and just below.
    private func frame(of id: String) -> CGRect? {
        let f: CGRect
        if let typing, typing.box.id.uuidString == id {
            f = typing.view.frame
        } else if let box = page?.textBoxes.first(where: { $0.id.uuidString == id }), let view = boxViews[box.id] {
            f = view.frame
        } else {
            return nil
        }
        return overlay.convert(CGRect(x: f.minX - 20, y: f.minY - 10, width: f.width + 260, height: f.height + 60), to: self)
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, isElementFocused elementIdentifier: String) -> Bool {
        typing?.box.id.uuidString == elementIdentifier && typing?.view.isFirstResponder == true
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, frameForElement elementIdentifier: String) -> CGRect {
        if elementIdentifier == Self.newText {
            return overlay.convert(overlay.bounds, to: self)
        }
        return frame(of: elementIdentifier) ?? .zero
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, focusElementIfNeeded elementIdentifier: String, referencePoint focusReferencePoint: CGPoint,
                                     completion: @escaping ((any UIResponder & UITextInput)?) -> Void) {
        if typing?.box.id.uuidString != elementIdentifier {
            if let box = page?.textBoxes.first(where: { $0.id.uuidString == elementIdentifier }) {
                beginTyping(box, isNew: false)
            } else {
                let p = convert(focusReferencePoint, to: overlay)
                beginTyping(TextBox(text: "", origin: CGPoint(x: p.x, y: p.y - 18), fontSize: 24), isNew: true)
            }
        }
        typing?.view.becomeFirstResponder()
        completion(typing?.view)
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: pointSize)
    }
}

/// Only its subviews take touches; everything else falls through to the canvas.
class PassthroughView: UIView {
    /// Views with this tag let the pencil through so you can keep writing over them.
    static let pencilThroughTag = 7701

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self { return nil }
        if hit?.tag == Self.pencilThroughTag, event?.allTouches?.contains(where: { $0.type == .pencil }) == true {
            return nil
        }
        return hit
    }
}

/// Gesture delegate driven by a closure.
/// Corner folds go first: scrolling and page turns around the page wait to see if a corner is being pulled.
final class FoldGate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: (UIGestureRecognizer) -> Bool = { _ in true }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        shouldBegin(gesture)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gesture is UIPanGestureRecognizer, let mine = gesture.view, let theirs = other.view else { return false }
        return other is UIPanGestureRecognizer && mine.isDescendant(of: theirs)
    }
}

final class GestureGate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: (UIGestureRecognizer) -> Bool = { _ in true }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        shouldBegin(gesture)
    }
}

/// Lets page swipes run alongside scrolling, but only when allowed.
final class SwipeGate: NSObject, UIGestureRecognizerDelegate {
    var canBegin: (UISwipeGestureRecognizer) -> Bool = { _ in true }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        (gesture as? UISwipeGestureRecognizer).map(canBegin) ?? true
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
