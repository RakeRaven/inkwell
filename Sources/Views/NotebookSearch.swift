import SwiftUI

/// Finds words anywhere in the notebook: handwriting, typed text, notes, lists, recordings and diagram labels.
struct NotebookSearch: View {
    let session: NotesSession
    @Binding var pageIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var reading = true

    private struct Hit: Identifiable {
        let id = UUID()
        let page: Int
        let text: String
        /// Where on the page, to light it up after jumping there.
        let rect: CGRect?
        let symbol: String
    }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        func has(_ text: String) -> Bool { text.localizedCaseInsensitiveContains(q) }
        var found: [Hit] = []
        for (i, page) in session.store.notebook.pages.enumerated() {
            for line in page.inkIndex?.lines ?? [] where has(line.text) {
                found.append(Hit(page: i, text: line.text, rect: line.rect, symbol: "scribble"))
            }
            for box in page.textBoxes where has(box.text) {
                let rect = CGRect(origin: box.anchor ?? box.origin, size: CGSize(width: 260, height: box.fontSize * 1.5))
                found.append(Hit(page: i, text: box.text, rect: rect, symbol: box.sticky == nil ? "textformat" : "note.text"))
            }
            for list in page.checklists {
                for text in [list.title] + list.items.map(\.text) where has(text) {
                    found.append(Hit(page: i, text: text, rect: CGRect(origin: list.origin, size: CGSize(width: 380, height: 40)), symbol: "checklist"))
                }
            }
            for note in page.voiceNotes where has(note.title) {
                found.append(Hit(page: i, text: note.title, rect: CGRect(x: note.position.x - 90, y: note.position.y - 16, width: 180, height: 32), symbol: "waveform"))
            }
            for shape in page.shapes {
                guard let d = shape.diagram else { continue }
                let element = d.element.map { Elements.name($0) } ?? ""
                for text in [d.label ?? "", d.type.title, element] where !text.isEmpty && has(text) {
                    found.append(Hit(page: i, text: text, rect: shape.bounds, symbol: "square.on.circle"))
                    break
                }
            }
        }
        return found
    }

    var body: some View {
        NavigationStack {
            List {
                if reading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading handwriting\u{2026}").foregroundStyle(Theme.muted)
                    }
                }
                ForEach(hits) { hit in
                    Button {
                        pageIndex = hit.page
                        dismiss()
                        if let rect = hit.rect {
                            // once the page has turned
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { session.handle.view?.flash(rect) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: hit.symbol)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.text).lineLimit(2).foregroundStyle(Theme.ink)
                                Text("Page \(hit.page + 1)").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                if !reading, query.count >= 2, hits.isEmpty {
                    Text("Nothing found").foregroundStyle(Theme.muted)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Handwriting, text, lists\u{2026}")
            .navigationTitle("Search Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            session.store.readAllInk { reading = false }
        }
    }
}
