import SwiftUI
import UIKit

/// Thin floating pen strip. Folds into a pill, fades while writing, or steps aside for Apple's picker.
struct InkToolbar: View {
    private let tools = InkTools.shared

    var body: some View {
        if tools.systemPicker {
            EmptyView()
        } else if tools.collapsed {
            Button { withAnimation(.snappy) { tools.collapsed = false } } label: {
                Image(systemName: tools.pen.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 46, height: 26)
                    .background(Theme.surface.opacity(0.94), in: Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        } else {
            strip
                .opacity(tools.hiddenWhileDrawing ? 0 : 1)
                .allowsHitTesting(!tools.hiddenWhileDrawing)
                .animation(.easeInOut(duration: 0.2), value: tools.hiddenWhileDrawing)
        }
    }

    private var strip: some View {
        let settings = tools.current
        let pen = tools.pen
        return HStack(spacing: 4) {
            ForEach(PenKind.allCases) { kind in
                Button { tools.select(kind) } label: {
                    Image(systemName: kind.symbol)
                        .frame(width: 30, height: 30)
                        .foregroundStyle(kind == pen ? Theme.accent : Theme.ink)
                        .background(kind == pen ? Theme.accent.opacity(0.18) : .clear, in: Circle())
                }
                .accessibilityLabel(kind.title)
            }
            if !settings.colors.isEmpty {
                separator
                ForEach(settings.colors.indices, id: \.self) { i in
                    Button { tools.setColor(index: i) } label: {
                        Circle()
                            .fill(Color(hex: settings.colors[i]))
                            .overlay(Circle().stroke(Theme.ink.opacity(0.25), lineWidth: 0.5))
                            .frame(width: 18, height: 18)
                            .padding(3)
                            .overlay(Circle().stroke(i == settings.colorIndex ? Theme.accent : .clear, lineWidth: 2))
                            .frame(width: 28, height: 30)
                    }
                }
                ColorPicker("Custom Color", selection: Binding(
                    get: { Color(hex: settings.colors[min(settings.colorIndex, settings.colors.count - 1)]) },
                    set: { tools.setCustomColor(UIColor($0)) }
                ), supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(0.8)
                .frame(width: 30)
            }
            if !pen.widths.isEmpty, pen != .eraser || tools.pixelEraser {
                separator
                widthSlider
            }
            separator
            Button { tools.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 30) }
            Button { tools.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 28, height: 30) }
            menu
            Button { withAnimation(.snappy) { tools.collapsed = true } } label: {
                Image(systemName: tools.atBottom ? "chevron.compact.down" : "chevron.compact.up").frame(width: 24, height: 30)
            }
        }
        .font(.system(size: 14, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Theme.surface.opacity(0.94), in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    /// Continuous size, with a dot that grows with it.
    private var widthSlider: some View {
        let range = tools.pen.widthRange
        let fraction = (tools.width - range.lowerBound) / (range.upperBound - range.lowerBound)
        return HStack(spacing: 6) {
            Circle()
                .fill(Theme.ink)
                .frame(width: 3 + 11 * fraction, height: 3 + 11 * fraction)
                .frame(width: 16)
            Slider(value: Binding(get: { Double(tools.width) }, set: { tools.setWidthValue(CGFloat($0)) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
                .frame(width: 120)
            Text(String(format: "%.1f", tools.width))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
                .frame(width: 30, alignment: .leading)
        }
        .padding(.horizontal, 2)
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 3)
    }

    private var menu: some View {
        Menu {
            Toggle(isOn: Binding(get: { tools.fingerDraws }, set: tools.setFingerDraws)) {
                Label("Draw with Finger", systemImage: "hand.draw")
            }
            Toggle(isOn: Binding(get: { tools.holdShapes }, set: tools.setHoldShapes)) {
                Label("Hold to Draw Shapes", systemImage: "square.on.circle")
            }
            Toggle(isOn: Binding(get: { tools.autoHide }, set: tools.setAutoHide)) {
                Label("Hide While Writing", systemImage: "eye.slash")
            }
            Picker(selection: Binding(get: { tools.pixelEraser }, set: tools.setPixelEraser)) {
                Text("Whole Strokes").tag(false)
                Text("Pixels").tag(true)
            } label: {
                Label("Eraser", systemImage: "eraser")
            }
            .pickerStyle(.menu)
            Button { tools.setAtBottom(!tools.atBottom) } label: {
                Label(tools.atBottom ? "Move to Top" : "Move to Bottom", systemImage: tools.atBottom ? "arrow.up.to.line" : "arrow.down.to.line")
            }
            Button { tools.setSystemPicker(true) } label: {
                Label("Use System Tool Picker", systemImage: "rectangle.bottomthird.inset.filled")
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 30)
        }
    }
}

/// Pencil double-tap and squeeze for the custom strip (Apple's picker handles its own).
struct PencilInteractions: UIViewRepresentable {
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        for case let interaction as UIPencilInteraction in view.interactions {
            interaction.isEnabled = enabled
        }
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            InkTools.shared.pencilTapped()
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended, UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
            withAnimation(.snappy) { InkTools.shared.collapsed.toggle() }
        }
    }
}
