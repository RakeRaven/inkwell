import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var path: [LibraryItem] = []
    @State private var importing = false
    @State private var renaming: LibraryItem?
    @State private var newTitle = ""
    @State private var deleting: LibraryItem?
    @State private var message: String?
    @State private var creating = false
    @State private var coverItem: LibraryItem?
    @State private var filter: ItemKind?
    private let appearance = Appearance.shared

    private var sortedItems: [LibraryItem] {
        library.items.filter { filter == nil || $0.kind == filter }.sorted { $0.modified > $1.modified }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 28)], spacing: 32) {
                    ForEach(sortedItems) { item in
                        NavigationLink(value: item) { LibraryCell(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    newTitle = item.title
                                    renaming = item
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                if item.kind == .notebook {
                                    Button { coverItem = item } label: {
                                        Label("Change Cover", systemImage: "book.closed")
                                    }
                                }
                                Button(role: .destructive) { deleting = item } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .background(Theme.paper)
            .overlay {
                if sortedItems.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "books.vertical", description: Text("Create a notebook, or import a PDF or EPUB."))
                        .foregroundStyle(Theme.muted)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .epub], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    var failures: [String] = []
                    for url in urls {
                        do { try library.importFile(at: url) } catch { failures.append(error.localizedDescription) }
                    }
                    if !failures.isEmpty { message = failures.joined(separator: "\n") }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
            .navigationDestination(for: LibraryItem.self) { WorkspaceView(item: $0) }
            .sheet(isPresented: $creating) {
                NewNotebookSheet { path.append($0) }
            }
            .sheet(item: $coverItem) { CoverSheet(item: $0) }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Save") {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let item = renaming, !title.isEmpty { library.rename(item.id, to: title) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete \u{201C}\(deleting?.title ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let item = deleting { library.delete(item.id) }
                }
            } message: {
                Text("This removes it and its ink for good.")
            }
            .alert("Import Failed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 6) {
                Text("Inkwell")
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Menu {
                    Picker("Accent", selection: Binding(get: { appearance.accent }, set: appearance.setAccent)) {
                        ForEach(AccentTheme.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Appearance", selection: Binding(get: { appearance.scheme }, set: appearance.setScheme)) {
                        ForEach(ColorSchemeChoice.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Page Turn", selection: Binding(get: { appearance.pageTurn }, set: appearance.setPageTurn)) {
                        ForEach(PageTurnStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Open Like a Book", isOn: Binding(get: { appearance.openAnimation }, set: appearance.setOpenAnimation))
                } label: {
                    BarIcon("paintpalette")
                }
                Button { importing = true } label: { BarIcon("square.and.arrow.down") }
                    .buttonStyle(.plain)
                Button { creating = true } label: {
                    Label("New Notebook", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
            }
            HStack(spacing: 8) {
                chip("All", kind: nil)
                chip("Notebooks", kind: .notebook)
                chip("PDFs", kind: .pdf)
                chip("Books", kind: .epub)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }

    private func chip(_ title: String, kind: ItemKind?) -> some View {
        let selected = filter == kind
        let count = library.items.filter { kind == nil || $0.kind == kind }.count
        return Button { withAnimation(.snappy) { filter = kind } } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").foregroundStyle(selected ? Color.white.opacity(0.75) : Theme.muted)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(selected ? Theme.accent : Theme.raised, in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.clear : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryCell: View {
    @Environment(Library.self) private var library
    let item: LibraryItem
    @State private var thumbnail: UIImage?
    @State private var coverPhoto: UIImage?
    @State private var coverInk: UIImage?
    @State private var coverStickers: [UUID: UIImage] = [:]

    private var icon: String {
        switch item.kind {
        case .notebook: "book.closed"
        case .pdf: "doc.richtext"
        case .epub: "book"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.raised)
                if let cover = item.cover {
                    CoverView(cover: cover, title: item.title, photo: coverPhoto, ink: coverInk, stickerImages: coverStickers)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.muted)
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Theme.accent, in: Circle())
                    .padding(8)
            }
            .shadow(color: Color(hex: "3A2A1A").opacity(0.14), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(item.modified.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 2)
        }
        .task(id: item.modified) {
            guard item.cover == nil else { return }
            thumbnail = library.thumbnail(for: item, size: CGSize(width: 340, height: 472))
        }
        .task(id: item.cover) {
            coverPhoto = library.coverPhoto(for: item)
            coverInk = library.coverInk(for: item).map(CoverView.inkImage)
            coverStickers = library.coverStickers(for: item)
            if item.cover == nil, thumbnail == nil {
                thumbnail = library.thumbnail(for: item, size: CGSize(width: 340, height: 472))
            }
        }
    }
}
