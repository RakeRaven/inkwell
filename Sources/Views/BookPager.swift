import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// The pager sized to the paper itself, so the curl lifts only the page.
/// Two pages side by side when that keeps them nearly as big as one.
struct BookLayout {
    let size: CGSize
    let spread: Bool

    init(page: CGSize, space: CGSize) {
        let room = CGSize(width: space.width * 0.96, height: space.height * 0.96)
        guard page.width > 0, page.height > 0, room.width > 0, room.height > 0 else {
            size = space
            spread = false
            return
        }
        let single = min(room.width / page.width, room.height / page.height)
        let double = min(room.width / (page.width * 2), room.height / page.height)
        spread = double >= single * 0.8
        let scale = spread ? double : single
        size = CGSize(width: page.width * scale * (spread ? 2 : 1), height: page.height * scale)
    }
}

/// One zoom and position for every page in book mode, so turning keeps the same view.
final class BookZoom {
    /// Times the fitted size.
    private(set) var scale: CGFloat = 1
    /// Middle of the view as a fraction of the page.
    private(set) var center = CGPoint(x: 0.5, y: 0.5)
    var zoomed: Bool { scale > 1.01 }
    /// Page turning pauses while zoomed in, so fingers pan instead.
    var onZoomedChange: ((Bool) -> Void)?
    private let pages = NSHashTable<NoteCanvasView>.weakObjects()

    func add(_ page: NoteCanvasView) {
        pages.add(page)
    }

    func update(scale: CGFloat, center: CGPoint, from source: NoteCanvasView) {
        let was = zoomed
        self.scale = scale
        self.center = center
        for page in pages.allObjects where page !== source { page.applyBookZoom() }
        if was != zoomed { onZoomedChange?(zoomed) }
    }
}

/// Shadow along the binding, so a spread reads as two pages.
final class SpineShade: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    /// Which side of the page the binding is on.
    var edge: UIRectEdge = .left {
        didSet { update() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func place(in rect: CGRect) {
        let width = min(36, rect.width * 0.08)
        frame = CGRect(x: edge == .left ? rect.minX : rect.maxX - width, y: rect.minY, width: width, height: rect.height)
    }

    private func update() {
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [0.28, 0.08, 0].map { UIColor.black.withAlphaComponent($0).cgColor }
        gradient.locations = [0, 0.18, 1]
        gradient.startPoint = CGPoint(x: edge == .left ? 0 : 1, y: 0.5)
        gradient.endPoint = CGPoint(x: edge == .left ? 1 : 0, y: 0.5)
    }
}

/// Turns pages with a real page curl: drag to fold the page and hold it there,
/// flick or drag past halfway to turn, let go early to drop it back.
/// `spread` shows two pages side by side like an open book.
struct PageCurlPager: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    let spread: Bool
    var zoom: BookZoom?
    let makePage: (Int) -> UIView
    /// Refreshes the page on screen when its content changes.
    let refresh: (UIView, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let spine: UIPageViewController.SpineLocation = spread ? .mid : .min
        let pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                         options: [.spineLocation: NSNumber(value: spine.rawValue)])
        pager.isDoubleSided = spread
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .clear
        context.coordinator.pager = pager
        pager.setViewControllers(context.coordinator.hosts(at: index), direction: .forward, animated: false)
        // fingers turn pages; the pencil keeps writing
        for gesture in pager.gestureRecognizers {
            gesture.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            gesture.isEnabled = zoom?.zoomed != true
        }
        zoom?.onZoomedChange = { [weak pager] zoomed in
            pager?.gestureRecognizers.forEach { $0.isEnabled = !zoomed }
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let current = pager.viewControllers?.first as? PageHost else { return }
        let target = coordinator.first(of: index)
        if current.index != target {
            // jumps from the bar or links turn the page too
            pager.setViewControllers(coordinator.hosts(at: index), direction: target > current.index ? .forward : .reverse, animated: true)
        } else {
            for case let host as PageHost in pager.viewControllers ?? [] {
                refresh(host.view, host.index)
            }
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlPager
        weak var pager: UIPageViewController?

        init(_ parent: PageCurlPager) {
            self.parent = parent
        }

        /// The page shown first (on the left in a spread) for a page index.
        func first(of index: Int) -> Int {
            let i = min(max(index, 0), max(parent.count - 1, 0))
            return parent.spread ? i - i % 2 : i
        }

        /// Pages beyond the end become blank paper so a spread always has a right-hand page.
        private var last: Int {
            parent.spread && parent.count % 2 == 1 ? parent.count : parent.count - 1
        }

        func hosts(at index: Int) -> [PageHost] {
            let start = first(of: index)
            return parent.spread ? [host(start), host(start + 1)] : [host(start)]
        }

        func host(_ index: Int) -> PageHost {
            let content = parent.makePage(index)
            // size and draw it before the curl snapshots it, or the turning page shows blank
            if let bounds = pager?.view.bounds, bounds.width > 0 {
                content.frame = CGRect(x: 0, y: 0, width: parent.spread ? bounds.width / 2 : bounds.width, height: bounds.height)
            }
            parent.refresh(content, index)
            content.layoutIfNeeded()
            (content as? NoteCanvasView)?.prepareForSnapshot()
            (content as? PDFBookPage)?.prepareForSnapshot()
            return PageHost(index: index, content: content)
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? PageHost)?.index, i > 0 else { return nil }
            return host(i - 1)
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? PageHost)?.index, i < last else { return nil }
            return host(i + 1)
        }

        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pager.viewControllers?.first as? PageHost else { return }
            parent.index = min(current.index, max(parent.count - 1, 0))
        }
    }
}

final class PageHost: UIViewController {
    let index: Int
    private let content: UIView

    init(index: Int, content: UIView) {
        self.index = index
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = content
    }
}

/// One PDF page for book mode: the page drawn to fit, with its annotation ink on top.
final class PDFBookPage: UIView {
    let ink = InkController()
    private let page: PDFPage
    private let paper = PDFPageDrawing()
    let spine = SpineShade()

    init(page: PDFPage, annotations: DrawingStore, key: String) {
        self.page = page
        super.init(frame: .zero)
        backgroundColor = .clear
        paper.page = page
        addSubview(paper)
        ink.fingerAllowed = false
        ink.canvas.isScrollEnabled = false
        ink.load(annotations.drawing(key))
        ink.onChange = { annotations.set($0, for: key) }
        // same page-point coordinates as the scrolling reader, so ink matches in both
        ink.canvas.bounds = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
        addSubview(ink.canvas)
        addSubview(spine)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func prepareForSnapshot() {
        layoutIfNeeded()
        paper.layer.displayIfNeeded()
    }

    var annotating = false {
        didSet {
            ink.canvas.isUserInteractionEnabled = annotating
            if annotating, window != nil { ink.activate() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let box = page.bounds(for: .cropBox).size
        guard box.width > 0, box.height > 0 else { return }
        let scale = min(bounds.width / box.width, bounds.height / box.height)
        let fitted = CGSize(width: box.width * scale, height: box.height * scale)
        paper.frame = CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        ink.canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
        ink.canvas.center = CGPoint(x: paper.frame.midX, y: paper.frame.midY)
        spine.place(in: paper.frame)
    }
}

private final class PDFPageDrawing: UIView {
    var page: PDFPage? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        guard let page, let ctx = UIGraphicsGetCurrentContext() else { return }
        PaperRenderer.draw(page, in: ctx, size: bounds.size)
    }
}
