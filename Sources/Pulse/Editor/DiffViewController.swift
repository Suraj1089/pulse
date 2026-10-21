import AppKit

/// The diff tab: one changed file, as git sees it, like VS Code's inline diff:
/// the whole file, removed and added lines tinted where they are, and the
/// edited part of a changed line tinted more strongly. A file too long to show
/// whole shows only its changes. git computes the diff in a short-lived
/// process (GitDiffLoader); this view keeps one read-only text view of the
/// result. Line backgrounds, markers and old/new line numbers are drawn for the
/// visible lines only, and colors are layout-manager temporary attributes, so
/// a large diff costs its text and a few bytes a line. Built when the tab is
/// shown, dropped when it closes.
final class DiffViewController: NSViewController {
    var onOpenFile: ((URL, Int?) -> Void)?

    private(set) var target: GitDiffTarget?
    private(set) var diff: GitDiff?
    private let loader = GitDiffLoader()
    private let highlighter = SyntaxHighlighter()
    private var language: Language?

    private let pathLabel = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "")
    private let previousButton = DiffViewController.iconButton("chevron.up", "Previous change")
    private let nextButton = DiffViewController.iconButton("chevron.down", "Next change")
    private let openButton = NSButton(title: "Open File", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private var textView: DiffTextView!

    deinit {
        loader.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = DiffBackgroundView()

        let header = DiffHeaderView()
        pathLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeLabel.font = .systemFont(ofSize: 11)
        modeLabel.textColor = .secondaryLabelColor
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        for button in [previousButton, nextButton] {
            button.target = self
        }
        previousButton.action = #selector(previousChange)
        nextButton.action = #selector(nextChange)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.target = self
        openButton.action = #selector(openFile)
        let refresh = DiffViewController.iconButton("arrow.clockwise", "Refresh")
        refresh.target = self
        refresh.action = #selector(reload)

        let stack = NSStackView(views: [pathLabel, modeLabel, statsLabel, NSView(), previousButton, nextButton, refresh, openButton])
        stack.spacing = 10
        stack.setCustomSpacing(4, after: previousButton)
        stack.setCustomSpacing(4, after: nextButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)

        let textView = DiffTextView.make()
        self.textView = textView
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        notice.font = .systemFont(ofSize: 13)
        notice.textColor = .secondaryLabelColor
        notice.alignment = .center
        notice.isHidden = true

        [header, scrollView, notice].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            notice.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            notice.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
        ])
        view = root
    }

    private static func iconButton(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: nil, action: nil)
        button.isBordered = false
        button.toolTip = label
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    // MARK: Loading

    /// Shows `target`, reloading from git (the file may have changed since).
    func show(_ target: GitDiffTarget) {
        _ = view
        let sameFile = target == self.target
        self.target = target
        language = Language.detect(url: target.fileURL)
        pathLabel.stringValue = target.originalPath.map { "\($0) → \(target.path)" } ?? target.path
        pathLabel.toolTip = target.path
        modeLabel.stringValue = target.staged ? "Staged" : (target.kind == .untracked ? "New file" : "Working tree")
        openButton.isEnabled = target.kind != .deleted
        if !sameFile {
            diff = nil
            statsLabel.stringValue = ""
            textView.show(nil)
            showNotice("Loading…")
        }
        reload()
    }

    @objc func reload() {
        guard let target else { return }
        loader.load(target) { [weak self] result in self?.apply(result) }
    }

    private func apply(_ result: GitDiffLoader.Result) {
        switch result {
        case .failed(let message):
            diff = nil
            textView.show(nil)
            statsLabel.stringValue = ""
            showNotice(message)
        case .diff(let diff):
            let previousTop = scrollView.contentView.bounds.origin
            let keepPosition = self.diff != nil
            statsLabel.attributedStringValue = diff.isBinary && diff.isEmpty ? NSAttributedString() : stats(diff)
            // The text view keeps the only copy of the text; this keeps the per-line data.
            self.diff = diff.isEmpty ? nil : diff.withoutText
            if diff.isBinary && diff.isEmpty {
                textView.show(nil)
                showNotice("Binary file. There is no text diff to show.")
            } else if diff.isEmpty {
                textView.show(nil)
                showNotice("No changes.")
            } else {
                showNotice(nil)
                textView.show(diff)
                highlightVisible()
                if keepPosition {
                    scrollView.contentView.scroll(to: previousTop)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                } else if diff.isWholeFile, let first = diff.changeLines.first {
                    scroll(toLine: first)
                } else {
                    scrollView.contentView.scroll(to: .zero)
                }
            }
        }
        previousButton.isEnabled = !(diff?.changeLines.isEmpty ?? true)
        nextButton.isEnabled = previousButton.isEnabled
    }

    private func showNotice(_ text: String?) {
        notice.stringValue = text ?? ""
        notice.isHidden = text == nil
        scrollView.isHidden = text != nil
    }

    private func stats(_ diff: GitDiff) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let text = NSMutableAttributedString(string: "+\(diff.added)", attributes: [.font: font, .foregroundColor: Theme.gitAdded])
        text.append(NSAttributedString(string: "  −\(diff.removed)", attributes: [.font: font, .foregroundColor: Theme.gitDeleted]))
        let note: String? = diff.isTruncated ? "  (first \(diff.lineCount.formatted()) lines; open the file for the rest)"
            : diff.isWholeFile ? nil : "  (changes only: the file is too long to show whole)"
        if let note {
            text.append(NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }

    // MARK: Highlighting

    @objc private func didScroll() {
        if (textView.textStorage?.length ?? 0) > SyntaxHighlighter.fullPassLimit { highlightVisible() }
    }

    private func highlightVisible() {
        guard let layoutManager = textView.layoutManager, let diff else { return }
        let range = SyntaxHighlighter.rangeToHighlight(textView: textView)
        highlighter.highlight(range: range, in: layoutManager, language: language)
        // Hunk headers and notes read as quiet separators, not code.
        let first = diff.line(containing: range.location)
        let last = diff.line(containing: max(range.location, NSMaxRange(range) - 1))
        guard first <= last else { return }
        for line in first...last where diff.kinds[line] == .hunk || diff.kinds[line] == .note {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.comment, forCharacterRange: diff.range(ofLine: line))
        }
    }

    func applyFontSize() {
        textView.applyFont()
        highlightVisible()
    }

    // MARK: Navigation

    /// A change is scrolled to with three lines of the file above it.
    private var changeOffset: CGFloat {
        3 * (textView.layoutManager?.defaultLineHeight(for: Theme.editorFont) ?? 16)
    }

    /// Index of the diff line `offset` points below the top of the visible area.
    private func line(atVisibleOffset offset: CGFloat) -> Int {
        guard let diff, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 0 }
        let top = scrollView.contentView.bounds.minY - textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(0, top + offset + 1)), in: container)
        return diff.line(containing: layoutManager.characterIndexForGlyph(at: glyph))
    }

    /// Where a change scrolled to sits: next and previous are counted from here.
    private var currentLine: Int { line(atVisibleOffset: changeOffset) }

    @objc private func nextChange() {
        guard let diff else { return }
        let current = currentLine
        if let line = diff.changeLines.first(where: { $0 > current }) { scroll(toLine: line) }
    }

    @objc private func previousChange() {
        guard let diff else { return }
        let current = currentLine
        if let line = diff.changeLines.last(where: { $0 < current }) { scroll(toLine: line) }
    }

    private func scroll(toLine line: Int) {
        guard let diff, diff.lineStarts.indices.contains(line),
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        // Right after new text, non-contiguous layout may not have grown the
        // text view down to the line yet, and the clip view would stop short;
        // scrollRangeToVisible lays out and sizes it first.
        textView.scrollRangeToVisible(NSRange(location: diff.lineStarts[line], length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: diff.lineStarts[line], length: 0), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 1), in: container)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + textView.textContainerOrigin.y - changeOffset)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.needsDisplay = true
        highlightVisible()
    }

    /// Opens the file at the first new-side line in view, or at the top.
    @objc private func openFile() {
        guard let target, target.kind != .deleted else { return }
        var line: Int?
        if let diff, !diff.isEmpty {
            line = (self.line(atVisibleOffset: 0)..<diff.lineCount).lazy.map { Int(diff.newNumbers[$0]) }.first { $0 > 0 }
        }
        onOpenFile?(target.fileURL, line)
    }

    var initialFirstResponder: NSView { textView }

    /// The text view wraps at the visible width, so it is always as wide as the scroll view.
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        if textView.frame.width != width { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
    }
}

/// Read-only text with a gutter of old and new line numbers and +/− markers.
/// Only line fragments in the dirty rect are visited, whatever the diff's size.
final class DiffTextView: NSTextView {
    private(set) var diff: GitDiff?
    private var gutterWidth: CGFloat = 0
    private var digitWidth: CGFloat = 8

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    /// A TextKit 1 stack (non-contiguous layout lays out only what is shown).
    static func make() -> DiffTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        return DiffTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = true
        backgroundColor = Theme.editorBackground
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 0, height: 6)
        textContainer?.lineFragmentPadding = 6
        setAccessibilityLabel("Diff")
        applyFont()
    }

    func applyFont() {
        let font = Theme.editorFont
        typingAttributes = [.font: font, .foregroundColor: Theme.text]
        if let storage = textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        digitWidth = ("8" as NSString).size(withAttributes: [.font: Theme.gutterFont]).width
        updateGutter()
    }

    func show(_ diff: GitDiff?) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.editorFont, .foregroundColor: Theme.text]
        textStorage?.setAttributedString(NSAttributedString(string: diff?.text ?? "", attributes: attributes))
        // The storage now holds the text; keep only the per-line data.
        self.diff = diff?.withoutText
        updateGutter()
        setSelectedRange(NSRange(location: 0, length: 0))
        needsDisplay = true
    }

    /// Two number columns sized to the largest line number, then the marker.
    private func updateGutter() {
        let largest = max(diff?.oldNumbers.max() ?? 0, diff?.newNumbers.max() ?? 0, 99)
        let digits = CGFloat(String(largest).count)
        gutterWidth = (digits * digitWidth + 12) * 2 + 16
        invalidateTextContainerOrigin()
        resizeContainer(to: frame.width)
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: gutterWidth, y: super.textContainerOrigin.y)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeContainer(to: newSize.width)
    }

    private func resizeContainer(to width: CGFloat) {
        // Lines wrap at the visible width, so the gutter never scrolls away.
        let available = max(100, width - gutterWidth)
        if textContainer?.containerSize.width != available {
            textContainer?.containerSize = NSSize(width: available, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let diff, !diff.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        Theme.chromeBackground.setFill()
        NSRect(x: 0, y: rect.minY, width: gutterWidth - 6, height: rect.height).fill()

        let numberAttributes: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let columnWidth = (gutterWidth - 16) / 2
        let containerRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        var edited: (line: Int, range: NSRange?) = (-1, nil)   // once per line, not per wrapped fragment
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = diff.line(containing: character)
            guard diff.kinds.indices.contains(line) else { return }
            let kind = diff.kinds[line]
            let row = NSRect(x: 0, y: fragment.minY + origin.y, width: self.bounds.width, height: fragment.height)
            if let color = DiffTextView.background(for: kind) {
                color.setFill()
                row.fill()
            }
            if kind == .added || kind == .removed {
                if edited.line != line { edited = (line, self.editedRange(of: line, in: diff)) }
                if let range = edited.range {
                    let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                    let part = NSIntersectionRange(range, characters)
                    if part.length > 0 {
                        let partGlyphs = layoutManager.glyphRange(forCharacterRange: part, actualCharacterRange: nil)
                        let box = layoutManager.boundingRect(forGlyphRange: partGlyphs, in: textContainer)
                        (kind == .added ? Theme.diffAddedEdit : Theme.diffRemovedEdit).setFill()
                        NSRect(x: box.minX + origin.x, y: row.minY, width: box.width, height: row.height).fill()
                    }
                }
            }
            // Numbers and the marker go on a line's first fragment only.
            guard character == diff.lineStarts[line] else { return }
            let textY = row.minY + (row.height - Theme.gutterFont.boundingRectForFont.height) / 2
            func number(_ value: Int32, column: Int) {
                guard value > 0 else { return }
                let string = String(value) as NSString
                let width = string.size(withAttributes: numberAttributes).width
                let x = CGFloat(column) * columnWidth + columnWidth - 6 - width
                string.draw(at: NSPoint(x: x, y: textY), withAttributes: numberAttributes)
            }
            number(diff.oldNumbers[line], column: 0)
            number(diff.newNumbers[line], column: 1)
            if let marker = DiffTextView.marker(for: kind) {
                let attributes: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: marker.1]
                (marker.0 as NSString).draw(at: NSPoint(x: columnWidth * 2 + 2, y: textY), withAttributes: attributes)
            }
        }
    }

    /// The part of a changed line that differs from the line it replaced (or
    /// that replaced it), in the text's offsets; nil when it has no such line.
    private func editedRange(of line: Int, in diff: GitDiff) -> NSRange? {
        guard let partner = diff.partner(of: line), let text = textStorage?.string else { return nil }
        return GitDiff.editedRanges(in: text as NSString, diff.range(ofLine: line), diff.range(ofLine: partner))?.0
    }

    private static func background(for kind: GitDiff.LineKind) -> NSColor? {
        switch kind {
        case .added: return Theme.diffAdded
        case .removed: return Theme.diffRemoved
        case .hunk: return Theme.diffHunk
        case .context, .note: return nil
        }
    }

    private static func marker(for kind: GitDiff.LineKind) -> (String, NSColor)? {
        switch kind {
        case .added: return ("+", Theme.gitAdded)
        case .removed: return ("−", Theme.gitDeleted)
        default: return nil
        }
    }
}

/// Layer-backed backgrounds (no backing store), in the editor's colors.
private final class DiffBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.editorBackground.cgColor }
}

private final class DiffHeaderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.chromeBackground.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
