import Foundation
import Observation
import PDFKit
import PencilKit
import UIKit

enum LibraryError: LocalizedError {
    case unsupported(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): "\(name) isn't a PDF or EPUB."
        case .unreadable(let name): "\(name) couldn't be opened."
        }
    }
}

/// Every notebook, PDF and EPUB, each stored in Documents/Items/<id>/.
@Observable
final class Library {
    private(set) var items: [LibraryItem] = []
    private let root = URL.documentsDirectory

    init() {
        load()
    }

    private var indexURL: URL { root.appending(path: "library.json") }

    func folder(for item: LibraryItem) -> URL {
        root.appending(path: "Items/\(item.id.uuidString)", directoryHint: .isDirectory)
    }

    func sourceURL(for item: LibraryItem) -> URL? {
        item.fileName.map { folder(for: item).appending(path: $0) }
    }

    func item(_ id: UUID) -> LibraryItem? {
        items.first { $0.id == id }
    }

    func createNotebook(title: String, companion: UUID? = nil, cover: Cover? = nil, paper: PaperStyle = .lined, paperColor: PaperColor = .white) -> LibraryItem {
        let item = LibraryItem(id: UUID(), kind: .notebook, title: title, created: .now, modified: .now, companion: companion, cover: cover)
        let dir = folder(for: item)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notebook = Notebook(paper: paper, paperColor: paperColor)
        try? JSONEncoder().encode(notebook).write(to: dir.appending(path: "notebook.json"), options: .atomic)
        items.insert(item, at: 0)
        save()
        return item
    }

    @discardableResult
    func importFile(at url: URL) throws -> LibraryItem {
        let ext = url.pathExtension.lowercased()
        let kind: ItemKind
        switch ext {
        case "pdf": kind = .pdf
        case "epub": kind = .epub
        default: throw LibraryError.unsupported(url.lastPathComponent)
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let fileName = "source.\(ext)"
        let item = LibraryItem(id: UUID(), kind: kind, title: url.deletingPathExtension().lastPathComponent, created: .now, modified: .now, fileName: fileName)
        let dir = folder(for: item)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appending(path: fileName)
            try FileManager.default.copyItem(at: url, to: dest)
            if kind == .pdf, PDFDocument(url: dest) == nil {
                throw LibraryError.unreadable(url.lastPathComponent)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        items.insert(item, at: 0)
        save()
        return item
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        save()
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        try? FileManager.default.removeItem(at: folder(for: item))
        save()
    }

    /// `photo` is a newly picked image; the cover's existing photo is kept otherwise.
    func setCover(_ id: UUID, to cover: Cover?, photo: UIImage? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var cover = cover
        let dir = folder(for: items[i])
        if cover != nil, let photo, let data = photo.downscaled(maxSide: 1400).jpegData(compressionQuality: 0.85) {
            let photoID = UUID()
            if (try? data.write(to: dir.appending(path: "cover-\(photoID.uuidString).jpg"), options: .atomic)) != nil {
                cover?.photo = photoID
            }
        }
        // drop photos the cover no longer uses
        let keep = cover?.photo.map { "cover-\($0.uuidString).jpg" }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for file in files where file.hasPrefix("cover-") && file != keep {
            try? FileManager.default.removeItem(at: dir.appending(path: file))
        }
        items[i].cover = cover
        save()
    }

    func coverPhoto(for item: LibraryItem) -> UIImage? {
        guard let id = item.cover?.photo else { return nil }
        return UIImage(contentsOfFile: folder(for: item).appending(path: "cover-\(id.uuidString).jpg").path)
    }

    func workspaceState(for item: LibraryItem) -> WorkspaceState {
        guard let data = try? Data(contentsOf: folder(for: item).appending(path: "workspace.json")),
              let state = try? JSONDecoder().decode(WorkspaceState.self, from: data) else { return WorkspaceState() }
        return state
    }

    func saveWorkspaceState(_ state: WorkspaceState, for item: LibraryItem) {
        try? JSONEncoder().encode(state).write(to: folder(for: item).appending(path: "workspace.json"), options: .atomic)
    }

    func touch(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].modified = .now
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            items = try JSONDecoder().decode([LibraryItem].self, from: data)
        } catch {
            // keep the unreadable index instead of overwriting it on next save
            let backup = root.appending(path: "library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: backup)
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
        } catch {
            print("Saving library failed: \(error)")
        }
    }
}

extension Library {
    func thumbnail(for item: LibraryItem, size: CGSize) -> UIImage? {
        switch item.kind {
        case .pdf:
            guard let url = sourceURL(for: item) else { return nil }
            return PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: size, for: .cropBox)
        case .notebook:
            let dir = folder(for: item)
            guard let notebook = NotebookStore.read(dir.appending(path: "notebook.json")),
                  let page = notebook.pages.first else { return nil }
            let paper = PaperRenderer.image(notebook.style(of: page), color: notebook.color(of: page), width: size.width)
            var ink: UIImage?
            if let data = try? Data(contentsOf: dir.appending(path: "pages/\(page.id.uuidString).drawing")),
               let drawing = try? PKDrawing(data: data) {
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    ink = drawing.image(from: CGRect(origin: .zero, size: notebookPageSize), scale: size.width / notebookPageSize.width * 2)
                }
            }
            return UIGraphicsImageRenderer(size: size).image { _ in
                let rect = CGRect(origin: .zero, size: size)
                paper.draw(in: rect)
                ink?.draw(in: rect)
            }
        case .epub:
            return nil
        }
    }
}
