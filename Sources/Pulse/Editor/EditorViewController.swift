import AppKit

/// Tabs, the one text view, the terminal split and the status bar.
///
/// Memory design: there is exactly one `CodeTextView` and one layout
/// manager. Switching tabs swaps the layout manager onto another document's
/// text storage, so each extra open file costs roughly its own text.
final class EditorViewController: NSViewController, NSTextViewDelegate {
    /// Large but finite. `CGFloat.greatestFiniteMagnitude` makes every line
    /// fragment ~1e308 pt wide, which breaks glyph drawing.
    private static let unbounded: CGFloat = 10_000_000

    var onActiveDocumentChange: ((Document?) -> Void)?
    var onSessionChange: (() -> Void)?
    var onDidSave: ((Document) -> Void)?
    var onOpenRequest: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private(set) var documents: [Document] = []
    private(set) var activeIndex: Int?
    var activeDocument: Document? { activeIndex.map { documents[$0] } }
    var terminalDirectory: URL?

    let statusBar = StatusBarView()
    private let tabBar = TabBarView()
    private let split = NSSplitView()
    private let editorArea = NSView()
    private let scrollView = EditorScrollView()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: NSSize(width: EditorViewController.unbounded, height: EditorViewController.unbounded))
    private let emptyStorage = NSTextStorage()
    private(set) var textView: CodeTextView!
    private var ruler: LineNumberRuler!
    private let emptyState = EmptyStateView()
    private let terminal = TerminalPanel()
    /// Views of the open special tabs, one per kind: built when first shown,
    /// kept while the tab is open (so switching keeps their state), dropped
    /// when the tab closes. Only the active one is in the view hierarchy.
    private var specialControllers: [Document.Special: NSViewController] = [:]
    private let highlighter = SyntaxHighlighter()
    private var highlightWork: DispatchWorkItem?
    private var autosaveWork: DispatchWorkItem?

    var isTerminalVisible: Bool { terminal.superview != nil }

    static var autosaveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autosave") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "autosave")
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }

    static var wrapLines: Bool {
        get { UserDefaults.standard.bool(forKey: "wrapLines") }
        set { UserDefaults.standard.set(newValue, forKey: "wrapLines") }
    }

    // MARK: View setup

    override func loadView() {
        let root = NSView()

        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(textContainer)
        emptyStorage.addLayoutManager(layoutManager)

        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        configure(textView)
        self.textView = textView

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.findBarPosition = .aboveContent
        scrollView.frame = editorArea.bounds
        scrollView.autoresizingMask = [.width, .height]
        editorArea.addSubview(scrollView)

        ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        emptyState.frame = editorArea.bounds
        emptyState.autoresizingMask = [.width, .height]
        emptyState.onOpen = { [weak self] in self?.onOpenRequest?() }
        emptyState.onNewFile = { [weak self] in self?.newDocument() }
        emptyState.onOpenRecent = { [weak self] url in self?.onOpenRecent?(url) }
        editorArea.addSubview(emptyState)

        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(editorArea)

        tabBar.onSelect = { [weak self] index in self?.activate(index) }
        tabBar.onClose = { [weak self] index in _ = self?.closeDocument(at: index) }

        [tabBar, split, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            split.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        view = root

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        applyWrap()
        refreshChrome()
    }

    private func configure(_ textView: CodeTextView) {
        textView.minSize = .zero
        textView.maxSize = NSSize(width: EditorViewController.unbounded, height: EditorViewController.unbounded)
        textView.isVerticallyResizable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFontPanel = false
        textView.drawsBackground = true
        textView.backgroundColor = Theme.editorBackground
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.typingAttributes = Document.baseAttributes
        textView.delegate = self
        textView.setAccessibilityLabel("Editor")
    }

    // MARK: Word wrap

    func applyWrap() {
        let wrap = EditorViewController.wrapLines
        // First: the scroller change below retiles, and a tile while wrapping
        // sizes the text view and its container (see EditorScrollView.tile).
        scrollView.wrapsLines = wrap
        textView.autoresizingMask = []
        textView.isHorizontallyResizable = !wrap
        textContainer.widthTracksTextView = wrap
        if !wrap {
            textContainer.containerSize = NSSize(width: EditorViewController.unbounded, height: EditorViewController.unbounded)
        }
        scrollView.hasHorizontalScroller = !wrap
        scrollView.tile()
    }

    func toggleWrap() {
        EditorViewController.wrapLines.toggle()
        applyWrap()
        ruler.needsDisplay = true
    }

    // MARK: Documents

    func open(_ url: URL, select range: NSRange? = nil) {
        if let index = documents.firstIndex(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
            activate(index)
        } else {
            do {
                add(try Document.open(url))
            } catch {
                _ = presentError(error)
                return
            }
        }
        if let range { reveal(range) }
    }

    /// Opens (or switches to) a special tab such as Keyboard Shortcuts.
    func openSpecial(_ kind: Document.Special) {
        if let index = documents.firstIndex(where: { $0.special == kind }) {
            activate(index)
        } else {
            add(Document(special: kind))
        }
    }

    func newDocument() {
        add(Document(url: nil, text: ""))
        view.window?.makeFirstResponder(textView)
    }

    func add(_ document: Document, activate shouldActivate: Bool = true) {
        document.onDirtyChange = { [weak self] in self?.refreshTabs() }
        // New tabs open next to the current one; restored tabs keep their order.
        let position = shouldActivate ? (activeIndex.map { $0 + 1 } ?? documents.count) : documents.count
        documents.insert(document, at: position)
        if shouldActivate || activeIndex == nil {
            activate(position)
        } else if let active = activeIndex, active >= position {
            activeIndex = active + 1
            refreshTabs()
        }
        onSessionChange?()
    }

    func activate(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        rememberViewState()
        activeIndex = index
        let document = documents[index]
        layoutManager.replaceTextStorage(document.storage)
        textView.typingAttributes = Document.baseAttributes
        textView.lineComment = document.language?.lineComment
        ruler.document = document
        ruler.updateThickness()
        let length = document.length
        let selection = NSRange(location: min(document.selectedRange.location, length),
                                length: min(document.selectedRange.length, length - min(document.selectedRange.location, length)))
        textView.setSelectedRange(selection)
        scrollView.visibleTextOrigin = document.scrollPoint
        textView.needsDisplay = true
        highlightNow()
        refreshChrome()
        view.window?.makeFirstResponder(document.special == nil ? textView : (specialControllers[.keyboardShortcuts] as? ShortcutsEditor)?.initialFirstResponder)
        onActiveDocumentChange?(document)
        onSessionChange?()
    }

    private func rememberViewState() {
        guard let document = activeDocument else { return }
        document.selectedRange = textView.selectedRange()
        document.scrollPoint = scrollView.visibleTextOrigin
    }

    /// Returns false when the user cancelled.
    @discardableResult
    func closeDocument(at index: Int) -> Bool {
        guard documents.indices.contains(index) else { return true }
        let document = documents[index]
        if document.isDirty {
            if document.url != nil && EditorViewController.autosaveEnabled {
                guard save(document) else { return false }
            } else {
                let alert = NSAlert()
                alert.messageText = "Save changes to “\(document.displayName)”?"
                alert.informativeText = "Your changes will be lost if you don’t save them."
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Don’t Save")
                switch alert.runModal() {
                case .alertFirstButtonReturn: guard save(document) else { return false }
                case .alertSecondButtonReturn: return false
                default: break
                }
            }
        }
        documents.remove(at: index)
        if let kind = document.special, let controller = specialControllers.removeValue(forKey: kind) {
            controller.view.removeFromSuperview()
        }
        if documents.isEmpty {
            activeIndex = nil
            layoutManager.replaceTextStorage(emptyStorage)
            ruler.document = nil
            refreshChrome()
            onActiveDocumentChange?(nil)
        } else if let active = activeIndex {
            if index == active {
                activeIndex = nil
                activate(min(index, documents.count - 1))
            } else if index < active {
                activeIndex = active - 1
                refreshTabs()
            } else {
                refreshTabs()
            }
        }
        onSessionChange?()
        return true
    }

    func closeActive() {
        if let index = activeIndex { closeDocument(at: index) } else { view.window?.performClose(nil) }
    }

    func selectTab(offset: Int) {
        guard let active = activeIndex, !documents.isEmpty else { return }
        activate((active + offset + documents.count) % documents.count)
    }

    // MARK: Saving

    @discardableResult
    func save(_ document: Document, as forceDialog: Bool = false) -> Bool {
        if document.special != nil { return true }
        var target = document.url
        if target == nil || forceDialog {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = document.displayName
            if let directory = document.url?.deletingLastPathComponent() ?? terminalDirectory {
                panel.directoryURL = directory
            }
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            target = url
        }
        do {
            try document.save(to: target)
        } catch {
            _ = presentError(error)
            return false
        }
        if document === activeDocument {
            textView.lineComment = document.language?.lineComment
            highlightNow()
            refreshChrome()
            onActiveDocumentChange?(document)
        }
        onSessionChange?()
        onDidSave?(document)
        return true
    }

    func saveActive(as forceDialog: Bool = false) {
        if let document = activeDocument { save(document, as: forceDialog) }
    }

    func saveAll() {
        for document in documents where document.isDirty { save(document) }
    }

    /// Writes every modified file that already has a path. Untitled buffers
    /// are kept by session recovery instead.
    func saveNamedDocuments() {
        for document in documents where document.isDirty && document.url != nil {
            if (try? document.save()) != nil { onDidSave?(document) }
        }
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        guard EditorViewController.autosaveEnabled else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNamedDocuments() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func reloadChangedDocuments() {
        for document in documents where document.reloadIfChangedOnDisk() {
            if document === activeDocument {
                ruler.updateThickness()
                ruler.needsDisplay = true
                highlightNow()
                updateStatus()
            }
        }
    }

    // MARK: Editing commands

    func reveal(_ range: NSRange) {
        let length = (textView.string as NSString).length
        let safe = NSRange(location: min(range.location, length), length: min(range.length, length - min(range.location, length)))
        textView.setSelectedRange(safe)
        textView.scrollRangeToVisible(safe)
        textView.centerSelectionInVisibleArea(nil)
        if safe.length > 0 { textView.showFindIndicator(for: safe) }
        view.window?.makeFirstResponder(textView)
    }

    func reveal(line: Int, column: Int, length: Int) {
        guard let document = activeDocument else { return }
        let start = document.start(ofLine: line - 1) + column
        reveal(NSRange(location: start, length: length))
    }

    func goToLine(_ number: Int) {
        guard let document = activeDocument else { return }
        textView.goToLine(number, in: document)
        view.window?.makeFirstResponder(textView)
    }

    /// Re-applies the editor size from Theme to every open document.
    func applyEditorFontSize() {
        documents.forEach { $0.applyFont() }
        textView.typingAttributes = Document.baseAttributes
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    var selectedText: String? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    // MARK: Terminal

    func toggleTerminal() {
        isTerminalVisible ? hideTerminal() : showTerminal()
    }

    func showTerminal() {
        if !isTerminalVisible {
            split.addArrangedSubview(terminal)
            split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
            split.layoutSubtreeIfNeeded()
            split.setPosition(max(120, split.bounds.height - 240), ofDividerAt: 0)
        }
        terminal.startIfNeeded(in: terminalDirectory)
        terminal.focus()
        onSessionChange?()
    }

    func hideTerminal() {
        guard isTerminalVisible else { return }
        split.removeArrangedSubview(terminal)
        terminal.removeFromSuperview()
        view.window?.makeFirstResponder(textView)
        onSessionChange?()
    }

    func applyTerminalFontSize() {
        terminal.applyFontSize()
    }

    /// True when `view` is the terminal or inside it (for focus-aware ⌘+ / ⌘−).
    func terminalContains(_ view: NSView) -> Bool {
        view.isDescendant(of: terminal)
    }

    func killTerminal() {
        terminal.kill()
        hideTerminal()
    }

    // MARK: Chrome

    func setRecents(_ urls: [URL]) {
        emptyState.setRecents(urls)
    }

    private func refreshChrome() {
        let hasDocument = activeDocument != nil
        let special = activeDocument?.special
        emptyState.isHidden = hasDocument
        scrollView.isHidden = !hasDocument || special != nil
        showSpecial(special)
        refreshTabs()
        updateStatus()
    }

    private func showSpecial(_ kind: Document.Special?) {
        // Only the active special view is on screen; the others keep their state.
        for (other, controller) in specialControllers where other != kind {
            controller.view.removeFromSuperview()
        }
        guard let kind else { return }
        let controller: NSViewController
        if let existing = specialControllers[kind] {
            controller = existing
        } else {
            switch kind {
            case .keyboardShortcuts: controller = ShortcutsEditor()
            case .welcome: controller = WelcomeController()
            }
            specialControllers[kind] = controller
        }
        if controller.view.superview !== editorArea {
            controller.view.frame = editorArea.bounds
            controller.view.autoresizingMask = [.width, .height]
            editorArea.addSubview(controller.view)
        }
    }

    private func refreshTabs() {
        tabBar.update(
            tabs: documents.map { TabInfo(title: $0.displayName, tooltip: $0.url?.path, isDirty: $0.isDirty) },
            selected: activeIndex
        )
    }

    private func updateStatus() {
        guard let document = activeDocument, document.special == nil else {
            statusBar.showDocument(languageName: nil, visible: false)
            return
        }
        let selection = textView.selectedRange()
        let line = document.line(at: selection.location)
        let column = selection.location - document.start(ofLine: line) + 1
        statusBar.showPosition(line: line + 1, column: column, selected: selection.length)
        statusBar.showDocument(languageName: document.language?.name, visible: true)
    }

    // MARK: Highlighting

    private func scheduleHighlight(after delay: TimeInterval = 0.08) {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlightNow() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func highlightNow() {
        highlightWork?.cancel()
        guard let document = activeDocument else { return }
        let range = SyntaxHighlighter.rangeToHighlight(textView: textView)
        highlighter.highlight(range: range, in: layoutManager, language: document.language)
    }

    @objc private func didScroll() {
        ruler.needsDisplay = true
        if (activeDocument?.length ?? 0) > SyntaxHighlighter.fullPassLimit { scheduleHighlight(after: 0.05) }
    }

    private func colorSample() -> String {
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return "none" }
        return String(describing: storage.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }

    /// Prints text-view geometry; used by scripts/screenshot.sh in CI.
    func dumpLayout() {
        layoutManager.ensureLayout(for: textContainer)
        let lines = [
            "storage length: \(layoutManager.textStorage?.length ?? -1), glyphs: \(layoutManager.numberOfGlyphs)",
            "textView frame: \(textView.frame), hidden: \(textView.isHidden), superview: \(String(describing: textView.superview))",
            "visibleRect: \(textView.visibleRect), clip bounds: \(scrollView.contentView.bounds)",
            "container size: \(textContainer.size), usedRect: \(layoutManager.usedRect(for: textContainer))",
            "first fragment: \(layoutManager.numberOfGlyphs > 0 ? layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil) : .zero)",
            "scrollView hidden: \(scrollView.isHidden), frame: \(scrollView.frame), emptyState hidden: \(emptyState.isHidden)",
            "text color sample: \(colorSample())",
        ]
        print("PULSE_LAYOUT " + lines.joined(separator: "\nPULSE_LAYOUT "))
        func describe(_ view: NSView, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            print("PULSE_VIEWS \(pad)\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) layer=\(view.layer != nil) opaque=\(view.isOpaque)")
            if depth < 6 { view.subviews.forEach { describe($0, depth: depth + 1) } }
        }
        describe(scrollView, depth: 0)
        if let directory = ProcessInfo.processInfo.environment["PULSE_DEBUG_DIR"] {
            let targets: [(String, NSView)] = [("textview", textView), ("scrollview", scrollView)]
            for (name, target) in targets {
                let rect = name == "textview" ? target.visibleRect : target.bounds
                guard let rep = target.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                target.cacheDisplay(in: rect, to: rep)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("debug-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        fflush(stdout)
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        activeDocument?.undoManager
    }

    func textDidChange(_ notification: Notification) {
        guard let document = activeDocument, document.special == nil else { return }
        document.invalidateLines()
        document.isDirty = true
        ruler.updateThickness()
        ruler.needsDisplay = true
        scheduleHighlight()
        scheduleAutosave()
        updateStatus()
        onSessionChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        ruler.needsDisplay = true
        updateStatus()
    }
}
