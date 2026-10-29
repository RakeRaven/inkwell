import SwiftUI
import UIKit

/// A card floating over the page that edits the selection without blocking the page under it.
final class FloatingPanel: UIView {
    private let host: UIViewController
    private let header = UIView()
    var onClose: (() -> Void)?
    private var dragOrigin: CGPoint = .zero
    private static let headerHeight: CGFloat = 30

    init<Content: View>(_ content: Content, size: CGSize) {
        host = UIHostingController(rootView: content)
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height + Self.headerHeight)))
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 6)

        let card = UIView(frame: bounds)
        card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.backgroundColor = Theme.uiPaper
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        addSubview(card)

        header.frame = CGRect(x: 0, y: 0, width: size.width, height: Self.headerHeight)
        header.autoresizingMask = [.flexibleWidth]
        let grabber = UIView(frame: CGRect(x: size.width / 2 - 20, y: 10, width: 40, height: 5))
        grabber.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.4)
        grabber.layer.cornerRadius = 2.5
        header.addSubview(grabber)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .secondaryLabel
        close.frame = CGRect(x: size.width - 40, y: 0, width: 36, height: Self.headerHeight)
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        header.addSubview(close)
        // drag the card out of the way by its top bar
        header.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        card.addSubview(header)

        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: Self.headerHeight, width: size.width, height: size.height)
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(host.view)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the card on the side of the screen away from `avoiding`, given in the parent's view.
    func show(in parent: UIViewController, avoiding rect: CGRect) {
        let area = parent.view.bounds.inset(by: parent.view.safeAreaInsets).insetBy(dx: 12, dy: 12)
        let top = area.minY + 56
        frame.size.height = min(frame.height, area.maxY - top)
        frame.origin = CGPoint(x: rect.midX < area.midX ? area.maxX - frame.width : area.minX, y: top)
        parent.addChild(host)
        parent.view.addSubview(self)
        host.didMove(toParent: parent)
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.2) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func close(animated: Bool = true) {
        host.willMove(toParent: nil)
        let finish = { [self] in
            removeFromSuperview()
            host.removeFromParent()
        }
        guard animated else { return finish() }
        UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }, completion: { _ in finish() })
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch gesture.state {
        case .began:
            dragOrigin = frame.origin
        default:
            let t = gesture.translation(in: parent)
            let area = parent.bounds.inset(by: parent.safeAreaInsets)
            frame.origin = CGPoint(x: min(max(dragOrigin.x + t.x, area.minX), area.maxX - frame.width),
                                   y: min(max(dragOrigin.y + t.y, area.minY), area.maxY - frame.height))
        }
    }
}
