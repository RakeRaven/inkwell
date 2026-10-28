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

    private var sortedItems: [LibraryItem] {
        library.items.sorted { $0.modified > $1.modified }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 24)], spacing: 28) {
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
                                Button(role: .destructive) { deleting = item } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(24)
            }
            .overlay {
                if library.items.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "books.vertical", description: Text("Create a notebook, or import a PDF or EPUB."))
                }
            }
            .navigationTitle("Inkwell")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    Button { path.append(library.createNotebook(title: "Untitled Notebook")) } label: {
                        Label("New Notebook", systemImage: "square.and.pencil")
                    }
                }
            }
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
}

private struct LibraryCell: View {
    @Environment(Library.self) private var library
    let item: LibraryItem
    @State private var thumbnail: UIImage?

    private var icon: String {
        switch item.kind {
        case .notebook: "book.closed"
        case .pdf: "doc.richtext"
        case .epub: "book"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground))
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: icon)
                    .font(.caption)
                    .padding(6)
                    .background(.thinMaterial, in: Circle())
                    .padding(8)
            }
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: item.modified) {
            thumbnail = library.thumbnail(for: item, size: CGSize(width: 340, height: 472))
        }
    }
}
