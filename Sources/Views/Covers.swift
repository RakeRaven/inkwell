import PhotosUI
import SwiftUI

struct CoverView: View {
    let cover: Cover
    let title: String
    var photo: UIImage?

    var body: some View {
        Color(hex: cover.color)
            .overlay {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                } else {
                    CoverPatternView(pattern: cover.pattern)
                }
            }
            .overlay(alignment: .leading) {
                LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14)
            }
            .overlay(alignment: .top) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 18)
                    .padding(.top, 26)
            }
            .clipped()
    }
}

struct CoverPatternView: View {
    let pattern: CoverPattern

    var body: some View {
        Canvas { ctx, size in
            let ink = GraphicsContext.Shading.color(.white.opacity(0.14))
            switch pattern {
            case .plain:
                break
            case .spine:
                let band = size.width * 0.2
                ctx.fill(Path(CGRect(x: 0, y: 0, width: band, height: size.height)), with: .color(.black.opacity(0.2)))
                var stitch = Path()
                stitch.move(to: CGPoint(x: band + 4, y: 0))
                stitch.addLine(to: CGPoint(x: band + 4, y: size.height))
                ctx.stroke(stitch, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            case .stripes:
                var path = Path()
                var x = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 14
                }
                ctx.stroke(path, with: ink, lineWidth: 4)
            case .dots:
                for x in stride(from: CGFloat(7), to: size.width, by: 14) {
                    for y in stride(from: CGFloat(7), to: size.height, by: 14) {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: ink)
                    }
                }
            case .grid:
                var path = Path()
                for x in stride(from: CGFloat(16), to: size.width, by: 16) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat(16), to: size.height, by: 16) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(path, with: ink, lineWidth: 1)
            }
        }
    }
}

/// Edits a cover. `photo` is what's shown; `photoChanged` marks a newly picked one that still needs saving.
struct CoverPicker: View {
    @Binding var cover: Cover?
    @Binding var photo: UIImage?
    @Binding var photoChanged: Bool
    let title: String
    @State private var pick: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 16) {
            Toggle("Cover", isOn: Binding(get: { cover != nil }, set: { on in
                cover = on ? Cover(color: Cover.colors.randomElement() ?? "2F5D8A") : nil
                if !on {
                    photo = nil
                    photoChanged = false
                }
            }))
            if let current = cover {
                CoverView(cover: current, title: title.isEmpty ? "Untitled" : title, photo: photo)
                    .frame(width: 150, height: 208)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 7), spacing: 10) {
                    ForEach(Cover.colors, id: \.self) { hex in
                        Button { cover?.color = hex } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(hex == current.color ? Color.accentColor : Color(.separator), lineWidth: hex == current.color ? 2.5 : 0.5).padding(-3))
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("Custom", selection: Binding(get: { Color(hex: current.color) }, set: { cover?.color = UIColor($0).hex }), supportsOpacity: false)
                        .labelsHidden()
                }
                Picker("Pattern", selection: Binding(get: { current.pattern }, set: { cover?.pattern = $0 })) {
                    ForEach(CoverPattern.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label(photo == nil ? "Use a Photo" : "Change Photo", systemImage: "photo")
                    }
                    if photo != nil {
                        Spacer()
                        Button("Remove Photo", role: .destructive) {
                            photo = nil
                            photoChanged = false
                            cover?.photo = nil
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    photo = image
                    photoChanged = true
                }
                pick = nil
            }
        }
    }
}

struct PaperPicker: View {
    @Binding var style: PaperStyle
    @Binding var color: PaperColor
    var allPages: Binding<Bool>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Paper Color", selection: $color) {
                ForEach(PaperColor.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 12) {
                ForEach(PaperStyle.allCases) { option in
                    Button { style = option } label: {
                        VStack(spacing: 4) {
                            Image(uiImage: PaperRenderer.image(option, color: color, width: 76))
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(option == style ? Color.accentColor : Color(.separator), lineWidth: option == style ? 2.5 : 0.5))
                            Text(option.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let allPages {
                Toggle("Apply to All Pages", isOn: allPages)
            }
        }
    }
}

struct NewNotebookSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let onCreate: (LibraryItem) -> Void

    @State private var title = ""
    @State private var cover: Cover? = Cover(color: Cover.colors.randomElement() ?? "2F5D8A")
    @State private var photo: UIImage?
    @State private var photoChanged = false
    @State private var paper: PaperStyle = .lined
    @State private var paperColor: PaperColor = .white

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Title", text: $title) }
                Section("Cover") {
                    CoverPicker(cover: $cover, photo: $photo, photoChanged: $photoChanged, title: title)
                }
                Section("Paper") {
                    PaperPicker(style: $paper, color: $paperColor)
                }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let item = library.createNotebook(title: name.isEmpty ? "Untitled Notebook" : name, cover: cover, paper: paper, paperColor: paperColor)
                        if cover != nil, photoChanged, let photo {
                            library.setCover(item.id, to: cover, photo: photo)
                        }
                        dismiss()
                        onCreate(library.item(item.id) ?? item)
                    }
                }
            }
        }
    }
}

struct CoverSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem

    @State private var cover: Cover?
    @State private var photo: UIImage?
    @State private var photoChanged = false

    init(item: LibraryItem) {
        self.item = item
        _cover = State(initialValue: item.cover)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CoverPicker(cover: $cover, photo: $photo, photoChanged: $photoChanged, title: item.title)
                } footer: {
                    Text("Without a cover, the library shows the first page.")
                }
            }
            .navigationTitle("Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.setCover(item.id, to: cover, photo: photoChanged ? photo : nil)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { photo = library.coverPhoto(for: item) }
    }
}
