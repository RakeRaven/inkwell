import UIKit

/// One leaf of paper turning over its hinge: pushed in first so it bows up into an arch, then lifted over.
/// Drawn from snapshots in thin strips with perspective, so the real pages can change underneath.
final class PageFlipView: UIView {
    /// The leaf lying flat to the right of its hinge, which is `leaf.minX`.
    private let leaf: CGRect
    private let forward: Bool
    /// How far the free edge gets pushed in before lifting (a stiff cover doesn't bow).
    private let push: CGFloat
    private let stage = UIView()
    private var strips: [(holder: CATransformLayer, front: CALayer, back: CALayer, frontShade: CALayer, backShade: CALayer)] = []
    private var link: CADisplayLink?
    private var animation: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval, done: () -> Void)?
    private(set) var progress: CGFloat = 0

    static let stripCount = 30
    /// Share of the turn spent pushing the page into an arch.
    private static let pushPhase: CGFloat = 0.28

    /// `front` faces up while the leaf lies right, `back` while it lies left (nil shows plain `backColor`).
    /// Forward turns go right to left, backward ones come back from the left.
    init(frame: CGRect, under: UIImage?, leaf: CGRect, front: UIImage?, back: UIImage?, backColor: UIColor,
         forward: Bool, push: CGFloat = 0.2) {
        self.leaf = leaf
        self.forward = forward
        self.push = push
        super.init(frame: frame)
        isUserInteractionEnabled = false
        if let under {
            let base = UIImageView(image: under)
            base.frame = bounds
            addSubview(base)
        }
        stage.frame = bounds
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 1800
        stage.layer.sublayerTransform = perspective
        addSubview(stage)

        let n = Self.stripCount
        let width = leaf.width / CGFloat(n)
        for i in 0..<n {
            let holder = CATransformLayer()
            holder.bounds = CGRect(x: 0, y: 0, width: width, height: leaf.height)
            holder.anchorPoint = CGPoint(x: 0, y: 0.5)
            let face = CALayer()
            face.frame = holder.bounds
            face.isDoubleSided = false
            face.contents = front?.cgImage
            face.contentsRect = CGRect(x: CGFloat(i) / CGFloat(n), y: 0, width: 1 / CGFloat(n), height: 1)
            face.backgroundColor = front == nil ? backColor.cgColor : nil
            let reverse = CALayer()
            reverse.frame = holder.bounds
            reverse.isDoubleSided = false
            reverse.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
            // lying left the leaf reads mirrored, so each strip takes the opposite slice of the back image
            reverse.contents = back?.cgImage
            reverse.contentsRect = CGRect(x: CGFloat(n - i - 1) / CGFloat(n), y: 0, width: 1 / CGFloat(n), height: 1)
            reverse.backgroundColor = back == nil ? backColor.cgColor : nil
            let frontShade = CALayer(), backShade = CALayer()
            for shade in [frontShade, backShade] {
                shade.frame = face.bounds
                shade.backgroundColor = UIColor.black.cgColor
                shade.opacity = 0
            }
            face.addSublayer(frontShade)
            reverse.addSublayer(backShade)
            holder.addSublayer(face)
            holder.addSublayer(reverse)
            stage.layer.addSublayer(holder)
            strips.append((holder, face, reverse, frontShade, backShade))
        }
        setProgress(0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 0 is where the turn starts, 1 where it lands.
    func setProgress(_ t: CGFloat) {
        progress = min(max(t, 0), 1)
        let w = leaf.width
        let p = Self.pushPhase
        var theta: CGFloat, inset: CGFloat, lag: CGFloat
        if progress < p {
            theta = 0
            inset = push * w * progress / p
            lag = 0
        } else {
            let u = (progress - p) / (1 - p)
            let eased = u * u * (3 - 2 * u)
            theta = .pi * eased
            // the arch relaxes as the leaf lifts, and the free edge trails a little mid-air
            inset = push * w * (1 - u)
            lag = w * 0.1 * sin(.pi * u)
        }
        if !forward {
            theta = .pi - theta
            lag = -lag
        }
        let span = w - inset
        let height = inset > 0.5 ? 2 * span / .pi * sqrt(max(w / span - 1, 0)) : 0
        // the arch always bows away from the surface it is leaving or landing on
        let bow = cos(theta) >= 0 ? 1.0 : -1.0
        let n = strips.count
        func point(_ s: CGFloat) -> (x: CGFloat, z: CGFloat) {
            let f = s / w
            let x = s * span / w
            let z = height * sin(.pi * f) * bow - lag * f * f
            return (leaf.minX + x * cos(theta) - z * sin(theta), x * sin(theta) + z * cos(theta))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var a = point(0)
        for (i, strip) in strips.enumerated() {
            let b = point(w * CGFloat(i + 1) / CGFloat(n))
            let dx = b.x - a.x, dz = b.z - a.z
            let angle = atan2(dz, dx)
            let length = max(hypot(dx, dz), 0.001)
            var t = CATransform3DMakeTranslation(0, 0, a.z)
            t = CATransform3DRotate(t, -angle, 0, 1, 0)
            // a hair wider so neighbouring strips never show a seam
            t = CATransform3DScale(t, length / strip.holder.bounds.width + 0.02, 1, 1)
            strip.holder.position = CGPoint(x: a.x, y: leaf.midY)
            strip.holder.transform = t
            // light from above: strips turned away from the viewer darken
            let facing = cos(angle)
            strip.frontShade.opacity = Float(0.42 * (1 - max(facing, 0)))
            strip.backShade.opacity = Float(0.42 * (1 - max(-facing, 0)))
            a = b
        }
        CATransaction.commit()
    }

    func animate(to target: CGFloat, duration: CFTimeInterval, completion: @escaping () -> Void) {
        link?.invalidate()
        animation = (progress, target, CACurrentMediaTime(), max(duration, 0.01), completion)
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step() {
        guard let animation else { return }
        let u = min((CACurrentMediaTime() - animation.start) / animation.duration, 1)
        setProgress(animation.from + (animation.to - animation.from) * CGFloat(u))
        if u >= 1 {
            link?.invalidate()
            link = nil
            self.animation = nil
            animation.done()
        }
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    /// The view as it looks on screen right now.
    static func snapshot(_ view: UIView, afterUpdates: Bool = false) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: afterUpdates)
        }
    }

    /// Several views drawn into one picture, each at its frame.
    static func compose(size: CGSize, _ parts: [(UIImage?, CGRect)]) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            for (image, rect) in parts { image?.draw(in: rect) }
        }
    }

    static func crop(_ image: UIImage, to rect: CGRect) -> UIImage {
        UIGraphicsImageRenderer(size: rect.size).image { _ in
            image.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
    }
}

/// How normal (not book) mode turns pages.
enum PageTurnStyle: String, CaseIterable, Identifiable {
    case slide, flip

    var id: String { rawValue }
    var title: String { self == .slide ? "Slide" : "Flip" }
}

/// What opening a notebook leafs through: its cover, then a few pages up to where you left off.
struct OpeningLeaves {
    var cover: UIImage?
    var pages: Int
    var paper: UIImage
}

/// Plays the opening over the notebook once, then gets out of the way.
struct OpeningFlip: UIViewRepresentable {
    let leaves: OpeningLeaves
    /// The book's open area, or nil for the whole pane.
    let book: BookLayout?
    let onDone: () -> Void

    func makeUIView(context: Context) -> OpeningFlipView {
        OpeningFlipView(leaves: leaves, book: book, onDone: onDone)
    }

    func updateUIView(_ view: OpeningFlipView, context: Context) {}
}

final class OpeningFlipView: UIView {
    private let leaves: OpeningLeaves
    private let book: BookLayout?
    private let onDone: () -> Void
    private var started = false

    init(leaves: OpeningLeaves, book: BookLayout?, onDone: @escaping () -> Void) {
        self.leaves = leaves
        self.book = book
        self.onDone = onDone
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !started, bounds.width > 0, bounds.height > 0 else { return }
        started = true
        var area = bounds
        if let book {
            area = CGRect(x: (bounds.width - book.size.width) / 2, y: (bounds.height - book.size.height) / 2,
                          width: book.size.width, height: book.size.height)
            if book.spread { area = CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height) }
        }
        // bottom of the stack first, so the cover ends up on top
        var flips: [(PageFlipView, delay: Double, duration: Double)] = []
        for i in (0..<leaves.pages).reversed() {
            let flip = PageFlipView(frame: bounds, under: nil, leaf: area, front: leaves.paper, back: leaves.paper,
                                    backColor: .white, forward: true, push: 0.12)
            addSubview(flip)
            flips.append((flip, 0.75 + Double(i) * 0.17, 0.5))
        }
        if let cover = leaves.cover {
            // a stiff board: it swings open without bowing
            let flip = PageFlipView(frame: bounds, under: nil, leaf: area, front: cover, back: nil,
                                    backColor: UIColor(white: 0.92, alpha: 1), forward: true, push: 0)
            addSubview(flip)
            flips.append((flip, 0.1, 0.85))
        }
        var remaining = flips.count
        for (flip, delay, duration) in flips {
            // without a cover the pages start straight away
            let start = leaves.cover == nil ? delay - 0.6 : delay
            DispatchQueue.main.asyncAfter(deadline: .now() + max(start, 0.05)) {
                flip.animate(to: 1, duration: duration) { [weak self, weak flip] in
                    flip?.removeFromSuperview()
                    remaining -= 1
                    if remaining == 0 { self?.onDone() }
                }
            }
        }
        if flips.isEmpty { onDone() }
    }
}
