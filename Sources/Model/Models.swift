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
    /// Notebooks only; without one the library shows the first page.
    var cover: Cover?
}

struct Cover: Codable, Hashable {
    var color: String
    var pattern: CoverPattern = .plain
    /// Photo stored as cover-<id>.jpg in the item's folder.
    var photo: UUID?

    static let colors = ["2F5D8A", "1F3B4D", "6B2E3E", "B5523B", "D9A441", "5E8C61", "2E6E6A", "6C5B9E", "C46A8E", "8A8D91", "2B2B2E", "E8DCC8"]
}

enum CoverPattern: String, Codable, CaseIterable, Identifiable {
    case plain, spine, stripes, dots, grid
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank, lined, narrow, wide, margin, doubleLine, handwriting, grid, smallGrid, dotted, cornell, music
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "Blank"
        case .lined: "Ruled"
        case .narrow: "Narrow Ruled"
        case .wide: "Wide Ruled"
        case .margin: "Ruled + Margin"
        case .doubleLine: "Double Line"
        case .handwriting: "Handwriting"
        case .grid: "Grid"
        case .smallGrid: "Fine Grid"
        case .dotted: "Dotted"
        case .cornell: "Cornell"
        case .music: "Music"
        }
    }
}

enum PaperColor: String, Codable, CaseIterable, Identifiable {
    case white, cream, yellow, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
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
    /// Overrides the notebook's paper for this page.
    var paper: PaperStyle?
    var paperColor: PaperColor?
}

struct Notebook: Codable {
    var paper: PaperStyle = .lined
    var paperColor: PaperColor?
    var pages: [NotePage] = [NotePage()]

    func style(of page: NotePage) -> PaperStyle { page.paper ?? paper }
    func color(of page: NotePage) -> PaperColor { page.paperColor ?? paperColor ?? .white }
}

/// Where an item was left, restored the next time it opens.
struct WorkspaceState: Codable {
    var notesOpen = false
    var annotating = false
    var split = 0.5
    var readerPage = 0
    var chapter = 0
    var notePage = 0
    /// Document open beside a notebook.
    var document: UUID?
}
