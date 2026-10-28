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
final class NoteCanvasView: UIView, UIEditMenuInteractionDelegate {
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
        }
    }

    /// Whole page fitted on screen, no scrolling, fingers left free to turn pages.
    var bookMode = false {
        didSet {
            guard bookMode != oldValue else { return }
            ink.fingerAllowed = !bookMode
            applyScrolling()
            fittedSize = .zero
            setNeedsLayout()
        }
    }

    private func applyScrolling() {
        canvas.isScrollEnabled = !bookMode && (mode == .draw || mode == .arrange)
        canvas.pinchGestureRecognizer?.isEnabled = !bookMode && mode != .arrange
    }

    private let ink = InkController()
    private var canvas: PKCanvasView { ink.canvas }
    private let paper = PaperView()
    private let media = UIView()
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
        case text(UUID), link(UUID), image(UUID)
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

        for view in [paper, media, overlay] as [UIView] {
            view.bounds = CGRect(origin: .zero, size: pageSize)
        }
        media.isUserInteractionEnabled = false
        // pictures sit between the paper and the ink so you can write on them
        canvas.insertSubview(paper, at: 0)
        canvas.insertSubview(media, aboveSubview: paper)
        canvas.addSubview(overlay)

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
        ink.onZoom = { [weak self] in self?.syncZoom() }
        ink.extrasHit = { [weak self] area in !(self?.boxes(in: area).isEmpty ?? true) }
        ink.eraseExtras = { [weak self] area in
            guard let self else { return }
            let ids = Set(self.boxes(in: area).map(\.id))
            self.editPage("Scribble Erase") { page in page.textBoxes.removeAll { ids.contains($0.id) } }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ page: NotePage, paper style: PaperStyle, color: PaperColor, size: CGSize, background: PDFPage?, drawing: () -> PKDrawing) {
        if size != pageSize {
            pageSize = size
            for view in [paper, media, overlay] as [UIView] {
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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != fittedSize else { return }
        fittedSize = bounds.size
        let fit = bookMode
            ? min(bounds.width / pageSize.width, bounds.height / pageSize.height) * 0.96
            : bounds.width / pageSize.width
        fitScale = fit
        canvas.minimumZoomScale = fit * 0.5
        canvas.maximumZoomScale = fit * 4
        canvas.zoomScale = fit
        syncZoom()
    }

    private func syncZoom() {
        let zoom = canvas.zoomScale
        let size = CGSize(width: pageSize.width * zoom, height: pageSize.height * zoom)
        canvas.contentSize = size
        for view in [paper, media, overlay] as [UIView] {
            view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            view.center = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let inset = max(0, (canvas.bounds.width - size.width) / 2)
        let top = bookMode ? max(0, (canvas.bounds.height - size.height) / 2) : 0
        canvas.contentInset = UIEdgeInsets(top: top, left: inset, bottom: top, right: inset)
        // sharper paper when zoomed, but only redrawn on real changes and capped to keep memory down
        let scale = min(traitCollection.displayScale * zoom, 3)
        if abs(scale - paper.contentScaleFactor) / scale > 0.15 {
            paper.contentScaleFactor = scale
            paper.setNeedsDisplay()
        }
        canvas.bringSubviewToFront(overlay)
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
        canvas.bringSubviewToFront(overlay)
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
        }
    }

    @objc private func arrangePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            guard let item = item(at: point) else { return }
            dragging = (item, point)
        case .changed:
            guard let dragging, let view = view(for: dragging.item) else { return }
            view.transform = CGAffineTransform(translationX: point.x - dragging.start.x, y: point.y - dragging.start.y)
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
                }
            }
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
            guard let pinching, let view = view(for: pinching) else { return }
            view.transform = CGAffineTransform(scaleX: gesture.scale, y: gesture.scale)
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
                case .link:
                    break
                }
            }
        default:
            pinching = nil
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
        actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.editPage("Delete") { page in
                switch item {
                case .text(let id): page.textBoxes.removeAll { $0.id == id }
                case .link(let id): page.links.removeAll { $0.id == id }
                case .image(let id): page.images.removeAll { $0.id == id }
                }
            }
        })
        return UIMenu(children: actions)
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
