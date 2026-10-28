import Foundation
import ZIPFoundation

enum EPUBError: LocalizedError {
    case invalid
    var errorDescription: String? { "The EPUB's structure couldn't be read." }
}

struct EPUBChapter: Hashable {
    let href: String
    let title: String
    let url: URL
}

/// An unpacked EPUB: reading order from the OPF spine, titles from the nav doc or NCX.
struct EPUBBook {
    let root: URL
    let chapters: [EPUBChapter]

    static func open(_ file: URL, unpackTo dir: URL) throws -> EPUBBook {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let root: URL
        if fm.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
            root = file
        } else {
            if !fm.fileExists(atPath: dir.appending(path: "META-INF/container.xml").path) {
                // unpack beside, then move, so a failed unzip never looks complete
                let tmp = dir.deletingLastPathComponent().appending(path: "unpacking")
                try? fm.removeItem(at: tmp)
                try? fm.removeItem(at: dir)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                try fm.unzipItem(at: file, to: tmp)
                try fm.moveItem(at: tmp, to: dir)
            }
            root = dir
        }

        let container = try XMLNodes(url: root.appending(path: "META-INF/container.xml"))
        guard let opfPath = container.first("rootfile")?["full-path"] else { throw EPUBError.invalid }
        let opfURL = root.appending(path: opfPath)
        let opf = try XMLNodes(url: opfURL)
        let base = opfURL.deletingLastPathComponent()

        var manifest: [String: (href: String, type: String, properties: String)] = [:]
        for item in opf.all("item") {
            if let id = item["id"], let href = item["href"] {
                manifest[id] = (href, item["media-type"] ?? "", item["properties"] ?? "")
            }
        }

        let titles = tocTitles(manifest: Array(manifest.values), base: base)
        var chapters: [EPUBChapter] = []
        for ref in opf.all("itemref") where ref["linear"] != "no" {
            guard let id = ref["idref"], let entry = manifest[id], let url = resolve(entry.href, base) else { continue }
            chapters.append(EPUBChapter(href: entry.href, title: titles[url.path] ?? "Section \(chapters.count + 1)", url: url))
        }
        guard !chapters.isEmpty else { throw EPUBError.invalid }
        return EPUBBook(root: root, chapters: chapters)
    }

    /// File URL for an href relative to base, without its #fragment.
    private static func resolve(_ href: String, _ base: URL) -> URL? {
        let url = URL(string: href, relativeTo: base)
            ?? href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: $0, relativeTo: base) }
        return url.map { URL(fileURLWithPath: $0.standardizedFileURL.path) }
    }

    private static func tocTitles(manifest: [(href: String, type: String, properties: String)], base: URL) -> [String: String] {
        var titles: [String: String] = [:]

        if let nav = manifest.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let navURL = resolve(nav.href, base),
           let doc = try? XMLNodes(url: navURL) {
            let navBase = navURL.deletingLastPathComponent()
            for a in doc.all("a") {
                let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let href = a["href"], let url = resolve(href, navBase), titles[url.path] == nil, !text.isEmpty {
                    titles[url.path] = text
                }
            }
        }

        if titles.isEmpty,
           let ncx = manifest.first(where: { $0.type == "application/x-dtbncx+xml" }),
           let ncxURL = resolve(ncx.href, base),
           let doc = try? XMLNodes(url: ncxURL) {
            let ncxBase = ncxURL.deletingLastPathComponent()
            var pending: String?
            for node in doc.nodes {
                if node.name == "text" {
                    pending = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if node.name == "content", let src = node["src"], let title = pending,
                          let url = resolve(src, ncxBase), titles[url.path] == nil {
                    titles[url.path] = title
                }
            }
        }
        return titles
    }
}

struct XNode {
    let name: String
    let attributes: [String: String]
    var text: String
    subscript(key: String) -> String? { attributes[key] }
}

/// Flat list of elements in end-tag order, each with its full inner text.
final class XMLNodes: NSObject, XMLParserDelegate {
    private(set) var nodes: [XNode] = []
    private var stack: [XNode] = []

    init(url: URL) throws {
        super.init()
        var data = try Data(contentsOf: url)
        // XHTML entities that plain XML doesn't define
        if var text = String(data: data, encoding: .utf8), text.contains("&nbsp;") {
            text = text.replacingOccurrences(of: "&nbsp;", with: "&#160;")
            data = Data(text.utf8)
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? EPUBError.invalid }
    }

    func all(_ name: String) -> [XNode] { nodes.filter { $0.name == name } }
    func first(_ name: String) -> XNode? { nodes.first { $0.name == name } }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append(XNode(name: elementName, attributes: attributeDict, text: ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for i in stack.indices { stack[i].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let node = stack.popLast() { nodes.append(node) }
    }
}
