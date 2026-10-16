import AppKit

/// One editor group, like VS Code's: its own tabs, path bar, text view and
/// gutter. A window starts with one; Split Editor Right / Down adds another
/// beside the active one (EditorViewController arranges them).
///
/// Memory design: a pane has one `CodeTextView` and one layout manager, and
/// switching its tabs moves that layout manager onto another document's
/// text storage. A file open in two panes keeps one text storage (one copy
/// of the text, one undo history) with a layout manager per pane, so a
/// split costs a text view plus the layout of what it shows, and closing
/// the pane gives that back.
final class EditorPane: NSView {
    /// Large but finite. `CGFloat.greatestFiniteMagnitude` makes every line
    /// fragment ~1e308 pt wide, which breaks glyph drawing.
    static let unbounded: CGFloat = 10_000_000

    struct ViewState {
        var selection: NSRange
        var scroll: NSPoint
    }

    let tabBar = TabBarView()
    let breadcrumbs = BreadcrumbBar()
    /// Holds the scroll view, a special tab's view, or the empty state.
    let editorArea = NSView()
    let scrollView: EditorScrollView
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer
    let textView: CodeTextView
    let ruler: LineNumberRuler
    private let emptyStorage: NSTextStorage
    private var breadcrumbHeight: NSLayoutConstraint!

    /// This pane's tabs; the same document may also be open in another pane.
    var documents: [Document] = []
    var activeIndex: Int?
    var activeDocument: Document? { activeIndex.map { documents[$0] } }
    var highlightWork: DispatchWorkItem?
    /// Each file's caret and scroll position in this pane.
    private var viewStates: [ObjectIdentifier: ViewState] = [:]

    init(delegate: NSTextViewDelegate) {
        // Container in a layout manager on a storage first, then the view.
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: EditorPane.unbounded, height: EditorPane.unbounded))
        layoutManager.addTextContainer(container)
        let emptyStorage = NSTextStorage()
        emptyStorage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        EditorPane.configure(textView)
        let scrollView = EditorScrollView()
        scrollView.documentView = textView
        self.layoutManager = layoutManager
        self.emptyStorage = emptyStorage
        textContainer = container
        self.textView = textView
        self.scrollView = scrollView
        ruler = LineNumberRuler(textView: textView)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        textView.delegate = delegate

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
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        [tabBar, breadcrumbs, editorArea].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        breadcrumbHeight = breadcrumbs.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            breadcrumbs.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            breadcrumbs.leadingAnchor.constraint(equalTo: leadingAnchor),
            breadcrumbs.trailingAnchor.constraint(equalTo: trailingAnchor),
            breadcrumbHeight,
            editorArea.topAnchor.constraint(equalTo: breadcrumbs.bottomAnchor),
            editorArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            editorArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func configure(_ textView: CodeTextView) {
        textView.minSize = .zero
        textView.maxSize = NSSize(width: EditorPane.unbounded, height: EditorPane.unbounded)
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
        textView.setAccessibilityLabel("Editor")
    }

    // MARK: Showing a document

    /// Shows `document` (nil: nothing), with this pane's caret and scroll
    /// position for it (the document's own for a file new to this pane).
    func show(_ document: Document?) {
        attach(document?.storage ?? emptyStorage)
        ruler.document = document
        ruler.updateThickness()
        guard let document else { return }
        textView.typingAttributes = Document.baseAttributes
        textView.lineComment = document.language?.lineComment
        let state = viewState(for: document)
        let length = document.length
        let location = min(state.selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(state.selection.length, length - location)))
        scrollView.visibleTextOrigin = state.scroll
        textView.needsDisplay = true
    }

    /// `replaceTextStorage` would move every layout manager on the old
    /// storage, including another pane's showing the same file, so a shared
    /// storage is left by this pane's layout manager alone.
    private func attach(_ storage: NSTextStorage) {
        guard let current = layoutManager.textStorage else {
            storage.addLayoutManager(layoutManager)
            return
        }
        guard current !== storage else { return }
        if current.layoutManagers.count > 1 {
            current.removeLayoutManager(layoutManager)
            storage.addLayoutManager(layoutManager)
        } else {
            layoutManager.replaceTextStorage(storage)
        }
    }

    /// Lets go of the shown document's storage (the pane is closing), so
    /// edits there no longer lay out text for it.
    func detach() {
        highlightWork?.cancel()
        layoutManager.textStorage?.removeLayoutManager(layoutManager)
    }

    func viewState(for document: Document) -> ViewState {
        viewStates[ObjectIdentifier(document)] ?? ViewState(selection: document.selectedRange, scroll: document.scrollPoint)
    }

    /// Saves the active tab's caret and scroll, here and on the document
    /// (which the session saves).
    func rememberViewState() {
        guard let document = activeDocument else { return }
        let state = ViewState(selection: textView.selectedRange(), scroll: scrollView.visibleTextOrigin)
        viewStates[ObjectIdentifier(document)] = state
        document.selectedRange = state.selection
        document.scrollPoint = state.scroll
    }

    /// A new pane opens a file where the pane it was split from shows it.
    func adoptViewState(of document: Document, from other: EditorPane) {
        viewStates[ObjectIdentifier(document)] = other.viewState(for: document)
    }

    func forget(_ document: Document) {
        viewStates[ObjectIdentifier(document)] = nil
    }

    // MARK: Chrome

    func applyWrap(_ wrap: Bool) {
        // First: the scroller change below retiles, and a tile while wrapping
        // sizes the text view and its container (see EditorScrollView.tile).
        scrollView.wrapsLines = wrap
        textView.autoresizingMask = []
        textView.isHorizontallyResizable = !wrap
        textContainer.widthTracksTextView = wrap
        if !wrap {
            textContainer.containerSize = NSSize(width: EditorPane.unbounded, height: EditorPane.unbounded)
        }
        scrollView.hasHorizontalScroller = !wrap
        scrollView.tile()
    }

    /// The path bar shows for files on disk; untitled and special tabs hide it.
    func showBreadcrumbs(_ file: URL?, root: URL?) {
        breadcrumbs.show(file, root: root)
        breadcrumbs.isHidden = file == nil
        breadcrumbHeight.constant = file == nil ? 0 : BreadcrumbBar.height
    }

    /// `isActive`: the pane commands go to (its selected tab is drawn as current).
    func refreshTabs(isActive: Bool) {
        tabBar.update(
            tabs: documents.map { TabInfo(title: $0.displayName, tooltip: $0.url?.path, isDirty: $0.isDirty) },
            selected: activeIndex,
            isActive: isActive
        )
    }
}
