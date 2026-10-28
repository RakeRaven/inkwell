import CoreGraphics
import Foundation

/// Default notebook page size in points (A4 portrait).
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
    /// Photo framing: zoom of at least 1, offsets as fractions of the cover size.
    var zoom: Double?
    var offsetX: Double?
    var offsetY: Double?
    /// Spine or stripes drawn over the photo too.
    var patternOverPhoto: Bool?
    /// Older covers only; `titleX`/`titleY` replace it.
    var titlePosition: CoverTitlePosition?
    var titleMode: CoverTitleMode?
    /// Title centre as fractions of the cover size.
    var titleX: Double?
    var titleY: Double?
    var titleStyle: CoverTitleStyle?
    var titleFont: CoverTitleFont?
    /// Handwriting stored as cover-ink-<id>.drawing, drawn on a `canvasSize` cover.
    var ink: UUID?

    static let canvasSize = CGSize(width: 300, height: 416)
    static let colors = ["2F5D8A", "1F3B4D", "6B2E3E", "B5523B", "D9A441", "5E8C61", "2E6E6A", "6C5B9E", "C46A8E", "8A8D91", "2B2B2E", "E8DCC8"]
    /// Snap targets for the title: three columns, three rows.
    static let titleColumns: [Double] = [0.2, 0.5, 0.8]
    static let titleRows: [Double] = [0.14, 0.5, 0.86]

    var mode: CoverTitleMode {
        titleMode ?? (titlePosition == .hidden ? .none : .typed)
    }

    var titleCenter: CGPoint {
        if let titleX, let titleY { return CGPoint(x: titleX, y: titleY) }
        switch titlePosition ?? .top {
        case .middle: return CGPoint(x: 0.5, y: 0.5)
        case .bottom: return CGPoint(x: 0.5, y: 0.86)
        default: return CGPoint(x: 0.5, y: 0.14)
        }
    }
}

enum CoverPattern: String, Codable, CaseIterable, Identifiable {
    case plain, spine, stripes, dots, grid
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CoverTitlePosition: String, Codable {
    case top, middle, bottom, hidden
}

enum CoverTitleMode: String, Codable, CaseIterable, Identifiable {
    case typed, handwritten, none
    var id: String { rawValue }

    var title: String {
        switch self {
        case .typed: "Typed"
        case .handwritten: "Handwritten"
        case .none: "None"
        }
    }
}

enum CoverTitleStyle: String, Codable, CaseIterable, Identifiable {
    case label, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CoverTitleFont: String, Codable, CaseIterable, Identifiable {
    case system, serif, rounded, hand
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Sans"
        case .serif: "Serif"
        case .rounded: "Rounded"
        case .hand: "Hand"
        }
    }
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

/// Page size presets; pages store the plain CGSize.
enum PageSize: String, CaseIterable, Identifiable {
    case a4, letter, legal, square, wide, standard
    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: "A4"
        case .letter: "Letter"
        case .legal: "Legal"
        case .square: "Square"
        case .wide: "16:9"
        case .standard: "4:3"
        }
    }

    var portrait: CGSize {
        switch self {
        case .a4: notebookPageSize
        case .letter: CGSize(width: 820, height: 1061)
        case .legal: CGSize(width: 820, height: 1351)
        case .square: CGSize(width: 900, height: 900)
        case .wide: CGSize(width: 820, height: 1458)
        case .standard: CGSize(width: 820, height: 1093)
        }
    }

    func size(landscape: Bool) -> CGSize {
        landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
    }

    /// The preset and orientation a stored size came from, if any.
    static func match(_ size: CGSize) -> (size: PageSize, landscape: Bool)? {
        for preset in allCases {
            if preset.portrait == size { return (preset, false) }
            if preset.size(landscape: true) == size { return (preset, true) }
        }
        return nil
    }
}

enum LinkTarget: Codable, Hashable {
    case pdfPage(doc: UUID, page: Int)
    case epubChapter(doc: UUID, href: String)
    case web(url: String)

    var docID: UUID? {
        switch self {
        case .pdfPage(let doc, _), .epubChapter(let doc, _): doc
        case .web: nil
        }
    }
}

struct NoteLink: Codable, Identifiable, Equatable {
    var id = UUID()
    var target: LinkTarget
    var label: String
    var position: CGPoint
    /// Set for links laid over handwriting or text; chips have none.
    var area: CGRect?
}

struct TextBox: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Markdown for typed text, plain digits for math results.
    var text: String
    var origin: CGPoint
    var fontSize: CGFloat = 28
    /// Set for calculated results: the point just right of the "=" they answer.
    var anchor: CGPoint?
}

struct ImageBox: Codable, Identifiable, Equatable {
    var id = UUID()
    /// File in the notebook's media folder.
    var file: String
    var frame: CGRect
}

/// A page of an inserted PDF shown as the paper.
struct PageBackground: Codable, Equatable {
    /// File in the notebook's attachments folder.
    var file: String
    var page: Int
}

struct NotePage: Codable, Identifiable, Equatable {
    var id = UUID()
    var links: [NoteLink] = []
    var textBoxes: [TextBox] = []
    var images: [ImageBox] = []
    /// Overrides the notebook's paper for this page.
    var paper: PaperStyle?
    var paperColor: PaperColor?
    var size: CGSize?
    var background: PageBackground?
}

extension NotePage {
    // older notebooks lack the newer keys
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        links = try c.decodeIfPresent([NoteLink].self, forKey: .links) ?? []
        textBoxes = try c.decodeIfPresent([TextBox].self, forKey: .textBoxes) ?? []
        images = try c.decodeIfPresent([ImageBox].self, forKey: .images) ?? []
        paper = try c.decodeIfPresent(PaperStyle.self, forKey: .paper)
        paperColor = try c.decodeIfPresent(PaperColor.self, forKey: .paperColor)
        size = try c.decodeIfPresent(CGSize.self, forKey: .size)
        background = try c.decodeIfPresent(PageBackground.self, forKey: .background)
    }
}

struct Notebook: Codable {
    var paper: PaperStyle = .lined
    var paperColor: PaperColor?
    var size: CGSize?
    var pages: [NotePage] = [NotePage()]

    func style(of page: NotePage) -> PaperStyle { page.paper ?? paper }
    func color(of page: NotePage) -> PaperColor { page.paperColor ?? paperColor ?? .white }
    func size(of page: NotePage) -> CGSize { page.size ?? size ?? notebookPageSize }
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
