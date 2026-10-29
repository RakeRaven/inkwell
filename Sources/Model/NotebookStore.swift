import Foundation
import Observation
import PDFKit
import PencilKit
import UIKit

/// An open notebook: page metadata in notebook.json, ink in pages/<page id>.drawing,
/// pictures in media/ and inserted PDFs in attachments/.
@Observable
final class NotebookStore {
    let item: LibraryItem
    private(set) var notebook: Notebook
    let drawings: DrawingStore
    private let folder: URL
    private let url: URL
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var images: [String: UIImage] = [:]
    @ObservationIgnored private var pdfs: [String: PDFDocument] = [:]
    @ObservationIgnored private var pendingIndex: [UUID: DispatchWorkItem] = [:]
    /// Pages whose handwriting is being read right now.
    private(set) var reading: Set<UUID> = []

    init(item: LibraryItem, library: Library) {
        let folder = library.folder(for: item)
        let file = folder.appending(path: "notebook.json")
        self.item = item
        self.folder = folder
        url = file
        drawings = DrawingStore(dir: folder.appending(path: "pages"))
        if let loaded = Self.read(file) {
            notebook = loaded
        } else {
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.moveItem(at: file, to: folder.appending(path: "notebook-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            }
            notebook = Notebook()
        }
    }

    static func read(_ url: URL) -> Notebook? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Notebook.self, from: data)
    }

    func drawing(for page: UUID) -> PKDrawing {
        drawings.drawing(page.uuidString)
    }

    func setDrawing(_ drawing: PKDrawing, for page: UUID) {
        drawings.set(drawing, for: page.uuidString)
        // read the handwriting again once writing pauses
        pendingIndex[page]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readInk(of: page) }
        pendingIndex[page] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // Search

    /// Reads a page's handwriting into its search index, unless it's already current.
    func readInk(of pageID: UUID, completion: @escaping () -> Void = {}) {
        guard let page = notebook.pages.first(where: { $0.id == pageID }), !reading.contains(pageID) else { return completion() }
        let drawing = drawing(for: pageID)
        let count = drawing.strokes.count
        guard page.inkIndex?.strokes != count else { return completion() }
        guard count > 0 else {
            update(pageID) { $0.inkIndex = InkIndex(lines: [], strokes: 0) }
            return completion()
        }
        let size = notebook.size(of: page)
        var image = UIImage()
        // dark ink on white reads best, whatever the paper
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let ink = drawing.image(from: CGRect(origin: .zero, size: size), scale: 1.5)
            image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                ink.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        reading.insert(pageID)
        HandwritingRecognizer.lines(in: image) { [weak self] found in
            guard let self else { return }
            self.reading.remove(pageID)
            let lines = found.map { text, box in
                InkLine(text: text, rect: CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                                 width: box.width * size.width, height: box.height * size.height))
            }
            self.update(pageID) { $0.inkIndex = InkIndex(lines: lines, strokes: count) }
            completion()
        }
    }

    /// Reads every page that has changed since it was last read, one after another.
    func readAllInk(completion: @escaping () -> Void = {}) {
        let stale = notebook.pages.filter { $0.inkIndex?.strokes != drawing(for: $0.id).strokes.count }.map(\.id)
        func next(_ i: Int) {
            guard i < stale.count else { return completion() }
            readInk(of: stale[i]) { next(i + 1) }
        }
        next(0)
    }

    // Voice notes

    /// Moves a recording into the notebook and returns its file name.
    func saveAudio(from source: URL) -> String? {
        let dir = folder.appending(path: "media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = "\(UUID().uuidString).m4a"
        do {
            try FileManager.default.moveItem(at: source, to: dir.appending(path: file))
        } catch {
            return nil
        }
        return file
    }

    func audioURL(_ file: String) -> URL {
        folder.appending(path: "media/\(file)")
    }

    func update(_ pageID: UUID, _ change: (inout NotePage) -> Void) {
        guard let i = notebook.pages.firstIndex(where: { $0.id == pageID }) else { return }
        change(&notebook.pages[i])
        scheduleSave()
    }

    /// Sets one page's paper, or every page's when `page` is nil.
    func setPaper(_ style: PaperStyle, color: PaperColor, page: UUID?) {
        if let page {
            update(page) {
                $0.paper = style
                $0.paperColor = color
            }
            return
        }
        notebook.paper = style
        notebook.paperColor = color
        for i in notebook.pages.indices {
            notebook.pages[i].paper = nil
            notebook.pages[i].paperColor = nil
        }
        scheduleSave()
    }

    /// Resizes one page, or every page without a PDF behind it when `page` is nil.
    func setSize(_ size: CGSize, page: UUID?) {
        if let page {
            update(page) { if $0.background == nil { $0.size = size } }
            return
        }
        notebook.size = size
        for i in notebook.pages.indices where notebook.pages[i].background == nil {
            notebook.pages[i].size = nil
        }
        scheduleSave()
    }

    /// New pages take the paper and size of the page they follow.
    func addPage(after index: Int) -> Int {
        let at = min(index + 1, notebook.pages.count)
        notebook.pages.insert(blankPage(like: notebook.pages.indices.contains(index) ? notebook.pages[index] : nil), at: at)
        scheduleSave()
        return at
    }

    private func blankPage(like page: NotePage?) -> NotePage {
        var blank = NotePage()
        guard let page else { return blank }
        blank.paper = page.paper
        blank.paperColor = page.paperColor
        blank.size = page.size
        return blank
    }

    /// Returns the page index to show next. A notebook always keeps at least one page.
    func deletePage(at index: Int) -> Int {
        guard notebook.pages.indices.contains(index) else { return 0 }
        let page = notebook.pages.remove(at: index)
        drawings.remove(page.id.uuidString)
        if notebook.pages.isEmpty { notebook.pages = [NotePage()] }
        scheduleSave()
        return min(index, notebook.pages.count - 1)
    }

    // PDF pages

    /// Copies the PDF in and adds a page per PDF page after `index`, each followed by
    /// a blank page when interleaving. Returns the first new page's index.
    func insertPDF(from source: URL, after index: Int, interleave: Bool) throws -> Int {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let dir = folder.appending(path: "attachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = "\(UUID().uuidString).pdf"
        let dest = dir.appending(path: file)
        try FileManager.default.copyItem(at: source, to: dest)
        guard let document = PDFDocument(url: dest), document.pageCount > 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw LibraryError.unreadable(source.lastPathComponent)
        }
        pdfs[file] = document

        let template = notebook.pages.indices.contains(index) ? notebook.pages[index] : nil
        var added: [NotePage] = []
        for i in 0..<document.pageCount {
            guard let pdfPage = document.page(at: i) else { continue }
            let box = pdfPage.bounds(for: .cropBox)
            var page = NotePage()
            // match the PDF page's shape at the usual page width
            let size = CGSize(width: 820, height: (820 * box.height / max(box.width, 1)).rounded())
            page.size = size
            page.background = PageBackground(file: file, page: i)
            added.append(page)
            if interleave {
                var blank = blankPage(like: template)
                blank.size = size
                added.append(blank)
            }
        }
        let at = min(index + 1, notebook.pages.count)
        notebook.pages.insert(contentsOf: added, at: at)
        scheduleSave()
        return at
    }

    func pdfPage(for background: PageBackground) -> PDFPage? {
        if pdfs[background.file] == nil {
            pdfs[background.file] = PDFDocument(url: folder.appending(path: "attachments/\(background.file)"))
        }
        return pdfs[background.file]?.page(at: background.page)
    }

    // Images

    /// Saves a picture for the notebook and returns its file name.
    func saveImage(_ image: UIImage) -> String? {
        let dir = folder.appending(path: "media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scaled = image.downscaled(maxSide: 2000)
        guard let data = scaled.jpegData(compressionQuality: 0.88) else { return nil }
        let file = "\(UUID().uuidString).jpg"
        do {
            try data.write(to: dir.appending(path: file), options: .atomic)
        } catch {
            return nil
        }
        images[file] = scaled
        return file
    }

    func image(_ file: String) -> UIImage? {
        if let cached = images[file] { return cached }
        let image = UIImage(contentsOfFile: folder.appending(path: "media/\(file)").path)
        images[file] = image
        return image
    }

    func flush() {
        pendingSave?.cancel()
        drawings.flush()
        save()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save() {
        do {
            try JSONEncoder().encode(notebook).write(to: url, options: .atomic)
        } catch {
            print("Saving notebook failed: \(error)")
        }
    }
}
