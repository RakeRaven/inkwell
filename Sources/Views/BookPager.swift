import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// Turns pages with a real page curl: drag to fold the page and hold it there,
/// flick or drag past halfway to turn, let go early to drop it back.
struct PageCurlPager: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    let makePage: (Int) -> UIView
    /// Refreshes the page on screen when its content changes.
    let refresh: (UIView, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                         options: [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)])
        pager.isDoubleSided = false
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = Theme.uiPaper
        pager.setViewControllers([context.coordinator.host(clamped(index))], direction: .forward, animated: false)
        // fingers turn pages; the pencil keeps writing
        for gesture in pager.gestureRecognizers {
            gesture.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard let current = pager.viewControllers?.first as? PageHost else { return }
        let target = clamped(index)
        if current.index != target {
            // jumps from the bar or links turn the page too
            pager.setViewControllers([context.coordinator.host(target)], direction: target > current.index ? .forward : .reverse, animated: true)
        } else {
            refresh(current.view, target)
        }
    }

    private func clamped(_ i: Int) -> Int {
        min(max(i, 0), max(count - 1, 0))
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlPager

        init(_ parent: PageCurlPager) {
            self.parent = parent
        }

        func host(_ index: Int) -> PageHost {
            let host = PageHost(index: index, content: parent.makePage(index))
            parent.refresh(host.view, index)
            return host
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? PageHost)?.index, i > 0 else { return nil }
            return host(i - 1)
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? PageHost)?.index, i < parent.count - 1 else { return nil }
            return host(i + 1)
        }

        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pager.viewControllers?.first as? PageHost else { return }
            parent.index = current.index
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

    init(page: PDFPage, annotations: DrawingStore, key: String) {
        self.page = page
        super.init(frame: .zero)
        backgroundColor = Theme.uiPaper
        paper.page = page
        addSubview(paper)
        ink.fingerAllowed = false
        ink.canvas.isScrollEnabled = false
        ink.load(annotations.drawing(key))
        ink.onChange = { annotations.set($0, for: key) }
        // same page-point coordinates as the scrolling reader, so ink matches in both
        ink.canvas.bounds = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
        addSubview(ink.canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        let scale = min(bounds.width / box.width, bounds.height / box.height) * 0.96
        let fitted = CGSize(width: box.width * scale, height: box.height * scale)
        paper.frame = CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        ink.canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
        ink.canvas.center = CGPoint(x: paper.frame.midX, y: paper.frame.midY)
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
