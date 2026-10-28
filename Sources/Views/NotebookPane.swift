import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LinkOption: Identifiable {
    let title: String
    let target: LinkTarget
    let label: String
    var id: String { title }
}

/// An open notebook plus the canvas state its controls share; the workspace header drives it.
@Observable
final class NotesSession {
    let store: NotebookStore
    let handle = CanvasHandle()
    var mode: CanvasMode = .draw
    var choosingPaper = false
    var allPages = false
    var confirmDelete = false
    var pickingPhoto = false
    var photoItem: PhotosPickerItem?
    var importingPDF = false
    var interleave = false
    /// Box dragged in link mode, waiting for a target.
    var linkArea: CGRect?
    var askingURL = false
    var urlText = "https://"
    var message: String?

    init(store: NotebookStore) {
        self.store = store
    }

    func toggle(_ mode: CanvasMode) {
        self.mode = self.mode == mode ? .draw : mode
    }
}

struct NotebookPane: View {
    @Bindable var session: NotesSession
    @Binding var pageIndex: Int
    let bookMode: Bool
    let linkOptions: [LinkOption]
    let onOpenLink: (NoteLink) -> Void

    private var store: NotebookStore { session.store }
    private var pages: [NotePage] { store.notebook.pages }
    private var index: Int { min(max(pageIndex, 0), pages.count - 1) }

    @ViewBuilder
    private var pageView: some View {
        if bookMode {
            GeometryReader { geo in
                let spread = geo.size.width > geo.size.height * 1.1
                PageCurlPager(count: pages.count, index: $pageIndex, spread: spread, makePage: { _ in
                    let view = NoteCanvasView()
                    view.bookMode = true
                    return view
                }, refresh: { view, i in
                    guard let canvas = view as? NoteCanvasView, pages.indices.contains(i) else { return }
                    canvas.onModeDone = { session.mode = .draw }
                    canvas.bind(store: store, page: pages[i], onOpenLink: onOpenLink, onLinkArea: { session.linkArea = $0 })
                    if i == index {
                        canvas.mode = session.mode
                        session.handle.view = canvas
                    }
                })
                .id(spread)
            }
        } else {
            NoteCanvas(store: store, page: pages[index], mode: $session.mode, handle: session.handle, onOpenLink: onOpenLink,
                       onSwipe: swipe, onLinkArea: { session.linkArea = $0 })
        }
    }

    var body: some View {
        pageView
            .overlay(alignment: .top) {
                if let hint {
                    Text(hint)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                        .padding(.top, 56)
                        .allowsHitTesting(false)
                }
            }
            .confirmationDialog("Delete this page?", isPresented: $session.confirmDelete, titleVisibility: .visible) {
                Button("Delete Page", role: .destructive) { pageIndex = store.deletePage(at: index) }
            }
            .confirmationDialog("Link to", isPresented: Binding(get: { session.linkArea != nil && !session.askingURL }, set: { shown in
                if !shown, !session.askingURL { session.linkArea = nil }
            }), titleVisibility: .visible) {
                ForEach(linkOptions) { option in
                    Button(option.title) {
                        if let area = session.linkArea { session.handle.view?.addAreaLink(option.target, label: option.label, area: area) }
                        session.linkArea = nil
                    }
                }
                Button("Web Link\u{2026}") { session.askingURL = true }
                Button("Cancel", role: .cancel) { session.linkArea = nil }
            }
            .alert("Web Link", isPresented: $session.askingURL) {
                TextField("https://", text: $session.urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Button("Add") { addWebLink() }
                Button("Cancel", role: .cancel) { session.linkArea = nil }
            }
            .photosPicker(isPresented: $session.pickingPhoto, selection: $session.photoItem, matching: .images)
            .onChange(of: session.photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                       let file = store.saveImage(image) {
                        session.handle.view?.addImage(file: file, size: image.size)
                    }
                    session.photoItem = nil
                }
            }
            .fileImporter(isPresented: $session.importingPDF, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    do {
                        pageIndex = try store.insertPDF(from: url, after: index, interleave: session.interleave)
                    } catch {
                        session.message = error.localizedDescription
                    }
                case .failure(let error):
                    session.message = error.localizedDescription
                }
            }
            .alert(session.message ?? "", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
                Button("OK") {}
            }
            .onChange(of: session.allPages) { _, all in
                guard all else { return }
                let page = pages[index]
                store.setPaper(store.notebook.style(of: page), color: store.notebook.color(of: page), page: nil)
            }
    }

    private var hint: String? {
        switch session.mode {
        case .draw: nil
        case .convert: "Drag over handwriting to turn it into text"
        case .link: "Drag over handwriting or text to link it"
        case .arrange: "Drag to move, pinch to resize, tap for options"
        }
    }

    private func swipe(_ delta: Int) -> Bool {
        let next = index + delta
        guard pages.indices.contains(next) else { return false }
        pageIndex = next
        return true
    }

    private func addWebLink() {
        var text = session.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        defer {
            session.linkArea = nil
            session.urlText = "https://"
        }
        guard let area = session.linkArea, let url = URL(string: text), url.host() != nil else { return }
        session.handle.view?.addAreaLink(.web(url: url.absoluteString), label: url.host() ?? text, area: area)
    }
}

/// The notebook's buttons, shown in the workspace's single top bar.
struct NotebookControls: View {
    @Bindable var session: NotesSession
    @Binding var pageIndex: Int
    let linkOptions: [LinkOption]
    let compact: Bool

    private var store: NotebookStore { session.store }
    private var pages: [NotePage] { store.notebook.pages }
    private var index: Int { min(max(pageIndex, 0), pages.count - 1) }
    private var isLastPage: Bool { index == pages.count - 1 }

    var body: some View {
        HStack(spacing: 2) {
            if !linkOptions.isEmpty {
                Menu {
                    ForEach(linkOptions) { option in
                        Button(option.title) { session.handle.view?.addLink(option.target, label: option.label) }
                    }
                } label: {
                    BarIcon("link.badge.plus")
                }
            }
            modeButtons
            Menu {
                Button { session.handle.view?.beginNewText() } label: { Label("Text", systemImage: "textformat") }
                Button { session.pickingPhoto = true } label: { Label("Image", systemImage: "photo") }
                Menu {
                    Button { session.handle.view?.insertShape(.equilateral) } label: { Label("Equilateral Triangle", systemImage: "triangle") }
                    Button { session.handle.view?.insertShape(.rightTriangle) } label: { Label("Right Triangle", systemImage: "righttriangle") }
                    Button { session.handle.view?.insertShape(.square) } label: { Label("Square", systemImage: "square") }
                    Button { session.handle.view?.insertShape(.circle) } label: { Label("Circle", systemImage: "circle") }
                    Button { session.handle.view?.insertShape(.line) } label: { Label("Line", systemImage: "line.diagonal") }
                    Button { session.handle.view?.insertShape(.angle) } label: { Label("Angle", systemImage: "angle") }
                } label: {
                    Label("Geometry", systemImage: "triangle")
                }
                Button { session.handle.view?.insertShape(.projectile) } label: {
                    Label("Projectile (Physics)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                Button {
                    session.interleave = false
                    session.importingPDF = true
                } label: {
                    Label("PDF Pages", systemImage: "doc.richtext")
                }
                Button {
                    session.interleave = true
                    session.importingPDF = true
                } label: {
                    Label("PDF Pages, Interleaved with Paper", systemImage: "doc.on.doc")
                }
            } label: {
                BarIcon("plus.square.on.square")
            }
            paperButton
            Theme.line.frame(width: 1, height: 22).padding(.horizontal, 4)
            Button { pageIndex = index - 1 } label: { BarIcon("chevron.left") }
                .disabled(index == 0)
            Text("\(index + 1)/\(pages.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
                .fixedSize()
            Button {
                pageIndex = isLastPage ? store.addPage(after: index) : index + 1
            } label: {
                BarIcon(isLastPage ? "plus" : "chevron.right")
            }
            Menu {
                Button { pageIndex = store.addPage(after: index) } label: { Label("Insert Page After", systemImage: "plus.square") }
                Button(role: .destructive) { session.confirmDelete = true } label: { Label("Delete Page", systemImage: "trash") }
            } label: {
                BarIcon("ellipsis")
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modeButtons: some View {
        let modes: [(CanvasMode, String, String)] = [
            (.convert, "text.viewfinder", "Handwriting to Text"),
            (.link, "link", "Link Handwriting or Text"),
            (.arrange, "arrow.up.and.down.and.arrow.left.and.right", "Move & Resize"),
        ]
        if compact {
            Menu {
                ForEach(modes, id: \.1) { mode, symbol, title in
                    Button { session.toggle(mode) } label: { Label(title, systemImage: symbol) }
                }
            } label: {
                BarIcon(modes.first { $0.0 == session.mode }?.1 ?? "wand.and.stars", active: session.mode != .draw)
            }
        } else {
            ForEach(modes, id: \.1) { mode, symbol, title in
                Button { session.toggle(mode) } label: { BarIcon(symbol, active: session.mode == mode) }
                    .accessibilityLabel(title)
            }
        }
    }

    /// Shows the current page's paper, opens the picker.
    private var paperButton: some View {
        let page = pages[index]
        let style = store.notebook.style(of: page)
        let color = store.notebook.color(of: page)
        return Button { session.choosingPaper = true } label: {
            HStack(spacing: 7) {
                PaperGlyph(style: style, color: color, pdf: page.background != nil)
                if !compact {
                    Text(page.background != nil ? "PDF Page" : style.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, compact ? 8 : 11)
            .frame(height: 32)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
        .padding(.horizontal, 4)
        .popover(isPresented: $session.choosingPaper) { paperPicker }
    }

    private var paperPicker: some View {
        let hasPDF = pages[index].background != nil
        return PaperPicker(
            style: Binding(get: { store.notebook.style(of: pages[index]) }, set: { setPaper($0, store.notebook.color(of: pages[index])) }),
            color: Binding(get: { store.notebook.color(of: pages[index]) }, set: { setPaper(store.notebook.style(of: pages[index]), $0) }),
            size: hasPDF ? nil : Binding(get: { store.notebook.size(of: pages[index]) }, set: {
                store.setSize($0, page: session.allPages ? nil : pages[index].id)
            }),
            allPages: $session.allPages
        )
        .padding(20)
        .frame(width: 440)
    }

    private func setPaper(_ style: PaperStyle, _ color: PaperColor) {
        store.setPaper(style, color: color, page: session.allPages ? nil : pages[index].id)
    }
}
