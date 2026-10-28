import SwiftUI

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// A document, a notebook, or both side by side with links between them.
struct WorkspaceView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    let item: LibraryItem

    @State private var reader: ReaderModel?
    @State private var notes: NotebookStore?
    @State private var annotating = false
    @State private var notePage = 0
    @State private var split: CGFloat = 0.5
    @State private var exportFile: ExportFile?
    @State private var message: String?

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if let reader {
                    ReaderPane(model: reader, annotating: annotating, backlinks: backlinks, onBacklink: { notePage = $0 })
                        .id(reader.item.id)
                        .frame(width: notes == nil ? geo.size.width : max(geo.size.width * split - 7, 0))
                }
                if reader != nil, notes != nil {
                    SplitHandle()
                        .gesture(DragGesture(coordinateSpace: .named("workspace")).onChanged { value in
                            split = min(max(value.location.x / geo.size.width, 0.25), 0.75)
                        })
                }
                if let notes {
                    NotebookPane(store: notes, pageIndex: $notePage, linkOptions: linkOptions, onOpenLink: open)
                }
            }
            .coordinateSpace(.named("workspace"))
        }
        .navigationTitle(reader?.item.title ?? notes?.item.title ?? item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { documentMenu }
        }
        .onAppear(perform: load)
        .onDisappear(perform: close)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flush() }
        }
        .sheet(item: $exportFile) { ShareSheet(url: $0.url) }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }

    private var documentMenu: some View {
        Menu {
            if let reader {
                if reader.pdf != nil {
                    Toggle(isOn: $annotating) { Label("Annotate PDF", systemImage: "pencil.tip.crop.circle") }
                    Button { export(reader) } label: { Label("Export Annotated PDF", systemImage: "square.and.arrow.up") }
                }
                if item.kind == .notebook {
                    Button { closeReader() } label: { Label("Close \(reader.item.title)", systemImage: "xmark") }
                } else {
                    Toggle(isOn: Binding(get: { notes != nil }, set: { $0 ? openSideNotes(for: reader.item) : closeNotes() })) {
                        Label("Notes on the Side", systemImage: "rectangle.split.2x1")
                    }
                }
            }
            if notes != nil {
                Menu {
                    ForEach(library.items.filter { $0.kind != .notebook }) { doc in
                        Button(doc.title) { openDocument(doc.id) }
                    }
                } label: {
                    Label("Open Beside Notes", systemImage: "doc.on.doc")
                }
            }
        } label: {
            Image(systemName: "pencil.and.outline")
        }
    }

    private var linkOptions: [LinkOption] {
        guard let reader, notes != nil else { return [] }
        let doc = reader.item
        let short = String(doc.title.prefix(18))
        let state = reader.state
        if reader.pdf != nil {
            let page = state.pageIndex
            var options = [LinkOption(title: "Link to Page \(page + 1)", target: .pdfPage(doc: doc.id, page: page), label: "\(short) · p. \(page + 1)")]
            if let chapter = reader.chapters.last(where: { $0.page <= page }) {
                options.append(LinkOption(title: "Link to Chapter: \(chapter.title)", target: .pdfPage(doc: doc.id, page: chapter.page), label: "\(short) · \(chapter.title.prefix(24))"))
            }
            return options
        }
        if let book = reader.epub, book.chapters.indices.contains(state.chapterIndex) {
            let chapter = book.chapters[state.chapterIndex]
            return [LinkOption(title: "Link to Chapter: \(chapter.title)", target: .epubChapter(doc: doc.id, href: chapter.href), label: "\(short) · \(chapter.title.prefix(24))")]
        }
        return []
    }

    /// Note pages linking to where the reader is now.
    private var backlinks: [Backlink] {
        guard let reader, let notes, let here = currentTarget(reader) else { return [] }
        var result: [Backlink] = []
        for (index, page) in notes.notebook.pages.enumerated() {
            for link in page.links where link.target == here {
                result.append(Backlink(id: link.id, notePage: index))
            }
        }
        return result
    }

    private func currentTarget(_ reader: ReaderModel) -> LinkTarget? {
        let state = reader.state
        if reader.pdf != nil {
            return .pdfPage(doc: reader.item.id, page: state.pageIndex)
        }
        if let book = reader.epub, book.chapters.indices.contains(state.chapterIndex) {
            return .epubChapter(doc: reader.item.id, href: book.chapters[state.chapterIndex].href)
        }
        return nil
    }

    private func load() {
        guard reader == nil, notes == nil else { return }
        if item.kind == .notebook {
            notes = NotebookStore(item: item, library: library)
        } else {
            reader = ReaderModel(item: item, library: library)
        }
    }

    private func flush() {
        notes?.flush()
        reader?.annotations.flush()
    }

    private func close() {
        flush()
        if let notes { library.touch(notes.item.id) }
        if let reader { library.touch(reader.item.id) }
    }

    private func openSideNotes(for doc: LibraryItem) {
        let notebook = library.items.first { $0.kind == .notebook && $0.companion == doc.id }
            ?? library.createNotebook(title: "\(doc.title) Notes", companion: doc.id)
        notePage = 0
        notes = NotebookStore(item: notebook, library: library)
    }

    private func closeNotes() {
        notes?.flush()
        notes = nil
    }

    private func closeReader() {
        reader?.annotations.flush()
        reader = nil
        annotating = false
    }

    @discardableResult
    private func openDocument(_ id: UUID) -> ReaderModel? {
        guard let doc = library.item(id) else {
            message = "That document is no longer in your library."
            return nil
        }
        if reader?.item.id != id {
            closeReader()
            reader = ReaderModel(item: doc, library: library)
        }
        return reader
    }

    private func open(_ link: NoteLink) {
        guard let reader = openDocument(link.target.docID) else { return }
        switch link.target {
        case .pdfPage(_, let page):
            reader.state.jump = PageJump(page: page)
        case .epubChapter(_, let href):
            if let i = reader.epub?.chapters.firstIndex(where: { $0.href == href }) {
                reader.state.chapterIndex = i
            }
        }
    }

    private func export(_ reader: ReaderModel) {
        guard let pdf = reader.pdf else { return }
        let name = reader.item.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name) (annotated).pdf")
        do {
            try pdf.flattened(with: reader.annotations, to: url)
            exportFile = ExportFile(url: url)
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}

private struct SplitHandle: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 1)
            .overlay {
                Capsule()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 6, height: 44)
            }
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
