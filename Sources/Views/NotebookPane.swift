import SwiftUI

struct LinkOption: Identifiable {
    let title: String
    let target: LinkTarget
    let label: String
    var id: String { title }
}

struct NotebookPane: View {
    let store: NotebookStore
    @Binding var pageIndex: Int
    let linkOptions: [LinkOption]
    let onOpenLink: (NoteLink) -> Void

    @State private var convertMode = false
    @State private var handle = CanvasHandle()
    @State private var confirmDelete = false
    @State private var addingText = false
    @State private var newText = ""

    private var pages: [NotePage] { store.notebook.pages }
    private var index: Int { min(max(pageIndex, 0), pages.count - 1) }
    private var isLastPage: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            NoteCanvas(store: store, page: pages[index], convertMode: $convertMode, handle: handle, onOpenLink: onOpenLink)
                .overlay(alignment: .top) {
                    if convertMode {
                        Text("Drag over handwriting to turn it into text")
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.top, 12)
                    }
                }
        }
        .confirmationDialog("Delete this page?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) { pageIndex = store.deletePage(at: index) }
        }
        .alert("Add Text", isPresented: $addingText) {
            TextField("Text", text: $newText)
            Button("Add") {
                handle.view?.addText(newText)
                newText = ""
            }
            Button("Cancel", role: .cancel) { newText = "" }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            Text(store.item.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if !linkOptions.isEmpty {
                Menu {
                    ForEach(linkOptions) { option in
                        Button(option.title) { handle.view?.addLink(option.target, label: option.label) }
                    }
                } label: {
                    Image(systemName: "link.badge.plus")
                }
            }
            Button { addingText = true } label: { Image(systemName: "textformat") }
            Toggle(isOn: $convertMode) { Image(systemName: "text.viewfinder") }
                .toggleStyle(.button)
            Menu {
                Picker("Paper", selection: Binding(get: { store.notebook.paper }, set: { store.setPaper($0) })) {
                    ForEach(PaperStyle.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                }
            } label: {
                Image(systemName: "doc.plaintext")
            }
            Divider().frame(height: 22)
            Button { pageIndex = index - 1 } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
            Text("\(index + 1) / \(pages.count)")
                .font(.subheadline)
                .monospacedDigit()
            Button {
                pageIndex = isLastPage ? store.addPage(after: index) : index + 1
            } label: {
                Image(systemName: isLastPage ? "plus" : "chevron.right")
            }
            Menu {
                Button { pageIndex = store.addPage(after: index) } label: { Label("Insert Page After", systemImage: "plus.square") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Page", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal)
        .frame(height: 44)
        .background(.bar)
    }
}
