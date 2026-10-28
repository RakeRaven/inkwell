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
                    if cover.patternOverPhoto == true {
                        CoverPatternView(pattern: cover.pattern)
                    }
                } else {
                    CoverPatternView(pattern: cover.pattern)
                }
                LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14 * s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if cover.mode == .typed {
                    titleLabel(in: size, scale: s)
                }
                if let ink {
                    Image(uiImage: ink).resizable()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func titleLabel(in size: CGSize, scale s: CGFloat) -> some View {
        let center = cover.titleCenter
        let style = cover.titleStyle ?? .label
        let left = center.x < 0.36, right = center.x > 0.64
        return Text(title)
            .font(font(size: 13 * s))
            .foregroundStyle(style == .light ? Color.white : Color.black.opacity(0.85))
            .shadow(color: style == .light ? .black.opacity(0.5) : .clear, radius: 2 * s)
            .lineLimit(3)
            .multilineTextAlignment(left ? .leading : right ? .trailing : .center)
            .padding(.horizontal, 10 * s)
            .padding(.vertical, 6 * s)
            .background(style == .label ? Color.white.opacity(0.92) : .clear, in: RoundedRectangle(cornerRadius: 4 * s))
            .frame(width: size.width - 36 * s, alignment: left ? .leading : right ? .trailing : .center)
            .position(x: size.width / 2, y: min(max(center.y, 0.06), 0.94) * size.height)
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

    private enum Drag { case title, photo, ignored }

    @State private var pick: PhotosPickerItem?
    @State private var drag: Drag?
    @State private var dragBase = CGPoint.zero
    @State private var zoomBase: Double?
    @State private var guideX: Double?
    @State private var guideY: Double?
    @State private var inkBefore: (ink: PKDrawing, changed: Bool)?

    private var canvas: CGSize { Cover.canvasSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(isOn: Binding(get: { draft.cover != nil }, set: { on in
                draft.cover = on ? Cover(color: Cover.colors.randomElement() ?? "2F5D8A") : nil
                if !on {
                    draft.photo = nil
                    draft.photoChanged = false
                    draft.ink = PKDrawing()
                    drawing = false
                }
            })) {
                Text("Cover").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            if let current = draft.cover {
                HStack(alignment: .top, spacing: 28) {
                    VStack(spacing: 14) {
                        preview(current)
                        writingControls
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        colorControls(current)
                        photoControls(current)
                        titleControls(current)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    draft.photo = image
                    draft.photoChanged = true
                    resetFraming()
                }
                pick = nil
            }
        }
    }

    private func preview(_ current: Cover) -> some View {
        ZStack {
            CoverView(cover: current, title: title.isEmpty ? "Untitled" : title, photo: draft.photo)
            CoverInkCanvas(drawing: $draft.ink, active: drawing) { draft.inkChanged = true }
            if drag == .title { guides }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(drawing ? Theme.accent : Theme.line, lineWidth: drawing ? 2.5 : 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        .contentShape(Rectangle())
        .gesture(dragGesture(current).simultaneously(with: pinchGesture), including: drawing ? .none : .all)
    }

    /// Snap points, plus the lines the title is snapped to.
    private var guides: some View {
        Canvas { ctx, size in
            for x in Cover.titleColumns {
                for y in Cover.titleRows {
                    ctx.fill(Path(ellipseIn: CGRect(x: x * size.width - 3, y: y * size.height - 3, width: 6, height: 6)), with: .color(.white.opacity(0.8)))
                }
            }
            var lines = Path()
            if let guideX {
                lines.move(to: CGPoint(x: guideX * size.width, y: 0))
                lines.addLine(to: CGPoint(x: guideX * size.width, y: size.height))
            }
            if let guideY {
                lines.move(to: CGPoint(x: 0, y: guideY * size.height))
                lines.addLine(to: CGPoint(x: size.width, y: guideY * size.height))
            }
            ctx.stroke(lines, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .allowsHitTesting(false)
    }

    /// Drags the title when it starts on it (snapping to the grid), otherwise pans the photo.
    private func dragGesture(_ current: Cover) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if drag == nil {
                    let center = current.titleCenter
                    if current.mode == .typed, abs(value.startLocation.y - center.y * canvas.height) < 30 {
                        drag = .title
                        dragBase = center
                    } else if draft.photo != nil {
                        drag = .photo
                        dragBase = CGPoint(x: current.offsetX ?? 0, y: current.offsetY ?? 0)
                    } else {
                        drag = .ignored
                    }
                }
                let x = Double(dragBase.x + value.translation.width / canvas.width)
                let y = Double(dragBase.y + value.translation.height / canvas.height)
                switch drag {
                case .title:
                    let column = Cover.titleColumns.min { abs($0 - x) < abs($1 - x) } ?? 0.5
                    var row = min(max(y, 0.06), 0.94)
                    let nearest = Cover.titleRows.min { abs($0 - row) < abs($1 - row) } ?? 0.5
                    guideY = abs(nearest - row) < 0.05 ? nearest : nil
                    if let guideY { row = guideY }
                    guideX = column
                    draft.cover?.titleX = column
                    draft.cover?.titleY = row
                case .photo:
                    draft.cover?.offsetX = min(max(x, -1), 1)
                    draft.cover?.offsetY = min(max(y, -1), 1)
                default:
                    break
                }
            }
            .onEnded { _ in
                drag = nil
                guideX = nil
                guideY = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard draft.photo != nil else { return }
                let base = zoomBase ?? draft.cover?.zoom ?? 1
                zoomBase = base
                draft.cover?.zoom = min(max(base * Double(value.magnification), 1), 5)
            }
            .onEnded { _ in zoomBase = nil }
    }

    private func resetFraming() {
        draft.cover?.zoom = nil
        draft.cover?.offsetX = nil
        draft.cover?.offsetY = nil
    }

    @ViewBuilder
    private var writingControls: some View {
        if drawing {
            HStack(spacing: 10) {
                Button("Cancel") {
                    if let inkBefore {
                        draft.ink = inkBefore.ink
                        draft.inkChanged = inkBefore.changed
                    }
                    inkBefore = nil
                    drawing = false
                }
                .buttonStyle(.bordered)
                Button("Done") {
                    inkBefore = nil
                    drawing = false
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            HStack(spacing: 10) {
                Button { startWriting() } label: { Label("Write on Cover", systemImage: "pencil.tip.crop.circle") }
                    .buttonStyle(.bordered)
                if !draft.ink.strokes.isEmpty {
                    Button(role: .destructive) {
                        draft.ink = PKDrawing()
                        draft.inkChanged = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func startWriting() {
        inkBefore = (draft.ink, draft.inkChanged)
        drawing = true
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Theme.muted)
            .textCase(.uppercase)
    }

    private func colorControls(_ current: Cover) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Colour & Pattern")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 7), alignment: .leading, spacing: 10) {
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
            Picker("Pattern", selection: Binding(get: { current.pattern }, set: { draft.cover?.pattern = $0 })) {
                ForEach(CoverPattern.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if draft.photo != nil {
                Toggle("Pattern over photo", isOn: Binding(get: { current.patternOverPhoto ?? false }, set: { draft.cover?.patternOverPhoto = $0 }))
                    .font(.system(size: 15))
            }
        }
    }

    private func photoControls(_ current: Cover) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Photo")
            HStack(spacing: 10) {
                PhotosPicker(selection: $pick, matching: .images) {
                    Label(draft.photo == nil ? "Choose Photo" : "Change", systemImage: "photo")
                }
                .buttonStyle(.bordered)
                if draft.photo != nil {
                    Button("Reset Framing") { resetFraming() }
                        .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        draft.photo = nil
                        draft.photoChanged = false
                        draft.cover?.photo = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if draft.photo != nil {
                Text("Pinch and drag the cover to frame the photo.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func titleControls(_ current: Cover) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Title")
            Picker("Title", selection: Binding(get: { current.mode }, set: { mode in
                draft.cover?.titleMode = mode
                if mode == .handwritten, !drawing { startWriting() }
            })) {
                ForEach(CoverTitleMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if current.mode == .typed {
                Picker("Style", selection: Binding(get: { current.titleStyle ?? .label }, set: { draft.cover?.titleStyle = $0 })) {
                    ForEach(CoverTitleStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Font", selection: Binding(get: { current.titleFont ?? .system }, set: { draft.cover?.titleFont = $0 })) {
                    ForEach(CoverTitleFont.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Drag the title on the cover. It snaps to a 3 \u{00D7} 3 grid.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            } else if current.mode == .handwritten {
                Text("Write the title on the cover with your Pencil.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
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
    /// Nil when the page's size is fixed (a PDF page).
    var size: Binding<CGSize>?
    var allPages: Binding<Bool>?

    private var pageSize: CGSize { size?.wrappedValue ?? notebookPageSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(uiImage: PaperRenderer.image(style, color: color, width: 90, pageSize: pageSize))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 90, height: 110)
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(style.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
            }
            Picker("Paper Colour", selection: $color) {
                ForEach(PaperColor.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 12)], spacing: 14) {
                ForEach(PaperStyle.allCases) { option in
                    Button { style = option } label: {
                        VStack(spacing: 5) {
                            Image(uiImage: PaperRenderer.image(option, color: color, width: 78))
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(option == style ? Theme.accent : Theme.line, lineWidth: option == style ? 2.5 : 1))
                            Text(option.title)
                                .font(.system(size: 11, weight: option == style ? .bold : .medium))
                                .foregroundStyle(option == style ? Theme.accent : Theme.ink)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let size {
                HStack {
                    Text("Size").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Picker("Size", selection: Binding(get: { PageSize.match(size.wrappedValue)?.size ?? .a4 }, set: { preset in
                        size.wrappedValue = preset.size(landscape: PageSize.match(size.wrappedValue)?.landscape ?? false)
                    })) {
                        ForEach(PageSize.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Picker("Orientation", selection: Binding(get: { PageSize.match(size.wrappedValue)?.landscape ?? false }, set: { landscape in
                        size.wrappedValue = (PageSize.match(size.wrappedValue)?.size ?? .a4).size(landscape: landscape)
                    })) {
                        Image(systemName: "rectangle.portrait").tag(false)
                        Image(systemName: "rectangle").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }
            }
            if let allPages {
                Toggle("Apply to All Pages", isOn: allPages)
                    .font(.system(size: 15, weight: .semibold))
            }
        }
    }

    private var detail: String {
        var parts = ["\(color.title) paper"]
        if size != nil, let match = PageSize.match(pageSize) {
            parts.append("\(match.size.title) \(match.landscape ? "landscape" : "portrait")")
        }
        return parts.joined(separator: " \u{00B7} ")
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
    @State private var size = notebookPageSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("Notebook title", text: $title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .textFieldStyle(.plain)
                        .card()
                    CoverPicker(draft: draft, title: title, drawing: $drawing)
                        .card()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Paper").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                        PaperPicker(style: $paper, color: $paperColor, size: $size)
                    }
                    .card()
                }
                .padding(28)
            }
            .scrollDisabled(drawing)
            .background(Theme.paper)
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let item = library.createNotebook(title: name.isEmpty ? "Untitled Notebook" : name, cover: draft.cover,
                                                          paper: paper, paperColor: paperColor, size: size)
                        if draft.cover != nil { draft.save(to: library, id: item.id) }
                        dismiss()
                        onCreate(library.item(item.id) ?? item)
                    }
                    .fontWeight(.semibold)
                    .disabled(drawing)
                }
            }
        }
        .presentationSizing(.page)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CoverPicker(draft: draft, title: item.title, drawing: $drawing)
                        .card()
                    Text("Without a cover, the library shows the first page.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                }
                .padding(28)
            }
            .scrollDisabled(drawing)
            .background(Theme.paper)
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
                    .disabled(drawing)
                }
            }
        }
        .presentationSizing(.page)
        .onAppear { draft.load(from: library, item: item) }
    }
}
