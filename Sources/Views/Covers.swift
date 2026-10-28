import Observation
import PencilKit
import PhotosUI
import SwiftUI

/// Laid out at any size from one design at 160pt wide, so the editor preview matches the library.
struct CoverView: View {
    let cover: Cover
    let title: String
    var photo: UIImage?
    var ink: UIImage?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let s = size.width / 160
            ZStack {
                Color(hex: cover.color)
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(cover.zoom ?? 1)
                        .offset(x: (cover.offsetX ?? 0) * size.width, y: (cover.offsetY ?? 0) * size.height)
                } else {
                    CoverPatternView(pattern: cover.pattern)
                }
                LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14 * s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                titleLabel(scale: s)
                if let ink {
                    Image(uiImage: ink).resizable()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func titleLabel(scale s: CGFloat) -> some View {
        let position = cover.titlePosition ?? .top
        let style = cover.titleStyle ?? .label
        if position != .hidden {
            Text(title)
                .font(font(size: 13 * s))
                .foregroundStyle(style == .light ? Color.white : Color.black.opacity(0.85))
                .shadow(color: style == .light ? .black.opacity(0.5) : .clear, radius: 2 * s)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10 * s)
                .padding(.vertical, 6 * s)
                .background(style == .label ? Color.white.opacity(0.92) : .clear, in: RoundedRectangle(cornerRadius: 4 * s))
                .padding(.horizontal, 18 * s)
                .padding(.vertical, 26 * s)
                .frame(maxHeight: .infinity, alignment: position == .middle ? .center : position == .bottom ? .bottom : .top)
        }
    }

    private func font(size: CGFloat) -> Font {
        switch cover.titleFont ?? .system {
        case .system: .system(size: size, weight: .semibold)
        case .serif: .system(size: size, weight: .semibold, design: .serif)
        case .rounded: .system(size: size, weight: .bold, design: .rounded)
        case .hand: .custom("Noteworthy-Bold", size: size)
        }
    }

    static func inkImage(_ drawing: PKDrawing) -> UIImage {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: CGRect(origin: .zero, size: Cover.canvasSize), scale: 2)
        }
        return image
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

/// Unsaved cover edits. Photo and ink only get written when they changed.
@Observable
final class CoverDraft {
    var cover: Cover?
    var photo: UIImage?
    var photoChanged = false
    var ink = PKDrawing()
    var inkChanged = false

    init(cover: Cover?) {
        self.cover = cover
    }

    func load(from library: Library, item: LibraryItem) {
        photo = library.coverPhoto(for: item)
        ink = library.coverInk(for: item) ?? PKDrawing()
    }

    func save(to library: Library, id: UUID) {
        library.setCover(id, to: cover, photo: photoChanged ? photo : nil, ink: inkChanged ? ink : nil)
    }
}

struct CoverPicker: View {
    @Bindable var draft: CoverDraft
    let title: String
    @Binding var drawing: Bool

    @State private var pick: PhotosPickerItem?
    @State private var dragBase: CGSize?
    @State private var zoomBase: Double?

    var body: some View {
        VStack(spacing: 18) {
            Toggle("Cover", isOn: Binding(get: { draft.cover != nil }, set: { on in
                draft.cover = on ? Cover(color: Cover.colors.randomElement() ?? "2F5D8A") : nil
                if !on {
                    draft.photo = nil
                    draft.photoChanged = false
                    draft.ink = PKDrawing()
                    drawing = false
                }
            }))
            if let current = draft.cover {
                preview(current)
                drawControls
                colorControls(current)
                photoControls(current)
                titleControls(current)
            }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    draft.photo = image
                    draft.photoChanged = true
                    draft.cover?.zoom = nil
                    draft.cover?.offsetX = nil
                    draft.cover?.offsetY = nil
                }
                pick = nil
            }
        }
    }

    private func preview(_ current: Cover) -> some View {
        ZStack {
            CoverView(cover: current, title: title.isEmpty ? "Untitled" : title, photo: draft.photo)
            CoverInkCanvas(drawing: $draft.ink, active: drawing) { draft.inkChanged = true }
        }
        .frame(width: Cover.canvasSize.width, height: Cover.canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(drawing ? Theme.accent : .clear, lineWidth: 2))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .gesture(framingGesture, including: drawing || draft.photo == nil ? .none : .all)
        .frame(maxWidth: .infinity)
    }

    /// Drag and pinch to frame the photo.
    private var framingGesture: some Gesture {
        let drag = DragGesture()
            .onChanged { value in
                let base = dragBase ?? CGSize(width: draft.cover?.offsetX ?? 0, height: draft.cover?.offsetY ?? 0)
                dragBase = base
                draft.cover?.offsetX = clamp(Double(base.width + value.translation.width / Cover.canvasSize.width))
                draft.cover?.offsetY = clamp(Double(base.height + value.translation.height / Cover.canvasSize.height))
            }
            .onEnded { _ in dragBase = nil }
        let pinch = MagnifyGesture()
            .onChanged { value in
                let base = zoomBase ?? draft.cover?.zoom ?? 1
                zoomBase = base
                draft.cover?.zoom = min(max(base * Double(value.magnification), 1), 5)
            }
            .onEnded { _ in zoomBase = nil }
        return drag.simultaneously(with: pinch)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }

    private var drawControls: some View {
        HStack {
            Toggle(isOn: $drawing) { Label("Write on Cover", systemImage: "pencil.tip.crop.circle") }
                .toggleStyle(.button)
            Spacer()
            if !draft.ink.strokes.isEmpty {
                Button("Clear Writing", role: .destructive) {
                    draft.ink = PKDrawing()
                    draft.inkChanged = true
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func colorControls(_ current: Cover) -> some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 7), spacing: 10) {
                ForEach(Cover.colors, id: \.self) { hex in
                    Button { draft.cover?.color = hex } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(hex == current.color ? Theme.accent : Theme.line, lineWidth: hex == current.color ? 2.5 : 1).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("Custom", selection: Binding(get: { Color(hex: current.color) }, set: { draft.cover?.color = UIColor($0).hex }), supportsOpacity: false)
                    .labelsHidden()
            }
            if draft.photo == nil {
                Picker("Pattern", selection: Binding(get: { current.pattern }, set: { draft.cover?.pattern = $0 })) {
                    ForEach(CoverPattern.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func photoControls(_ current: Cover) -> some View {
        VStack(spacing: 10) {
            HStack {
                PhotosPicker(selection: $pick, matching: .images) {
                    Label(draft.photo == nil ? "Use a Photo" : "Change Photo", systemImage: "photo")
                }
                if draft.photo != nil {
                    Spacer()
                    Button("Remove Photo", role: .destructive) {
                        draft.photo = nil
                        draft.photoChanged = false
                        draft.cover?.photo = nil
                    }
                }
            }
            if draft.photo != nil {
                HStack {
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: Binding(get: { current.zoom ?? 1 }, set: { draft.cover?.zoom = $0 }), in: 1...5)
                    Image(systemName: "plus.magnifyingglass")
                    Button("Reset") {
                        draft.cover?.zoom = nil
                        draft.cover?.offsetX = nil
                        draft.cover?.offsetY = nil
                    }
                }
                .foregroundStyle(.secondary)
                Text("Drag and pinch the cover to frame the photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.borderless)
    }

    private func titleControls(_ current: Cover) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Title").font(.subheadline.weight(.semibold))
            Picker("Position", selection: Binding(get: { current.titlePosition ?? .top }, set: { draft.cover?.titlePosition = $0 })) {
                ForEach(CoverTitlePosition.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Style", selection: Binding(get: { current.titleStyle ?? .label }, set: { draft.cover?.titleStyle = $0 })) {
                ForEach(CoverTitleStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Font", selection: Binding(get: { current.titleFont ?? .system }, set: { draft.cover?.titleFont = $0 })) {
                ForEach(CoverTitleFont.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Handwriting on a cover, with its own tool picker.
struct CoverInkCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let active: Bool
    let onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        context.coordinator.picker.colorUserInterfaceStyle = .light
        context.coordinator.picker.addObserver(canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if canvas.drawing != drawing { canvas.drawing = drawing }
        canvas.isUserInteractionEnabled = active
        context.coordinator.picker.setVisible(active, forFirstResponder: canvas)
        if active {
            canvas.becomeFirstResponder()
        } else if canvas.isFirstResponder {
            canvas.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CoverInkCanvas
        let picker = PKToolPicker()

        init(_ parent: CoverInkCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard canvasView.drawing != parent.drawing else { return }
            parent.drawing = canvasView.drawing
            parent.onEdit()
        }
    }
}

struct PaperPicker: View {
    @Binding var style: PaperStyle
    @Binding var color: PaperColor
    var allPages: Binding<Bool>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(uiImage: PaperRenderer.image(style, color: color, width: 84))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(style.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("\(color.title) paper")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
            }
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
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(option == style ? Theme.accent : Theme.line, lineWidth: option == style ? 2.5 : 0.5))
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
    @State private var draft = CoverDraft(cover: Cover(color: Cover.colors.randomElement() ?? "2F5D8A"))
    @State private var drawing = false
    @State private var paper: PaperStyle = .lined
    @State private var paperColor: PaperColor = .white

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Title", text: $title) }
                Section("Cover") {
                    CoverPicker(draft: draft, title: title, drawing: $drawing)
                }
                Section("Paper") {
                    PaperPicker(style: $paper, color: $paperColor)
                }
            }
            .themedForm()
            .scrollDisabled(drawing)
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let item = library.createNotebook(title: name.isEmpty ? "Untitled Notebook" : name, cover: draft.cover, paper: paper, paperColor: paperColor)
                        if draft.cover != nil { draft.save(to: library, id: item.id) }
                        dismiss()
                        onCreate(library.item(item.id) ?? item)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

struct CoverSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem

    @State private var draft: CoverDraft
    @State private var drawing = false

    init(item: LibraryItem) {
        self.item = item
        _draft = State(initialValue: CoverDraft(cover: item.cover))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CoverPicker(draft: draft, title: item.title, drawing: $drawing)
                } footer: {
                    Text("Without a cover, the library shows the first page.")
                }
            }
            .themedForm()
            .scrollDisabled(drawing)
            .navigationTitle("Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.save(to: library, id: item.id)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear { draft.load(from: library, item: item) }
    }
}
