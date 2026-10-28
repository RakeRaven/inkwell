import CoreImage
import SwiftUI
import UIKit
import Vision

/// Pan, pinch and rotate all at once, story-sticker style, plus tap.
/// Reports the change since the gesture began; the caller decides what it moves.
struct StickerGestures: UIViewRepresentable {
    var onBegin: (CGPoint) -> Void
    /// Translation, scale and rotation (radians) since `onBegin`.
    var onChange: (CGSize, CGFloat, CGFloat) -> Void
    var onEnd: () -> Void
    var onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handle(_:)))
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handle(_:)))
        let rotate = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.handle(_:)))
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        for gesture in [pan, pinch, rotate, tap] as [UIGestureRecognizer] {
            gesture.delegate = c
            view.addGestureRecognizer(gesture)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: StickerGestures
        private var active = Set<UIGestureRecognizer>()
        private var translation = CGSize.zero
        private var scale: CGFloat = 1
        private var rotation: CGFloat = 0

        init(_ parent: StickerGestures) {
            self.parent = parent
        }

        @objc func handle(_ gesture: UIGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                if active.isEmpty {
                    translation = .zero
                    scale = 1
                    rotation = 0
                    parent.onBegin(gesture.location(in: view))
                }
                active.insert(gesture)
                update(gesture, in: view)
            case .changed:
                update(gesture, in: view)
            default:
                update(gesture, in: view)
                active.remove(gesture)
                if active.isEmpty { parent.onEnd() }
            }
        }

        // each gesture keeps its last value when it ends, so lifting a finger doesn't jump
        private func update(_ gesture: UIGestureRecognizer, in view: UIView) {
            switch gesture {
            case let pan as UIPanGestureRecognizer:
                let t = pan.translation(in: view)
                translation = CGSize(width: t.x, height: t.y)
            case let pinch as UIPinchGestureRecognizer:
                scale = pinch.scale
            case let rotate as UIRotationGestureRecognizer:
                rotation = rotate.rotation
            default:
                break
            }
            parent.onChange(translation, scale, rotation)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            parent.onTap(gesture.location(in: view))
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

enum SubjectLifter {
    /// Cuts the main subject out of a photo, like long-pressing it in Photos. Falls back to the whole photo.
    static func lift(_ image: UIImage, completion: @escaping (UIImage) -> Void) {
        let source = image.downscaled(maxSide: 1600)
        DispatchQueue.global(qos: .userInitiated).async {
            var result = source
            if let cg = source.cgImage {
                let handler = VNImageRequestHandler(cgImage: cg, orientation: cgOrientation(source.imageOrientation))
                let request = VNGenerateForegroundInstanceMaskRequest()
                if (try? handler.perform([request])) != nil,
                   let observation = request.results?.first,
                   let buffer = try? observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: true) {
                    let ci = CIImage(cvPixelBuffer: buffer)
                    if let cut = CIContext().createCGImage(ci, from: ci.extent) {
                        result = UIImage(cgImage: cut)
                    }
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
