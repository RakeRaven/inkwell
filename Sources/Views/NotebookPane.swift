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
    let showsBar: Bool
    let linkOptions: [LinkOption]
    let onOpenLink: (NoteLink) -> Void

    @State private var convertMode = false
    @State private var handle = CanvasHandle()
    @State private var confirmDelete = false
    @State private var addingText = false
    @State private var newText = ""
    @State private var choosingPaper = false
    @State private var allPages = false

    private var pages: [NotePage] { store.notebook.pages }
    private var index: Int { min(max(pageIndex, 0), pages.count - 1) }
    private var isLastPage: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            if showsBar {
                toolbar
                Divider()
            }
            NoteCanvas(store: store, page: pages[index], convertMode: $convertMode, handle: handle, onOpenLink: onOpenLink, onSwipe: swipe)
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
        .onChange(of: allPages) { _, all in
            guard all else { return }
            let page = pages[index]
            store.setPaper(store.notebook.style(of: page), color: store.notebook.color(of: page), page: nil)
        }
    }

    private func swipe(_ delta: Int) -> Bool {
        let next = index + delta
        guard pages.indices.contains(next) else { return false }
        pageIndex = next
        return true
    }

    private var paperPicker: some View {
        PaperPicker(
            style: Binding(get: { store.notebook.style(of: pages[index]) }, set: { setPaper($0, store.notebook.color(of: pages[index])) }),
            color: Binding(get: { store.notebook.color(of: pages[index]) }, set: { setPaper(store.notebook.style(of: pages[index]), $0) }),
            allPages: $allPages
        )
        .padding()
        .frame(width: 400)
    }

    private func setPaper(_ style: PaperStyle, _ color: PaperColor) {
        store.setPaper(style, color: color, page: allPages ? nil : pages[index].id)
    }

    private var toolbar: some View {
        let page = pages[index]
        let style = store.notebook.style(of: page)
        let color = store.notebook.color(of: page)
        return HStack(spacing: 2) {
            Text(store.item.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer(minLength: 8)
            if !linkOptions.isEmpty {
                Menu {
                    ForEach(linkOptions) { option in
                        Button(option.title) { handle.view?.addLink(option.target, label: option.label) }
                    }
                } label: {
                    BarIcon("link.badge.plus")
                }
            }
            Button { addingText = true } label: { BarIcon("textformat") }
            Button { convertMode.toggle() } label: { BarIcon("text.viewfinder", active: convertMode) }
            // shows the current page's paper so you know what you're switching from
            Button { choosingPaper = true } label: {
                HStack(spacing: 6) {
                    Image(uiImage: PaperRenderer.image(style, color: color, width: 14))
                        .resizable()
                        .frame(width: 14, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.line, lineWidth: 1))
                    Text(style.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.raised, in: Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            }
            .popover(isPresented: $choosingPaper) { paperPicker }
            .padding(.horizontal, 4)
            Theme.line.frame(width: 1, height: 22).padding(.horizontal, 4)
            Button { pageIndex = index - 1 } label: { BarIcon("chevron.left") }
                .disabled(index == 0)
            Text("\(index + 1) / \(pages.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
            Button {
                pageIndex = isLastPage ? store.addPage(after: index) : index + 1
            } label: {
                BarIcon(isLastPage ? "plus" : "chevron.right")
            }
            Menu {
                Button { pageIndex = store.addPage(after: index) } label: { Label("Insert Page After", systemImage: "plus.square") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Page", systemImage: "trash") }
            } label: {
                BarIcon("ellipsis")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .barStyle()
    }
}
