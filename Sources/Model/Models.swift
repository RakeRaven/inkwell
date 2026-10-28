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
    var patternColor: String?
    /// Older covers only; `titleX`/`titleY` replace it.
    var titlePosition: CoverTitlePosition?
    var titleMode: CoverTitleMode?
    /// Title centre as fractions of the cover size.
    var titleX: Double?
    var titleY: Double?
    var titleScale: Double?
    /// Radians.
    var titleRotation: Double?
    var titleStyle: CoverTitleStyle?
    var titleFont: CoverTitleFont?
    var stickers: [CoverSticker]?
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

/// Emoji or text, or a picture stored as cover-sticker-<id>.png, placed like a story sticker.
struct CoverSticker: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Nil for picture stickers.
    var emoji: String?
    /// Centre as fractions of the cover size.
    var x = 0.5
    var y = 0.5
    var scale = 1.0
    /// Radians.
    var rotation = 0.0
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
    case a4, a5, a3, a6, b5, letter, legal, executive, tabloid, square, wide, standard, indexCard, phone
    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: "A4"
        case .a5: "A5"
        case .a3: "A3"
        case .a6: "A6"
        case .b5: "B5"
        case .letter: "Letter"
        case .legal: "Legal"
        case .executive: "Executive"
        case .tabloid: "Tabloid"
        case .square: "Square"
        case .wide: "16:9"
        case .standard: "4:3"
        case .indexCard: "Index Card"
        case .phone: "Phone"
        }
    }

    /// Paper sizes keep their real proportions to A4, so smaller paper holds fewer lines.
    var portrait: CGSize {
        switch self {
        case .a4: notebookPageSize
        case .a5: CGSize(width: 579, height: 820)
        case .a3: CGSize(width: 1160, height: 1641)
        case .a6: CGSize(width: 410, height: 579)
        case .b5: CGSize(width: 688, height: 977)
        case .letter: CGSize(width: 820, height: 1061)
        case .legal: CGSize(width: 820, height: 1351)
        case .executive: CGSize(width: 719, height: 1042)
        case .tabloid: CGSize(width: 1091, height: 1687)
        case .square: CGSize(width: 900, height: 900)
        case .wide: CGSize(width: 820, height: 1458)
        case .standard: CGSize(width: 820, height: 1093)
        case .indexCard: CGSize(width: 397, height: 595)
        case .phone: CGSize(width: 600, height: 1300)
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

enum ShapeKind: String, Codable {
    case polygon, polyline, line, ellipse, projectile, graph
}

/// Functions of x plotted over a window.
struct GraphSpec: Codable, Equatable {
    var functions = ["sin(x)"]
    var xMin = -10.0
    var xMax = 10.0
    var yMin = -6.0
    var yMax = 6.0
}

/// Launch settings for a projectile, in metres, seconds and degrees.
struct Projectile: Codable, Equatable {
    var speed = 20.0
    var angle = 45.0
    var gravity = 9.81
    /// Launch height above the ground line.
    var height = 0.0
    /// Page points per metre.
    var scale = 12.0
}

/// An editable vector shape: snapped from ink, or inserted from the menu.
struct ShapeItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ShapeKind
    /// Vertices; a line's two ends; an ellipse's centre; a projectile's launch point; a graph's top-left.
    var points: [CGPoint]
    /// Ellipse radii, or a graph's size.
    var radii: CGSize?
    /// Radians, for ellipses.
    var rotation: Double?
    var color = "1C1C1E"
    var width: CGFloat = 3
    var opacity: Double?
    /// Show side lengths and angles.
    var measures: Bool?
    var projectile: Projectile?
    var graph: GraphSpec?
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
    var shapes: [ShapeItem] = []
    /// Overrides the notebook's paper for this page.
    var paper: PaperStyle?
    var paperColor: PaperColor?
    var size: CGSize?
    var background: PageBackground?
    /// Dog-eared corners; a page with any is bookmarked.
    var folds: [PageCorner]?

    var bookmarked: Bool { !(folds ?? []).isEmpty }
}

enum PageCorner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? rect.minX : rect.maxX, y: isTop ? rect.minY : rect.maxY)
    }
}

extension NotePage {
    // older notebooks lack the newer keys
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        links = try c.decodeIfPresent([NoteLink].self, forKey: .links) ?? []
        textBoxes = try c.decodeIfPresent([TextBox].self, forKey: .textBoxes) ?? []
        images = try c.decodeIfPresent([ImageBox].self, forKey: .images) ?? []
        shapes = try c.decodeIfPresent([ShapeItem].self, forKey: .shapes) ?? []
        paper = try c.decodeIfPresent(PaperStyle.self, forKey: .paper)
        paperColor = try c.decodeIfPresent(PaperColor.self, forKey: .paperColor)
        size = try c.decodeIfPresent(CGSize.self, forKey: .size)
        background = try c.decodeIfPresent(PageBackground.self, forKey: .background)
        folds = try c.decodeIfPresent([PageCorner].self, forKey: .folds)
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
    var readerHidden: Bool?
    var bookMode: Bool?
}
