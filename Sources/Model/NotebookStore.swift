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
