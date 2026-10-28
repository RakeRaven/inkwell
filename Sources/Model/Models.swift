import CoreGraphics
import Foundation

/// Notebook page size in points (A4-ish).
let notebookPageSize = CGSize(width: 820, height: 1160)

enum ItemKind: String, Codable {
    case notebook, pdf, epub
}

struct LibraryItem: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: ItemKind
    var title: String
    var created: Date
    var modified: Date
    /// Imported file inside the item's folder (PDF/EPUB only).
    var fileName: String?
    /// Document this notebook was created beside.
    var companion: UUID?
}

enum PaperStyle: String, Codable, CaseIterable {
    case blank, lined, grid, dotted
}

enum LinkTarget: Codable, Hashable {
    case pdfPage(doc: UUID, page: Int)
    case epubChapter(doc: UUID, href: String)

    var docID: UUID {
        switch self {
        case .pdfPage(let doc, _), .epubChapter(let doc, _): doc
        }
    }
}

struct NoteLink: Codable, Identifiable, Equatable {
    var id = UUID()
    var target: LinkTarget
    var label: String
    var position: CGPoint
}

struct TextBox: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var origin: CGPoint
    var fontSize: CGFloat = 28
    /// Set for calculated results: the point just right of the "=" they answer.
    var anchor: CGPoint?
}

struct NotePage: Codable, Identifiable, Equatable {
    var id = UUID()
    var links: [NoteLink] = []
    var textBoxes: [TextBox] = []
}

struct Notebook: Codable {
    var paper: PaperStyle = .lined
    var pages: [NotePage] = [NotePage()]
}
