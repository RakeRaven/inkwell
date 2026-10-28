import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// What a finger or pencil does on the page besides drawing.
enum CanvasMode {
    case draw
    /// Drag a box over handwriting to turn it into text.
    case convert
    /// Drag a box over handwriting or text to link it.
    case link
    /// Move, resize and delete images, text and links.
    case arrange
}

/// Ready-made shapes for the insert menu.
enum ShapePreset {
    case equilateral, rightTriangle, square, circle, line, angle, projectile, graph
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
final class NoteCanvasView: UIView, UIEditMenuInteractionDelegate, UIPopoverPresentationControllerDelegate {
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
            canvas.drawingGestureRecognizer.isEnabled = mode == .draw
            // arranging keeps two-finger scrolling; one finger moves things
            canvas.panGestureRecognizer.minimumNumberOfTouches = mode == .arrange ? 2 : 1
            overlay.isUserInteractionEnabled = mode != .arrange
            applyScrolling()
            rebuildOverlay()
            updateRuler()
        }
    }

    /// Whole page fitted on screen, no scrolling, fingers left free to turn pages.
    var bookMode = false {
        didSet {
            guard bookMode != oldValue else { return }
            ink.fingerAllowed = !bookMode
            // book pages are paper edge to edge, and a spread's blank end page stays white
            backgroundColor = bookMode ? .white : Theme.uiPaper
            spine.isHidden = !bookMode
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
    private let rulerLayer = PassthroughView()
    private var ruler: RulerView?
    private lazy var cornerPress = UILongPressGestureRecognizer(target: self, action: #selector(cornerPressed(_:)))
    private let cornerGate = GestureGate()

    private func raiseLayers() {
        canvas.bringSubviewToFront(overlay)
        canvas.bringSubviewToFront(foldView)
        canvas.bringSubviewToFront(rulerLayer)
    }

    /// The corner a finger is holding, in a zone that stays the same size on screen.
    private func corner(at point: CGPoint) -> PageCorner? {
        let reach = max(FoldView.size, 60 / max(canvas.zoomScale, 0.1))
        let page = CGRect(origin: .zero, size: pageSize)
        return PageCorner.allCases.first { corner in
            let c = corner.point(in: page)
            return hypot(point.x - c.x, point.y - c.y) < reach
        }
    }

    @objc private func cornerPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let corner = corner(at: gesture.location(in: overlay)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let folding = !(page?.folds ?? []).contains(corner)
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        foldView.layer.add(fade, forKey: "fold")
        editPage(folding ? "Fold Corner" : "Unfold Corner") { page in
            var folds = page.folds ?? []
            if folding { folds.append(corner) } else { folds.removeAll { $0 == corner } }
            page.folds = folds.isEmpty ? nil : folds
        }
    }

    /// Shows the ruler on the page being written on, and only there.
    private func updateRuler() {
        let tools = InkTools.shared
        guard tools.ruler, tools.active === ink, window != nil, mode == .draw else {
            ruler?.removeFromSuperview()
            ruler = nil
            return
        }
        let view = ruler ?? RulerView()
        if ruler == nil {
            ruler = view
            rulerLayer.addSubview(view)
            view.onMove = { middle, angle in
                tools.rulerMiddle = middle
                tools.rulerAngle = angle
            }
        }
        let page = CGRect(origin: .zero, size: pageSize)
        var middle = tools.rulerMiddle ?? visibleCenter()
        middle.x = min(max(middle.x, page.minX), page.maxX)
        middle.y = min(max(middle.y, page.minY), page.maxY)
        view.place(at: middle, angle: tools.rulerAngle)
    }

    private func applyScrolling() {
        // a book page only pans once zoomed in, otherwise fingers turn pages
        let pans = bookMode ? bookZoom?.zoomed == true : true
        canvas.isScrollEnabled = pans && (mode == .draw || mode == .arrange)
        canvas.pinchGestureRecognizer?.isEnabled = mode != .arrange
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
        if scale < 1.03 {
            // back at the whole page: settle exactly so page turns come back
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
    private weak var inspector: UIViewController?
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
    private var pendingMath: DispatchWorkItem?
    private let swipeGate = SwipeGate()
    private var pushDirection = 0
    private var dragging: (item: Item, start: CGPoint)?
    private var pinching: Item?
    private var menuItem: Item?

    private enum Item: Equatable {
        case text(UUID), link(UUID), image(UUID), shape(UUID)
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

        for view in [paper, media, shapesView, overlay, foldView, rulerLayer] as [UIView] {
            view.bounds = CGRect(origin: .zero, size: pageSize)
        }
        media.isUserInteractionEnabled = false
        // pictures sit between the paper and the ink so you can write on them
        canvas.insertSubview(paper, at: 0)
        canvas.insertSubview(media, aboveSubview: paper)
        canvas.insertSubview(shapesView, aboveSubview: media)
        canvas.addSubview(overlay)
        canvas.addSubview(foldView)
        canvas.addSubview(rulerLayer)

        // hold a page corner to fold it over and bookmark the page
        cornerPress.minimumPressDuration = 0.45
        cornerPress.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        cornerPress.delegate = cornerGate
        canvas.addGestureRecognizer(cornerPress)
        cornerGate.shouldBegin = { [weak self] gesture in
            guard let self, self.mode == .draw else { return false }
            return self.corner(at: gesture.location(in: self.overlay)) != nil
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
            return shape.distance(to: point) < 24
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
        ink.onToolsChanged = { [weak self] in self?.updateRuler() }
        ink.adjustStroke = { [weak self] stroke in self?.ruler?.straightened(stroke) }
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
            for view in [paper, media, shapesView, overlay, foldView, rulerLayer] as [UIView] {
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
            if pushDirection != 0 {
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
        pushDirection = delta
        if onSwipe?(delta) != true { pushDirection = 0 }
    }

    /// Wires the view to a notebook page and shows it.
    func bind(store: NotebookStore, page: NotePage, onOpenLink: @escaping (NoteLink) -> Void, onLinkArea: @escaping (CGRect) -> Void) {
        let id = page.id
        onDrawingChange = { [store] in store.setDrawing($0, for: id) }
        onEditPage = { [store] change in store.update(id, change) }
        onLinkTap = onOpenLink
        self.onLinkArea = onLinkArea
        imageProvider = { [store] in store.image($0) }
        let notebook = store.notebook
        show(page, paper: notebook.style(of: page), color: notebook.color(of: page), size: notebook.size(of: page),
             background: page.background.flatMap { store.pdfPage(for: $0) }) { store.drawing(for: id) }
    }

    func beginNewText() {
        guard let presenter = viewController else { return }
        let origin = visibleCenter()
        TextBoxEditor.present(from: presenter, text: "", title: "New Text") { [weak self] text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let box = TextBox(text: trimmed, origin: CGPoint(x: max(origin.x - 160, 20), y: origin.y), fontSize: 24)
            self?.editPage("Add Text") { $0.textBoxes.append(box) }
        }
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
        updateRuler()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spine.place(in: bounds)
        bringSubviewToFront(spine)
        guard bounds.width > 0, bounds.height > 0, bounds.size != fittedSize else { return }
        fittedSize = bounds.size
        let fit = bookMode
            ? min(bounds.width / pageSize.width, bounds.height / pageSize.height)
            : bounds.width / pageSize.width
        fitScale = fit
        // a book page never shrinks below the paper
        canvas.minimumZoomScale = bookMode ? fit : fit * 0.5
        canvas.maximumZoomScale = fit * 4
        canvas.zoomScale = fit
        syncZoom()
        applyBookZoom()
    }

    private func syncZoom() {
        let zoom = canvas.zoomScale
        let size = CGSize(width: pageSize.width * zoom, height: pageSize.height * zoom)
        canvas.contentSize = size
        for view in [paper, media, shapesView, overlay, foldView, rulerLayer] as [UIView] {
            view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            view.center = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let inset = max(0, (canvas.bounds.width - size.width) / 2)
        // a page smaller than the view sits in the middle, not at the top
        let top = max(0, (canvas.bounds.height - size.height) / 2)
        canvas.contentInset = UIEdgeInsets(top: top, left: inset, bottom: top, right: inset)
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
        overlay.subviews.forEach { $0.removeFromSuperview() }
        media.subviews.forEach { $0.removeFromSuperview() }
        boxViews.removeAll()
        linkViews.removeAll()
        imageViews.removeAll()
        guard let page else { return }
        shapesView.shapes = page.shapes
        if let id = selectedShape {
            if let current = page.shapes.first(where: { $0.id == id }) {
                if shapeDrag == nil { editor?.shape = current }
            } else {
                deselectShape()
            }
        }
        shapesView.selected = selectedShape
        foldView.folds = page.folds ?? []
        foldView.paperColor = paper.color.fill
        foldView.behind = backgroundColor ?? Theme.uiPaper
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
        for box in page.textBoxes {
            let view = textBoxView(box)
            boxViews[box.id] = view
            overlay.addSubview(view)
        }
        for link in page.links {
            let view = link.area == nil ? linkChip(link) : areaLink(link)
            linkViews[link.id] = view
            overlay.addSubview(view)
        }
        if mode == .arrange {
            for view in Array(boxViews.values) + Array(linkViews.values) {
                view.layer.borderColor = Theme.uiAccent.withAlphaComponent(0.6).cgColor
                view.layer.borderWidth = 1.5
            }
        }
        overlay.layer.addSublayer(selectionLayer)
        handleViews = []
        layoutHandles()
        raiseLayers()
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
            label.attributedText = Markdown.render(box.text, size: box.fontSize, color: inkColor)
        }
        let size = label.sizeThatFits(CGSize(width: min(560, pageSize.width - 40), height: .greatestFiniteMagnitude))
        label.frame = CGRect(origin: .zero, size: size)
        label.isUserInteractionEnabled = false

        let button = UIButton(type: .custom)
        button.addSubview(label)
        if let anchor = box.anchor {
            button.frame = CGRect(x: anchor.x, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        } else {
            button.frame = CGRect(origin: box.origin, size: size)
        }

        var actions: [UIMenuElement] = [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = box.text
            },
        ]
        if box.anchor == nil {
            actions.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.edit(box) })
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
        return button
    }

    private func linkChip(_ link: NoteLink) -> UIView {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: link.target.docID == nil ? "safari" : "link")
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
                case .link:
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
                }
            }
        })
        return UIMenu(children: actions)
    }

    // Shapes

    private func shape(at point: CGPoint) -> ShapeItem? {
        page?.shapes.reversed().first { $0.distance(to: point) < 16 }
    }

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
        }
        let id = shape.id
        editPage("Add Shape") { $0.shapes.append(shape) }
        selectShape(id)
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
            self?.inspector?.dismiss(animated: true)
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
        if let inspector, inspector.presentingViewController != nil {
            inspector.dismiss(animated: animated)
        }
    }

    private func presentInspector(for shape: ShapeItem, editor: ShapeEditor) {
        // present from whatever is on top, unless something else is already showing there
        guard var presenter = viewController else { return }
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        guard presenter.presentedViewController == nil || presenter.presentedViewController?.isBeingDismissed == true,
              presenter.viewIfLoaded?.window != nil else { return }
        let host = UIHostingController(rootView: ShapeInspector(editor: editor))
        host.modalPresentationStyle = .popover
        host.preferredContentSize = CGSize(width: 340, height: shape.kind == .projectile || shape.kind == .graph ? 620 : 470)
        if let pop = host.popoverPresentationController {
            pop.sourceView = self
            let rect = overlay.convert(shape.bounds, to: self).intersection(bounds.insetBy(dx: 20, dy: 20))
            let finite = !rect.isNull && rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            pop.sourceRect = finite ? rect : CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = [.left, .right, .up, .down]
            // the page stays live so handles can be dragged with the panel open
            pop.passthroughViews = [self]
            pop.delegate = self
        }
        presenter.present(host, animated: true)
        inspector = host
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        deselectShape()
    }

    private func commitShape(_ shape: ShapeItem) {
        shapesView.preview = nil
        editPage("Edit Shape") { page in
            if let i = page.shapes.firstIndex(where: { $0.id == shape.id }) { page.shapes[i] = shape }
        }
    }

    /// Round grab handles on the selected shape, kept the same size on screen at any zoom.
    private func layoutHandles() {
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
            } else {
                convertStrokes(in: rect)
            }
            onModeDone?()
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

/// Only its subviews take touches; everything else falls through to the canvas.
final class PassthroughView: UIView {
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
