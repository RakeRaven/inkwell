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
    var stickerImages: [UUID: UIImage] = [:]

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
                        CoverPatternView(pattern: cover.pattern, color: cover.patternColor)
                    }
                } else {
                    CoverPatternView(pattern: cover.pattern, color: cover.patternColor)
                }
                LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14 * s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if cover.mode == .typed {
                    titleLabel(in: size, scale: s)
                }
                ForEach(cover.stickers ?? []) { sticker in
                    stickerView(sticker, scale: s)
                        .scaleEffect(CGFloat(sticker.scale))
                        .rotationEffect(.radians(sticker.rotation))
                        .position(x: CGFloat(sticker.x) * size.width, y: CGFloat(sticker.y) * size.height)
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
        return Text(title)
            .font(font(size: 13 * s))
            .foregroundStyle(style == .light ? Color.white : Color.black.opacity(0.85))
            .shadow(color: style == .light ? .black.opacity(0.5) : .clear, radius: 2 * s)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10 * s)
            .padding(.vertical, 6 * s)
            .background(style == .label ? Color.white.opacity(0.92) : .clear, in: RoundedRectangle(cornerRadius: 4 * s))
            .frame(maxWidth: size.width * 0.82)
            .scaleEffect(CGFloat(cover.titleScale ?? 1))
            .rotationEffect(.radians(cover.titleRotation ?? 0))
            .position(x: center.x * size.width, y: center.y * size.height)
    }

    @ViewBuilder
    private func stickerView(_ sticker: CoverSticker, scale s: CGFloat) -> some View {
        if let emoji = sticker.emoji {
            Text(emoji)
                .font(.system(size: max(Self.emojiSize * s, 1)))
                .fixedSize()
        } else if let image = stickerImages[sticker.id] {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: Self.pictureSize * s, height: Self.pictureSize * s)
        }
    }

    /// Sticker sizes at the 160pt design width, before their own scale.
    static let emojiSize: CGFloat = 26
    static let pictureSize: CGFloat = 54

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
    /// Hex; white when nil.
    var color: String?

    var body: some View {
        Canvas { ctx, size in
            let base = color.map { Color(hex: $0) } ?? .white
            let ink = GraphicsContext.Shading.color(base.opacity(color == nil ? 0.14 : 0.45))
            switch pattern {
            case .plain:
                break
            case .spine:
                let band = size.width * 0.2
                let fill: Color = color == nil ? .black.opacity(0.2) : base.opacity(0.85)
                ctx.fill(Path(CGRect(x: 0, y: 0, width: band, height: size.height)), with: .color(fill))
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

/// Unsaved cover edits. Photo, ink and picture stickers only get written when they changed.
@Observable
final class CoverDraft {
    var cover: Cover?
    var photo: UIImage?
    var photoChanged = false
    var ink = PKDrawing()
    var inkChanged = false
    var stickerImages: [UUID: UIImage] = [:]

    init(cover: Cover?) {
        self.cover = cover
    }

    func load(from library: Library, item: LibraryItem) {
        photo = library.coverPhoto(for: item)
        ink = library.coverInk(for: item) ?? PKDrawing()
        stickerImages = library.coverStickers(for: item)
    }

    func save(to library: Library, id: UUID) {
        library.setCover(id, to: cover, photo: photoChanged ? photo : nil, ink: inkChanged ? ink : nil, stickers: stickerImages)
    }
}

struct CoverPicker: View {
    @Bindable var draft: CoverDraft
    let title: String
    @Binding var drawing: Bool

    private enum Target: Equatable {
        case title, sticker(UUID), photo
    }

    /// Where the touched thing started: centre, scale and rotation.
    private struct Start {
        var x: Double, y: Double, scale: Double, rotation: Double
    }

    @State private var pick: PhotosPickerItem?
    @State private var stickerPick: PhotosPickerItem?
    @State private var lifting = false
    @State private var customSticker = ""
    @State private var target: Target?
    @State private var selected: Target?
    @State private var start = Start(x: 0, y: 0, scale: 1, rotation: 0)
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
                        previewControls(current)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        colorControls(current)
                        photoControls
                        titleControls(current)
                        stickerControls
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
        .onChange(of: stickerPick) { _, item in
            guard let item else { return }
            lifting = true
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    SubjectLifter.lift(image) { cut in
                        let sticker = CoverSticker(emoji: nil)
                        draft.stickerImages[sticker.id] = cut
                        add(sticker)
                        lifting = false
                    }
                } else {
                    lifting = false
                }
                stickerPick = nil
            }
        }
    }

    private func preview(_ current: Cover) -> some View {
        ZStack {
            CoverView(cover: current, title: title.isEmpty ? "Untitled" : title, photo: draft.photo, stickerImages: draft.stickerImages)
            CoverInkCanvas(drawing: $draft.ink, active: drawing) { draft.inkChanged = true }
            if !drawing {
                overlay(current)
                StickerGestures(onBegin: { begin(at: $0, current) }, onChange: change, onEnd: end, onTap: { selected = hit($0, current) })
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(drawing ? Theme.accent : Theme.line, lineWidth: drawing ? 2.5 : 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    /// Snap guides while moving, and a dashed ring round the selected item.
    private func overlay(_ current: Cover) -> some View {
        Canvas { ctx, size in
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
            if let selected, let ring = frame(of: selected, current) {
                let rect = CGRect(x: ring.center.x - ring.radius, y: ring.center.y - ring.radius, width: ring.radius * 2, height: ring.radius * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    // Gestures

    /// Rough touch area of an item, in preview points.
    private func frame(of target: Target, _ current: Cover) -> (center: CGPoint, radius: CGFloat)? {
        let s = canvas.width / 160
        switch target {
        case .title:
            guard current.mode == .typed else { return nil }
            let c = current.titleCenter
            let width = min(canvas.width * 0.41, CGFloat(max(title.count, 7)) * 3.6 * s + 10 * s)
            return (CGPoint(x: c.x * canvas.width, y: c.y * canvas.height), width * CGFloat(current.titleScale ?? 1))
        case .sticker(let id):
            guard let sticker = current.stickers?.first(where: { $0.id == id }) else { return nil }
            let base = sticker.emoji == nil ? CoverView.pictureSize : CoverView.emojiSize
            return (CGPoint(x: CGFloat(sticker.x) * canvas.width, y: CGFloat(sticker.y) * canvas.height), base * s * 0.62 * CGFloat(sticker.scale))
        case .photo:
            return nil
        }
    }

    /// Topmost sticker, then the title.
    private func hit(_ point: CGPoint, _ current: Cover) -> Target? {
        let candidates = (current.stickers ?? []).reversed().map { Target.sticker($0.id) } + [.title]
        return candidates.first { candidate in
            guard let f = frame(of: candidate, current) else { return false }
            if candidate == .title {
                // the title is wide and short
                let rotation = CGFloat(current.titleRotation ?? 0)
                let dx = point.x - f.center.x, dy = point.y - f.center.y
                let lx = dx * cos(rotation) + dy * sin(rotation), ly = -dx * sin(rotation) + dy * cos(rotation)
                return abs(lx) < f.radius + 10 && abs(ly) < 22 * CGFloat(current.titleScale ?? 1) + 10
            }
            return hypot(point.x - f.center.x, point.y - f.center.y) < f.radius + 12
        }
    }

    private func begin(at point: CGPoint, _ current: Cover) {
        target = hit(point, current) ?? (draft.photo != nil ? .photo : nil)
        switch target {
        case .title:
            let c = current.titleCenter
            start = Start(x: Double(c.x), y: Double(c.y), scale: current.titleScale ?? 1, rotation: current.titleRotation ?? 0)
            selected = .title
        case .sticker(let id):
            if let sticker = current.stickers?.first(where: { $0.id == id }) {
                start = Start(x: sticker.x, y: sticker.y, scale: sticker.scale, rotation: sticker.rotation)
            }
            selected = target
        case .photo:
            start = Start(x: current.offsetX ?? 0, y: current.offsetY ?? 0, scale: current.zoom ?? 1, rotation: 0)
        case nil:
            break
        }
    }

    private func change(_ translation: CGSize, _ scale: CGFloat, _ rotation: CGFloat) {
        guard let target, translation.width.isFinite, translation.height.isFinite,
              scale.isFinite, scale > 0, rotation.isFinite else { return }
        let x = start.x + Double(translation.width / canvas.width)
        let y = start.y + Double(translation.height / canvas.height)
        if target == .photo {
            draft.cover?.offsetX = min(max(x, -1), 1)
            draft.cover?.offsetY = min(max(y, -1), 1)
            draft.cover?.zoom = min(max(start.scale * Double(scale), 1), 5)
            return
        }
        // snap the centre to the middle line and the title rows, and near-level to level
        let rows = target == .title ? Cover.titleRows : [0.5]
        let nearRow = rows.min { abs($0 - y) < abs($1 - y) } ?? 0.5
        guideX = abs(x - 0.5) < 0.025 ? 0.5 : nil
        guideY = abs(nearRow - y) < 0.025 ? nearRow : nil
        let cx = min(max(guideX ?? x, 0.02), 0.98)
        let cy = min(max(guideY ?? y, 0.02), 0.98)
        let s = min(max(start.scale * Double(scale), 0.3), 5)
        var r = start.rotation + Double(rotation)
        let turns = (r / (.pi / 2)).rounded() * (.pi / 2)
        if abs(r - turns) < 0.07 { r = turns }
        switch target {
        case .title:
            draft.cover?.titleX = cx
            draft.cover?.titleY = cy
            draft.cover?.titleScale = s
            draft.cover?.titleRotation = r
        case .sticker(let id):
            guard let i = draft.cover?.stickers?.firstIndex(where: { $0.id == id }) else { return }
            draft.cover?.stickers?[i].x = cx
            draft.cover?.stickers?[i].y = cy
            draft.cover?.stickers?[i].scale = s
            draft.cover?.stickers?[i].rotation = r
        case .photo:
            break
        }
    }

    private func end() {
        target = nil
        guideX = nil
        guideY = nil
    }

    private func resetFraming() {
        draft.cover?.zoom = nil
        draft.cover?.offsetX = nil
        draft.cover?.offsetY = nil
    }

    private func add(_ sticker: CoverSticker) {
        var sticker = sticker
        // stagger new stickers so they don't stack exactly
        let count = Double(draft.cover?.stickers?.count ?? 0)
        sticker.x = 0.5 + (count.truncatingRemainder(dividingBy: 3) - 1) * 0.12
        sticker.y = 0.55 + (count.truncatingRemainder(dividingBy: 2)) * 0.1
        // read first: writing draft.cover while reading it in the same line traps
        let stickers = (draft.cover?.stickers ?? []) + [sticker]
        draft.cover?.stickers = stickers
        selected = .sticker(sticker.id)
    }

    // Controls

    @ViewBuilder
    private func previewControls(_ current: Cover) -> some View {
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
                Button { startWriting() } label: { Label("Write", systemImage: "pencil.tip.crop.circle") }
                    .buttonStyle(.bordered)
                if !draft.ink.strokes.isEmpty {
                    Button(role: .destructive) {
                        draft.ink = PKDrawing()
                        draft.inkChanged = true
                    } label: {
                        Label("Writing", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                if case .sticker(let id) = selected {
                    Button(role: .destructive) {
                        draft.cover?.stickers?.removeAll { $0.id == id }
                        selected = nil
                    } label: {
                        Label("Sticker", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Drag, pinch and twist the title, stickers or photo.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private func startWriting() {
        inkBefore = (draft.ink, draft.inkChanged)
        selected = nil
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
            if current.pattern != .plain {
                HStack {
                    ColorPicker("Pattern colour", selection: Binding(get: { Color(hex: current.patternColor ?? "FFFFFF") }, set: {
                        draft.cover?.patternColor = UIColor($0).hex
                    }), supportsOpacity: false)
                    if current.patternColor != nil {
                        Button("Reset") { draft.cover?.patternColor = nil }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.system(size: 15))
                if draft.photo != nil {
                    Toggle("Pattern over photo", isOn: Binding(get: { current.patternOverPhoto ?? false }, set: { draft.cover?.patternOverPhoto = $0 }))
                        .font(.system(size: 15))
                }
            }
        }
    }

    private var photoControls: some View {
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
            } else if current.mode == .handwritten {
                Text("Write the title on the cover with your Pencil.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private var stickerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Stickers")
            HStack(spacing: 8) {
                TextField("Type or pick an emoji", text: $customSticker)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let text = customSticker.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    add(CoverSticker(emoji: text))
                    customSticker = ""
                }
                .buttonStyle(.bordered)
            }
            PhotosPicker(selection: $stickerPick, matching: .images) {
                Label(lifting ? "Cutting out\u{2026}" : "Sticker from Photo", systemImage: "person.crop.square.badge.camera")
            }
            .buttonStyle(.bordered)
            .disabled(lifting)
            Text("Use the emoji key on the keyboard for emoji. Photo stickers cut out the subject automatically.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
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
            HStack(alignment: .center, spacing: 16) {
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
                Spacer(minLength: 8)
                if let size { sizeControls(size) }
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
            if let allPages {
                Toggle("Apply to All Pages", isOn: allPages)
                    .font(.system(size: 15, weight: .semibold))
            }
        }
    }

    private func sizeControls(_ size: Binding<CGSize>) -> some View {
        let match = PageSize.match(size.wrappedValue)
        return VStack(alignment: .trailing, spacing: 8) {
            Menu {
                Picker("Size", selection: Binding(get: { match?.size ?? .a4 }, set: { preset in
                    size.wrappedValue = preset.size(landscape: match?.landscape ?? false)
                })) {
                    ForEach(PageSize.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(match?.size.title ?? "Custom")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Theme.raised, in: Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            }
            Picker("Orientation", selection: Binding(get: { match?.landscape ?? false }, set: { landscape in
                size.wrappedValue = (match?.size ?? .a4).size(landscape: landscape)
            })) {
                Image(systemName: "rectangle.portrait").tag(false)
                Image(systemName: "rectangle").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 100)
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
