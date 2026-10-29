import UIKit

/// A to-do list edited right on the page: tap a box to tick it, type straight into the rows.
final class ChecklistView: UIView, UITextFieldDelegate {
    static let width: CGFloat = 380
    private(set) var list: Checklist
    private let ink: UIColor
    /// Saves the list, or removes it when nil (emptied out).
    var onSave: ((Checklist?, String) -> Void)?
    /// Typing started or stopped; the canvas keeps this view alive in between.
    var onEditing: ((Bool) -> Void)?
    private(set) var isEditingList = false

    private let titleField = Field()
    private let more = UIButton(type: .system)
    private let add = UIButton(type: .system)
    private var rows: [Row] = []
    private var dragging: (row: Row, startY: CGFloat)?

    private var rowHeight: CGFloat { list.fontSize * 1.75 }
    private var titleHeight: CGFloat { list.fontSize * 1.9 }
    private var addHeight: CGFloat { list.fontSize * 1.4 }

    init(list: Checklist, ink: UIColor) {
        self.list = list
        self.ink = ink
        super.init(frame: .zero)
        titleField.font = NoteCanvasView.typingFont(list.fontSize * 1.1).withWeight(.bold)
        titleField.textColor = ink
        titleField.text = list.title
        titleField.attributedPlaceholder = NSAttributedString(string: "To Do", attributes: [.foregroundColor: ink.withAlphaComponent(0.35)])
        titleField.returnKeyType = .next
        titleField.delegate = self
        addSubview(titleField)

        more.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        more.tintColor = ink.withAlphaComponent(0.45)
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIAction(title: "Clear Ticked", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                guard let self else { return }
                self.list.items.removeAll { $0.done }
                self.onSave?(self.list, "Clear Ticked")
            },
            UIAction(title: "Delete List", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.onSave?(nil, "Delete List")
            },
        ])
        addSubview(more)
        add.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: list.fontSize * 0.7)), for: .normal)
        add.setTitle(" Add item", for: .normal)
        add.titleLabel?.font = NoteCanvasView.typingFont(list.fontSize * 0.7)
        add.tintColor = ink.withAlphaComponent(0.4)
        add.contentHorizontalAlignment = .leading
        add.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let item = ChecklistItem(text: "")
            self.list.items.append(item)
            self.rows.append(self.makeRow(item))
            self.layout()
            self.onSave?(self.list, "Add Item")
        }, for: .touchUpInside)
        addSubview(add)
        rows = list.items.map(makeRow)
        layout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeRow(_ item: ChecklistItem) -> Row {
        let row = Row(id: item.id)
        row.box.addAction(UIAction { [weak self, weak row] _ in
            guard let self, let row, let i = self.index(of: row) else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            self.list.items[i].done.toggle()
            self.style(row, done: self.list.items[i].done)
            self.onSave?(self.list, self.list.items[i].done ? "Tick" : "Untick")
        }, for: .touchUpInside)
        row.field.font = NoteCanvasView.typingFont(list.fontSize)
        row.field.text = item.text
        row.field.returnKeyType = .next
        row.field.delegate = self
        row.field.addAction(UIAction { [weak self, weak row] _ in
            guard let self, let row, let i = self.index(of: row) else { return }
            self.list.items[i].text = row.field.text ?? ""
        }, for: .editingChanged)
        row.field.onEmptyBackspace = { [weak self, weak row] in
            guard let self, let row, let i = self.index(of: row) else { return }
            self.removeRow(at: i)
        }
        row.handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(reorder(_:))))
        style(row, done: item.done)
        addSubview(row)
        return row
    }

    private func style(_ row: Row, done: Bool) {
        let size = list.fontSize * 0.9
        row.box.setImage(UIImage(systemName: done ? "checkmark.square.fill" : "square",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: size)), for: .normal)
        row.box.tintColor = done ? Theme.uiAccent : ink
        row.field.textColor = done ? ink.withAlphaComponent(0.45) : ink
        // a line through the row crosses out handwriting as well as typing
        row.strike.backgroundColor = ink.withAlphaComponent(0.55)
        row.strike.isHidden = !done
        row.handle.tintColor = ink.withAlphaComponent(0.3)
        row.handle.image = UIImage(systemName: "line.3.horizontal", withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.7))
    }

    private func index(of row: Row) -> Int? {
        list.items.firstIndex { $0.id == row.id }
    }

    private func layout() {
        let width = Self.width
        titleField.frame = CGRect(x: 0, y: 0, width: width - 40, height: titleHeight)
        more.frame = CGRect(x: width - 36, y: 0, width: 36, height: titleHeight)
        for (i, row) in rows.enumerated() where row !== dragging?.row {
            row.frame = CGRect(x: 0, y: titleHeight + CGFloat(i) * rowHeight, width: width, height: rowHeight)
        }
        let bottom = titleHeight + CGFloat(rows.count) * rowHeight
        add.frame = CGRect(x: 0, y: bottom, width: 160, height: addHeight)
        let origin = frame.origin == .zero ? list.origin : frame.origin
        frame = CGRect(origin: origin, size: CGSize(width: width, height: bottom + addHeight))
    }

    private func insertRow(after i: Int) {
        let item = ChecklistItem(text: "")
        list.items.insert(item, at: i + 1)
        rows.insert(makeRow(item), at: i + 1)
        layout()
        rows[i + 1].field.becomeFirstResponder()
    }

    private func removeRow(at i: Int) {
        // keep focus inside the list so editing doesn't end in between
        if i > 0 { rows[i - 1].field.becomeFirstResponder() } else { titleField.becomeFirstResponder() }
        list.items.remove(at: i)
        rows.remove(at: i).removeFromSuperview()
        layout()
    }

    @objc private func reorder(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view, let row = handle.superview as? Row else { return }
        switch gesture.state {
        case .began:
            dragging = (row, row.frame.minY)
            bringSubviewToFront(row)
            row.alpha = 0.8
        case .changed:
            guard let dragging else { return }
            row.frame.origin.y = dragging.startY + gesture.translation(in: self).y
        default:
            guard let from = index(of: row) else { return }
            let to = min(max(Int(((row.frame.midY - titleHeight) / rowHeight).rounded(.down)), 0), rows.count - 1)
            dragging = nil
            row.alpha = 1
            list.items.insert(list.items.remove(at: from), at: to)
            rows.insert(rows.remove(at: from), at: to)
            UIView.animate(withDuration: 0.2) { self.layout() }
            if from != to { onSave?(list, "Reorder List") }
        }
    }

    // Typing

    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard !isEditingList else { return }
        isEditingList = true
        onEditing?(true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === titleField {
            if rows.isEmpty { insertRow(after: -1) } else { rows[0].field.becomeFirstResponder() }
        } else if let i = rows.firstIndex(where: { $0.field === textField }) {
            insertRow(after: i)
        }
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        // focus hops between rows; only leaving the list altogether finishes
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditingList, !self.containsFirstResponder else { return }
            self.isEditingList = false
            // taken off the page (deleted, or the page changed) rather than finished
            guard self.superview != nil else { return }
            self.list.title = self.titleField.text?.trimmingCharacters(in: .whitespaces) ?? ""
            // blank rows stay, they may be handwritten in
            self.onEditing?(false)
            let empty = self.list.title.isEmpty && self.list.items.isEmpty
            self.onSave?(empty ? nil : self.list, empty ? "Delete List" : "Edit To-Do List")
        }
    }

    /// The pencil writes straight over the list as ink; only the boxes and buttons take it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard event?.allTouches?.contains(where: { $0.type == .pencil }) == true else { return super.hitTest(point, with: event) }
        let controls = rows.flatMap { [$0.box, $0.handle] } + [more, add]
        return controls.first { $0.convert($0.bounds, to: self).contains(point) && !$0.isHidden }
    }

    private var containsFirstResponder: Bool {
        titleField.isFirstResponder || rows.contains { $0.field.isFirstResponder }
    }

    final class Field: UITextField {
        var onEmptyBackspace: (() -> Void)?

        override func deleteBackward() {
            if text?.isEmpty ?? true { onEmptyBackspace?() }
            super.deleteBackward()
        }
    }

    final class Row: UIView {
        let id: UUID
        let box = UIButton(type: .custom)
        let field = Field()
        let handle = UIImageView()
        let strike = UIView()

        init(id: UUID) {
            self.id = id
            super.init(frame: .zero)
            handle.isUserInteractionEnabled = true
            handle.contentMode = .center
            strike.isUserInteractionEnabled = false
            [box, field, handle, strike].forEach(addSubview)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let h = bounds.height
            box.frame = CGRect(x: 0, y: 0, width: h, height: h)
            handle.frame = CGRect(x: bounds.width - h, y: 0, width: h, height: h)
            field.frame = CGRect(x: h + 4, y: 0, width: bounds.width - h * 2 - 8, height: h)
            strike.frame = CGRect(x: h + 2, y: h / 2 - 1, width: bounds.width - h * 2 - 4, height: 2)
        }
    }
}
