import Foundation
import Observation
import PencilKit

/// An open notebook: page metadata in notebook.json, ink in pages/<page id>.drawing.
@Observable
final class NotebookStore {
    let item: LibraryItem
    private(set) var notebook: Notebook
    let drawings: DrawingStore
    private let url: URL
    @ObservationIgnored private var pendingSave: DispatchWorkItem?

    init(item: LibraryItem, library: Library) {
        let folder = library.folder(for: item)
        let file = folder.appending(path: "notebook.json")
        self.item = item
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

    func setPaper(_ paper: PaperStyle) {
        notebook.paper = paper
        scheduleSave()
    }

    func addPage(after index: Int) -> Int {
        let at = min(index + 1, notebook.pages.count)
        notebook.pages.insert(NotePage(), at: at)
        scheduleSave()
        return at
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
