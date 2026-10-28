import UIKit

/// Renders the Markdown subset typed text supports: headings, bullets, checklists, quotes,
/// plus inline bold, italic, code, strikethrough and links.
enum Markdown {
    static func render(_ source: String, size: CGFloat, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = source.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            var line = Substring(raw)
            var font = base(size, weight: .regular)
            var lineColor = color
            var prefix = ""
            if line.hasPrefix("### ") {
                line = line.dropFirst(4)
                font = base(size * 1.15, weight: .bold)
            } else if line.hasPrefix("## ") {
                line = line.dropFirst(3)
                font = base(size * 1.35, weight: .bold)
            } else if line.hasPrefix("# ") {
                line = line.dropFirst(2)
                font = base(size * 1.65, weight: .heavy)
            } else if line.hasPrefix("- [ ] ") {
                line = line.dropFirst(6)
                prefix = "\u{2610}  "
            } else if line.lowercased().hasPrefix("- [x] ") {
                line = line.dropFirst(6)
                prefix = "\u{2611}  "
                lineColor = color.withAlphaComponent(0.55)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = line.dropFirst(2)
                prefix = "\u{2022}  "
            } else if line.hasPrefix("> ") {
                line = line.dropFirst(2)
                prefix = "\u{258F} "
                lineColor = color.withAlphaComponent(0.65)
                font = italic(font)
            }
            if !prefix.isEmpty {
                result.append(NSAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: lineColor]))
            }
            result.append(inline(String(line), font: font, color: lineColor))
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }
        return result
    }

    /// Web links written as [text](url) or bare URLs.
    static func links(in source: String) -> [URL] {
        var found: [URL] = []
        for line in source.components(separatedBy: "\n") {
            guard let parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { continue }
            for run in parsed.runs {
                if let link = run.link, !found.contains(link) { found.append(link) }
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let url = match.url, !found.contains(url) { found.append(url) }
            }
        }
        return found
    }

    private static func base(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let rounded = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: rounded, size: size)
    }

    private static func italic(_ font: UIFont) -> UIFont {
        guard let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return font }
        return UIFont(descriptor: d, size: font.pointSize)
    }

    private static func inline(_ line: String, font: UIFont, color: UIColor) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var runFont = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                    attrs[.backgroundColor] = UIColor(white: 0.5, alpha: 0.14)
                }
                if intent.contains(.strikethrough) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if !traits.isEmpty,
                   let d = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits)) {
                    runFont = UIFont(descriptor: d, size: runFont.pointSize)
                }
            }
            if run.link != nil {
                attrs[.foregroundColor] = Theme.uiAccent
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attrs[.font] = runFont
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }
}

/// Multi-line Markdown editor with a formatting bar, presented as a sheet.
final class TextBoxEditor: UIViewController, UITextViewDelegate {
    private let textView = UITextView()
    private let preview = UILabel()
    private let initial: String
    private let onDone: (String) -> Void

    init(text: String, title: String, onDone: @escaping (String) -> Void) {
        initial = text
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func present(from presenter: UIViewController, text: String, title: String, onDone: @escaping (String) -> Void) {
        let nav = UINavigationController(rootViewController: TextBoxEditor(text: text, title: title, onDone: onDone))
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = CGSize(width: 620, height: 640)
        presenter.present(nav, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Theme.paper)
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let text = self.textView.text ?? ""
            self.dismiss(animated: true)
            self.onDone(text)
        })

        textView.text = initial
        textView.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        textView.backgroundColor = UIColor(Theme.raised)
        textView.layer.cornerRadius = 14
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        textView.delegate = self

        preview.numberOfLines = 0
        let previewBox = UIScrollView()
        previewBox.backgroundColor = UIColor(Theme.raised)
        previewBox.layer.cornerRadius = 14
        previewBox.addSubview(preview)

        let bar = UIStackView(arrangedSubviews: formatButtons())
        bar.axis = .horizontal
        bar.spacing = 6
        bar.distribution = .fillEqually

        let caption = UILabel()
        caption.text = "Preview"
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        caption.textColor = UIColor(Theme.muted)

        let stack = UIStackView(arrangedSubviews: [bar, textView, caption, previewBox])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: 38),
            textView.heightAnchor.constraint(equalTo: previewBox.heightAnchor, multiplier: 1.3),
            preview.leadingAnchor.constraint(equalTo: previewBox.contentLayoutGuide.leadingAnchor, constant: 14),
            preview.topAnchor.constraint(equalTo: previewBox.contentLayoutGuide.topAnchor, constant: 12),
            preview.bottomAnchor.constraint(equalTo: previewBox.contentLayoutGuide.bottomAnchor, constant: -12),
            preview.widthAnchor.constraint(equalTo: previewBox.frameLayoutGuide.widthAnchor, constant: -28),
        ])
        updatePreview()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        updatePreview()
    }

    private func updatePreview() {
        preview.attributedText = Markdown.render(textView.text ?? "", size: 20, color: UIColor(Theme.ink))
    }

    private func formatButtons() -> [UIButton] {
        let actions: [(String, () -> Void)] = [
            ("bold", { [weak self] in self?.wrap("**") }),
            ("italic", { [weak self] in self?.wrap("*") }),
            ("strikethrough", { [weak self] in self?.wrap("~~") }),
            ("chevron.left.forwardslash.chevron.right", { [weak self] in self?.wrap("`") }),
            ("textformat.size", { [weak self] in self?.prefixLines("# ") }),
            ("list.bullet", { [weak self] in self?.prefixLines("- ") }),
            ("checklist", { [weak self] in self?.prefixLines("- [ ] ") }),
            ("text.quote", { [weak self] in self?.prefixLines("> ") }),
            ("link", { [weak self] in self?.insertLink() }),
        ]
        return actions.map { symbol, action in
            var config = UIButton.Configuration.filled()
            config.image = UIImage(systemName: symbol)
            config.baseBackgroundColor = UIColor(Theme.raised)
            config.baseForegroundColor = UIColor(Theme.ink)
            config.cornerStyle = .medium
            return UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        }
    }

    /// Wraps the selection in a marker, or inserts an empty pair at the cursor.
    private func wrap(_ marker: String) {
        let range = textView.selectedRange
        let text = textView.text as NSString? ?? ""
        let selected = text.substring(with: range)
        textView.textStorage.replaceCharacters(in: range, with: marker + selected + marker)
        textView.selectedRange = NSRange(location: range.location + marker.count, length: selected.utf16.count)
        updatePreview()
    }

    /// Adds a prefix to each selected line, or removes it if every line already has it.
    private func prefixLines(_ prefix: String) {
        let text = textView.text as NSString? ?? ""
        let lineRange = text.lineRange(for: textView.selectedRange)
        let lines = text.substring(with: lineRange).components(separatedBy: "\n")
        let body = lines.last == "" ? Array(lines.dropLast()) : lines
        let removing = body.allSatisfy { $0.hasPrefix(prefix) }
        var changed = body.map { removing ? String($0.dropFirst(prefix.count)) : prefix + $0 }.joined(separator: "\n")
        if lines.last == "" { changed += "\n" }
        textView.textStorage.replaceCharacters(in: lineRange, with: changed)
        textView.selectedRange = NSRange(location: lineRange.location, length: changed.utf16.count)
        updatePreview()
    }

    private func insertLink() {
        let range = textView.selectedRange
        let text = textView.text as NSString? ?? ""
        let selected = text.substring(with: range)
        let label = selected.isEmpty ? "link" : selected
        let snippet = "[\(label)](https://)"
        textView.textStorage.replaceCharacters(in: range, with: snippet)
        // leave the cursor inside the URL
        textView.selectedRange = NSRange(location: range.location + label.utf16.count + 3 + 8, length: 0)
        updatePreview()
    }
}
