import PDFKit
import PencilKit
import SwiftUI
import WebKit

struct PageJump: Equatable {
    let id = UUID()
    let page: Int
}

@Observable
final class ReaderState {
    var pageIndex = 0
    var chapterIndex = 0
    var jump: PageJump?
}

/// An open PDF or EPUB with its on-page annotations.
@Observable
final class ReaderModel {
    let item: LibraryItem
    let state = ReaderState()
    let annotations: DrawingStore
    private(set) var pdf: PDFDocument?
    private(set) var epub: EPUBBook?
    private(set) var chapters: [(title: String, page: Int)] = []
    private(set) var error: String?

    init(item: LibraryItem, library: Library) {
        self.item = item
        let folder = library.folder(for: item)
        annotations = DrawingStore(dir: folder.appending(path: "annotations"))
        guard let source = library.sourceURL(for: item) else {
            error = "This item has no file."
            return
        }
        switch item.kind {
        case .pdf:
            pdf = PDFDocument(url: source)
            if let pdf {
                chapters = pdf.chapters
            } else {
                error = "Couldn't open this PDF."
            }
        case .epub:
            do {
                epub = try EPUBBook.open(source, unpackTo: folder.appending(path: "unpacked"))
            } catch {
                self.error = "Couldn't open this EPUB: \(error.localizedDescription)"
            }
        case .notebook:
            break
        }
    }
}

struct Backlink: Identifiable {
    let id: UUID
    let notePage: Int
}

struct ReaderPane: View {
    let model: ReaderModel
    let annotating: Bool
    let showsBar: Bool
    let backlinks: [Backlink]
    let onBacklink: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showsBar {
                bar
                Divider()
            }
            content
        }
    }

    private var bar: some View {
        HStack(spacing: 18) {
            Text(location)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if !backlinks.isEmpty {
                Menu {
                    ForEach(backlinks) { link in
                        Button("Note page \(link.notePage + 1)") { onBacklink(link.notePage) }
                    }
                } label: {
                    Label("\(backlinks.count)", systemImage: "link")
                }
            }
            if !model.chapters.isEmpty {
                Menu {
                    ForEach(Array(model.chapters.enumerated()), id: \.offset) { _, chapter in
                        Button(chapter.title) { model.state.jump = PageJump(page: chapter.page) }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
            }
            if let book = model.epub {
                chapterControls(book)
            }
        }
        .padding(.horizontal)
        .frame(height: 44)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if let pdf = model.pdf {
            PDFReader(document: pdf, annotations: model.annotations, annotating: annotating, state: model.state)
        } else if let book = model.epub {
            EPUBReader(book: book, state: model.state)
        } else {
            ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle", description: Text(model.error ?? ""))
        }
    }

    private var location: String {
        let state = model.state
        if let pdf = model.pdf {
            var text = "Page \(state.pageIndex + 1) of \(pdf.pageCount)"
            if let chapter = model.chapters.last(where: { $0.page <= state.pageIndex }) {
                text += " · \(chapter.title)"
            }
            return text
        }
        if let book = model.epub, book.chapters.indices.contains(state.chapterIndex) {
            return book.chapters[state.chapterIndex].title
        }
        return model.item.title
    }

    @ViewBuilder
    private func chapterControls(_ book: EPUBBook) -> some View {
        let state = model.state
        Button { state.chapterIndex -= 1 } label: { Image(systemName: "chevron.left") }
            .disabled(state.chapterIndex <= 0)
        Menu {
            ForEach(Array(book.chapters.enumerated()), id: \.offset) { i, chapter in
                Button(chapter.title) { state.chapterIndex = i }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        Button { state.chapterIndex += 1 } label: { Image(systemName: "chevron.right") }
            .disabled(state.chapterIndex >= book.chapters.count - 1)
    }
}

struct PDFReader: UIViewRepresentable {
    let document: PDFDocument
    let annotations: DrawingStore
    let annotating: Bool
    let state: ReaderState

    func makeCoordinator() -> Coordinator {
        Coordinator(annotations: annotations, state: state)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        // must be set before the document
        view.pageOverlayViewProvider = context.coordinator
        view.document = document
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.setAnnotating(annotating)
        if let jump = state.jump, jump.id != coordinator.lastJump, let page = document.page(at: jump.page) {
            coordinator.lastJump = jump.id
            // a fresh PDFView needs a layout pass before it can scroll
            let delay = view.window == nil ? 0.3 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { view.go(to: page) }
        }
    }

    /// One PencilKit canvas per page, laid over the page by PDFKit.
    final class Coordinator: NSObject, PDFPageOverlayViewProvider {
        let annotations: DrawingStore
        let state: ReaderState
        var lastJump: UUID?
        private weak var view: PDFView?
        private var annotating = false
        // kept for the reader's lifetime so undo targets stay alive
        private var inks: [PDFPage: InkController] = [:]

        init(annotations: DrawingStore, state: ReaderState) {
            self.annotations = annotations
            self.state = state
        }

        func attach(_ view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        }

        @objc private func pageChanged() {
            guard let view, let page = view.currentPage, let doc = view.document else { return }
            state.pageIndex = doc.index(for: page)
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            let ink = inks[page] ?? makeInk(for: page)
            ink.canvas.isUserInteractionEnabled = annotating
            return ink.canvas
        }

        private func makeInk(for page: PDFPage) -> InkController {
            let key = String(page.document?.index(for: page) ?? 0)
            let ink = InkController()
            // fingers keep scrolling the PDF
            ink.fingerAllowed = false
            ink.canvas.isScrollEnabled = false
            ink.load(annotations.drawing(key))
            ink.onChange = { [weak self] drawing in self?.annotations.set(drawing, for: key) }
            inks[page] = ink
            return ink
        }

        func setAnnotating(_ on: Bool) {
            guard on != annotating else { return }
            annotating = on
            view?.isInMarkupMode = on
            for ink in inks.values { ink.canvas.isUserInteractionEnabled = on }
            if on, let page = view?.currentPage {
                inks[page]?.activate()
            } else {
                for ink in inks.values { ink.canvas.resignFirstResponder() }
            }
        }
    }
}

struct EPUBReader: UIViewRepresentable {
    let book: EPUBBook
    let state: ReaderState

    private static let readableStyle = """
        var style = document.createElement('style');
        style.textContent = 'body{max-width:42em;margin:0 auto!important;padding:24px 28px!important;line-height:1.55}img,svg{max-width:100%;height:auto}';
        document.head.appendChild(style);
        var meta = document.createElement('meta');
        meta.name = 'viewport';
        meta.content = 'width=device-width,initial-scale=1';
        document.head.appendChild(meta);
        """

    func makeCoordinator() -> Coordinator {
        Coordinator(book: book, state: state)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: Self.readableStyle, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let index = state.chapterIndex
        guard index != context.coordinator.loaded, book.chapters.indices.contains(index) else { return }
        context.coordinator.loaded = index
        web.loadFileURL(book.chapters[index].url, allowingReadAccessTo: book.root)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let book: EPUBBook
        let state: ReaderState
        var loaded = -1

        init(book: EPUBBook, state: ReaderState) {
            self.book = book
            self.state = state
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // in-book links can open another chapter file; keep the index in sync
            guard let path = webView.url?.standardizedFileURL.path,
                  let i = book.chapters.firstIndex(where: { $0.url.path == path }),
                  i != loaded else { return }
            loaded = i
            state.chapterIndex = i
        }
    }
}

extension PDFDocument {
    /// Outline entries two levels deep, in page order.
    var chapters: [(title: String, page: Int)] {
        var result: [(title: String, page: Int)] = []
        func walk(_ outline: PDFOutline, depth: Int) {
            for i in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: i) else { continue }
                if let label = child.label, let page = child.destination?.page {
                    result.append((title: label, page: index(for: page)))
                }
                if depth < 1 { walk(child, depth: depth + 1) }
            }
        }
        if let root = outlineRoot { walk(root, depth: 0) }
        return result.sorted { $0.page < $1.page }
    }

    /// Writes a copy with each page's ink drawn on top.
    func flattened(with annotations: DrawingStore, to url: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        try renderer.writePDF(to: url) { ctx in
            for i in 0..<self.pageCount {
                guard let page = self.page(at: i) else { continue }
                let rect = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
                ctx.beginPage(withBounds: rect, pageInfo: [:])
                let cg = ctx.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: rect.height)
                cg.scaleBy(x: 1, y: -1)
                page.draw(with: .cropBox, to: cg)
                cg.restoreGState()
                let drawing = annotations.drawing(String(i))
                guard !drawing.strokes.isEmpty else { continue }
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    drawing.image(from: rect, scale: 3).draw(in: rect)
                }
            }
        }
    }
}
