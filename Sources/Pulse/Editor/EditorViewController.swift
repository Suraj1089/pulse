import AppKit

/// The editor panes (tabs and a text view each), the terminal split and the
/// status bar.
///
/// Memory design: a window starts with one `EditorPane`, which has one text
/// view and one layout manager; switching tabs moves that layout manager
/// onto another document's text storage, so each extra open file costs
/// roughly its own text. Split Editor Right / Down adds a pane only when
/// asked; the same file in two panes shares its storage (see EditorPane).
final class EditorViewController: NSViewController, NSTextViewDelegate {
    enum SplitDirection {
        case right, down
    }

    var onActiveDocumentChange: ((Document?) -> Void)?
    var onSessionChange: (() -> Void)?
    var onDidSave: ((Document) -> Void)?
    var onOpenRequest: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    /// The panes in reading order. One until the editor is split.
    private(set) var panes: [EditorPane] = []
    /// The pane commands go to: the last one focused.
    private(set) var activePane: EditorPane!

    /// Every open document once, pane by pane (for the session, saving, Claude Code).
    var documents: [Document] {
        var seen = Set<ObjectIdentifier>()
        return panes.flatMap(\.documents).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
    var activeDocument: Document? { activePane?.activeDocument }
    /// The active pane's text view.
    var textView: CodeTextView! { activePane?.textView }
    /// The active pane's path bar.
    var breadcrumbs: BreadcrumbBar { activePane.breadcrumbs }
    var terminalDirectory: URL?
    /// The window's opened folder, for the breadcrumb path (and Claude Code's `/ide` list).
    var projectRoot: URL? {
        didSet {
            claude.workspaceFolders = projectRoot.map { [$0] } ?? []
            if isViewLoaded { panes.forEach(refreshBreadcrumbs) }
        }
    }
    /// Claude Code's IDE connection for this window: started with its first
    /// terminal, it shares the file and selection with `claude` (see ClaudeBridge).
    let claude = ClaudeBridge()

    let statusBar = StatusBarView()
    private let split = NSSplitView()
    /// Holds the panes: one pane, or split views of them (nested for a grid).
    private let paneArea = NSView()
    private let emptyState = EmptyStateView()
    private let terminal = TerminalPanel()
    /// Views of the open special tabs, one per kind: built when first shown,
    /// kept while the tab is open (so switching keeps their state), dropped
    /// when the tab closes. Only the shown ones are in the view hierarchy;
    /// a special tab is in one pane at a time.
    private var specialControllers: [Document.Special: NSViewController] = [:]
    private let highlighter = SyntaxHighlighter()
    private var autosaveWork: DispatchWorkItem?
    /// Go › Back / Forward (see NavigationHistory).
    private var history = NavigationHistory()
    /// Set by an edit, a jump or a step through the history until the event
    /// that made it is handled. Caret moves meanwhile are not jumps: typing
    /// and pasting never count, and opening a search result in another file
    /// is one jump with the reveal that follows.
    private var settling = false

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

    /// Default file mode (Welcome tab): files opened from disk start read-only.
    static var opensFilesReadOnly: Bool {
        get { UserDefaults.standard.object(forKey: "openFilesReadOnly") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "openFilesReadOnly")
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }

    // MARK: View setup

    override func loadView() {
        let root = NSView()

        let pane = makePane()
        panes = [pane]
        activePane = pane
        placeAtRoot(pane)

        emptyState.frame = pane.editorArea.bounds
        emptyState.autoresizingMask = [.width, .height]
        emptyState.onOpen = { [weak self] in self?.onOpenRequest?() }
        emptyState.onNewFile = { [weak self] in self?.newDocument() }
        emptyState.onOpenRecent = { [weak self] url in self?.onOpenRecent?(url) }
        pane.editorArea.addSubview(emptyState)

        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(paneArea)

        // The last shell exited (or was killed): the panel goes away.
        terminal.onEmpty = { [weak self] in self?.hideTerminal() }
        claude.host = self
        terminal.environment = { [weak self] in self?.claude.terminalEnvironment() ?? [] }
        NotificationCenter.default.addObserver(self, selector: #selector(claudeIntegrationDidChange),
                                               name: .claudeIntegrationDidChange, object: nil)

        [split, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
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
        refreshChrome(pane)
    }

    /// A pane wired to this controller; nothing is built before a split asks.
    private func makePane() -> EditorPane {
        let pane = EditorPane(delegate: self)
        pane.tabBar.onSelect = { [weak self, weak pane] index in
            guard let self, let pane else { return }
            self.activate(index, in: pane)
        }
        pane.tabBar.onClose = { [weak self, weak pane] index in
            guard let self, let pane else { return }
            self.closeTab(at: index, in: pane)
        }
        pane.tabBar.menuForTab = { [weak self, weak pane] index in
            guard let self, let pane else { return nil }
            return self.tabMenu(at: index, in: pane)
        }
        pane.textView.onFocus = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.focusChanged(to: pane)
        }
        pane.textView.onRefuse = { [weak self] message in self?.statusBar.showMessage(message, isWarning: false) }
        pane.scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView)
        pane.applyWrap(EditorViewController.wrapLines)
        return pane
    }

    private func owner(of textView: NSTextView) -> EditorPane? {
        panes.first { $0.textView === textView }
    }

    /// Panes whose selected tab is `document`.
    private func panesShowing(_ document: Document) -> [EditorPane] {
        panes.filter { $0.activeDocument === document }
    }

    private func isOpen(_ document: Document, besides pane: EditorPane) -> Bool {
        panes.contains { $0 !== pane && $0.documents.contains { $0 === document } }
    }

    // MARK: Word wrap

    func applyWrap() {
        panes.forEach { $0.applyWrap(EditorViewController.wrapLines) }
    }

    func toggleWrap() {
        EditorViewController.wrapLines.toggle()
        applyWrap()
        panes.forEach { $0.ruler.needsDisplay = true }
    }

    // MARK: Documents

    /// Opens `url` in the active pane: its tab there, the same document if
    /// another pane has it open (one text, shared), or a new tab.
    func open(_ url: URL, select range: NSRange? = nil) {
        let target = url.standardizedFileURL
        let pane = activePane!
        if let index = pane.documents.firstIndex(where: { $0.url?.standardizedFileURL == target }) {
            activate(index, in: pane)
        } else if let document = documents.first(where: { $0.url?.standardizedFileURL == target }) {
            add(document, to: pane, activate: true)
        } else {
            do {
                let document = try Document.open(url)
                document.isReadOnly = EditorViewController.opensFilesReadOnly
                add(document, to: pane, activate: true)
            } catch {
                _ = presentError(error)
                return
            }
        }
        if let range { reveal(range) }
    }

    /// Opens (or switches to) a special tab such as Keyboard Shortcuts.
    func openSpecial(_ kind: Document.Special) {
        if let (pane, index) = location(where: { $0.special == kind }) {
            activate(index, in: pane)
        } else {
            add(Document(special: kind))
        }
    }

    /// Shows a changed file's diff in the diff tab, opening it if needed.
    func openDiff(_ target: GitDiffTarget) {
        if let (pane, index) = location(where: { $0.special == .diff }) {
            pane.documents[index].diffTarget = target
            if index == pane.activeIndex {
                (specialControllers[.diff] as? DiffViewController)?.show(target)
                refreshTabs()
            } else {
                activate(index, in: pane)
            }
        } else {
            let document = Document(special: .diff)
            document.diffTarget = target
            add(document)
        }
    }

    /// The first pane and tab whose document matches.
    private func location(where matches: (Document) -> Bool) -> (EditorPane, Int)? {
        let ordered = (activePane.map { [$0] } ?? []) + panes.filter { $0 !== activePane }
        for pane in ordered {
            if let index = pane.documents.firstIndex(where: matches) { return (pane, index) }
        }
        return nil
    }

    /// Re-reads the diff on screen, if any (after saving, staging or returning to Pulse).
    func reloadVisibleDiff() {
        guard panes.contains(where: { $0.activeDocument?.special == .diff }) else { return }
        (specialControllers[.diff] as? DiffViewController)?.reload()
    }

    func newDocument() {
        add(Document(url: nil, text: ""))
        view.window?.makeFirstResponder(textView)
    }

    /// Locks or unlocks the active file, in every pane that shows it.
    func toggleReadOnly() {
        guard let document = activeDocument, document.special == nil else { return }
        document.isReadOnly.toggle()
        for pane in panes where pane.activeDocument === document {
            pane.textView.isEditable = !document.isReadOnly
        }
        updateStatus()
        if !document.isReadOnly { view.window?.makeFirstResponder(textView) }
    }

    /// Adds a tab to the active pane.
    func add(_ document: Document, activate shouldActivate: Bool = true) {
        add(document, to: activePane, activate: shouldActivate)
    }

    private func add(_ document: Document, to pane: EditorPane, activate shouldActivate: Bool) {
        document.onDirtyChange = { [weak self] in self?.refreshTabs() }
        // New tabs open next to the current one; restored tabs keep their order.
        let position = shouldActivate ? (pane.activeIndex.map { $0 + 1 } ?? pane.documents.count) : pane.documents.count
        pane.documents.insert(document, at: position)
        if shouldActivate || pane.activeIndex == nil {
            activate(position, in: pane)
        } else if let active = pane.activeIndex, active >= position {
            pane.activeIndex = active + 1
            refreshTabs()
        }
        onSessionChange?()
    }

    /// Selects `documents[index]`: in the active pane if it is open there,
    /// otherwise in the pane that has it.
    func activate(_ index: Int) {
        let all = documents
        guard all.indices.contains(index) else { return }
        let document = all[index]
        if let (pane, tab) = location(where: { $0 === document }) { activate(tab, in: pane) }
    }

    private func activate(_ index: Int, in pane: EditorPane) {
        guard pane.documents.indices.contains(index) else { return }
        let document = pane.documents[index]
        // Another file: a jump from where the caret was. Showing it moves
        // the caret, which is not one.
        if document !== pane.activeDocument {
            if let origin = place(in: pane) { recordJump(from: origin) }
            settle()
        }
        pane.rememberViewState()
        pane.activeIndex = index
        makeActive(pane)
        pane.show(document)
        highlightNow(pane)
        refreshChrome(pane)
        view.window?.makeFirstResponder(firstResponder(for: document, in: pane))
        onActiveDocumentChange?(document)
        onSessionChange?()
        claude.selectionDidChange()
    }

    private func firstResponder(for document: Document, in pane: EditorPane) -> NSView? {
        switch document.special {
        case nil: return pane.textView
        case .keyboardShortcuts: return (specialControllers[.keyboardShortcuts] as? ShortcutsEditor)?.initialFirstResponder
        case .diff: return (specialControllers[.diff] as? DiffViewController)?.initialFirstResponder
        case .welcome: return nil
        }
    }

    /// Closes `documents[index]` in every pane (asking once if it is unsaved).
    /// Returns false when the user cancelled.
    @discardableResult
    func closeDocument(at index: Int) -> Bool {
        let all = documents
        guard all.indices.contains(index) else { return true }
        let document = all[index]
        guard confirmClose(document) else { return false }
        for pane in panes {
            if let tab = pane.documents.firstIndex(where: { $0 === document }) {
                removeTab(at: tab, from: pane, keepingDocument: false)
            }
        }
        onSessionChange?()
        return true
    }

    /// One tab of one pane (the tab's ×, ⌘W). A file still open in another
    /// pane closes here without saving or asking.
    @discardableResult
    private func closeTab(at index: Int, in pane: EditorPane) -> Bool {
        guard pane.documents.indices.contains(index) else { return true }
        let document = pane.documents[index]
        let elsewhere = isOpen(document, besides: pane)
        if !elsewhere {
            guard confirmClose(document) else { return false }
        }
        removeTab(at: index, from: pane, keepingDocument: elsewhere)
        onSessionChange?()
        return true
    }

    /// Saves or asks about an unsaved document; false when the user cancelled.
    private func confirmClose(_ document: Document) -> Bool {
        guard document.isDirty else { return true }
        if document.url != nil && EditorViewController.autosaveEnabled {
            return save(document)
        }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(document)
        case .alertSecondButtonReturn: return false
        default: return true
        }
    }

    /// A pane left without tabs closes, unless it is the only one.
    private func removeTab(at index: Int, from pane: EditorPane, keepingDocument: Bool) {
        let document = pane.documents.remove(at: index)
        pane.forget(document)
        if !keepingDocument, let kind = document.special, let controller = specialControllers.removeValue(forKey: kind) {
            controller.view.removeFromSuperview()
        }
        if pane.documents.isEmpty {
            pane.activeIndex = nil
            if panes.count > 1 {
                removePane(pane)
                return
            }
            pane.show(nil)
            refreshChrome(pane)
            onActiveDocumentChange?(nil)
        } else if let active = pane.activeIndex {
            if index == active {
                pane.activeIndex = nil
                activate(min(index, pane.documents.count - 1), in: pane)
            } else if index < active {
                pane.activeIndex = active - 1
                refreshTabs()
            } else {
                refreshTabs()
            }
        }
    }

    /// Before a window that won't be restored closes: closes each unsaved
    /// untitled buffer (and, with autosave off, each unsaved file), which asks
    /// Save / Cancel / Don't Save. False if the user cancelled.
    func closeUnsavedUntitledDocuments() -> Bool {
        while let index = documents.lastIndex(where: { $0.isDirty && ($0.url == nil || !EditorViewController.autosaveEnabled) }) {
            activate(index)
            if !closeDocument(at: index) { return false }
        }
        return true
    }

    func closeActive() {
        if let pane = activePane, let index = pane.activeIndex {
            closeTab(at: index, in: pane)
        } else {
            view.window?.performClose(nil)
        }
    }

    func selectTab(offset: Int) {
        guard let pane = activePane, let active = pane.activeIndex, !pane.documents.isEmpty else { return }
        activate((active + offset + pane.documents.count) % pane.documents.count, in: pane)
    }

    // MARK: Split panes

    /// The split commands need a file tab (special tabs show one view at a time).
    var canSplitEditor: Bool {
        activeDocument.map { $0.special == nil } ?? false
    }

    /// The active tab, opened again in a new pane to the right of (or below)
    /// the active pane, with the same caret and scroll position.
    func splitEditor(_ direction: SplitDirection) {
        guard let source = activePane, let document = source.activeDocument, document.special == nil else { return }
        source.rememberViewState()
        let pane = makePane()
        insert(pane, beside: source, vertical: direction == .right)
        panes.insert(pane, at: (panes.firstIndex { $0 === source } ?? panes.count - 1) + 1)
        pane.layoutSubtreeIfNeeded()
        pane.adoptViewState(of: document, from: source)
        add(document, to: pane, activate: true)
    }

    /// Next to `anchor` in its split view when that runs the same way,
    /// otherwise in a new split view that takes `anchor`'s place.
    private func insert(_ pane: EditorPane, beside anchor: EditorPane, vertical: Bool) {
        if let parent = anchor.superview as? NSSplitView, parent.isVertical == vertical,
           let index = parent.arrangedSubviews.firstIndex(of: anchor) {
            parent.insertArrangedSubview(pane, at: index + 1)
            equalize(parent)
            return
        }
        let group = NSSplitView()
        group.isVertical = vertical
        group.dividerStyle = .thin
        replace(anchor, with: group)
        group.addArrangedSubview(anchor)
        group.addArrangedSubview(pane)
        equalize(group)
    }

    /// Takes a pane out; a split view left with one view is replaced by it.
    private func removePane(_ pane: EditorPane) {
        guard panes.count > 1, let position = panes.firstIndex(where: { $0 === pane }) else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView)
        pane.detach()
        panes.remove(at: position)
        let parent = pane.superview as? NSSplitView
        parent?.removeArrangedSubview(pane)
        pane.removeFromSuperview()
        if let parent {
            if parent.arrangedSubviews.count == 1, let only = parent.arrangedSubviews.first {
                parent.removeArrangedSubview(only)
                only.removeFromSuperview()
                replace(parent, with: only)
            } else {
                equalize(parent)
            }
        }
        refreshTabs()
        guard activePane === pane else { return }
        let next = panes[max(0, position - 1)]
        makeActive(next)
        refreshChrome(next)
        if let document = next.activeDocument {
            view.window?.makeFirstResponder(firstResponder(for: document, in: next))
        }
        onActiveDocumentChange?(next.activeDocument)
        claude.selectionDidChange()
    }

    private func replace(_ old: NSView, with new: NSView) {
        if let parent = old.superview as? NSSplitView, let index = parent.arrangedSubviews.firstIndex(of: old) {
            parent.removeArrangedSubview(old)
            old.removeFromSuperview()
            parent.insertArrangedSubview(new, at: index)
            equalize(parent)
        } else {
            old.removeFromSuperview()
            placeAtRoot(new)
        }
    }

    private func placeAtRoot(_ view: NSView) {
        // A split view switches its arranged views to Auto Layout; back at
        // the root the pane is sized by its frame and autoresizing mask.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = paneArea.bounds
        view.autoresizingMask = [.width, .height]
        paneArea.addSubview(view)
    }

    /// Gives every view in `splitView` the same share.
    private func equalize(_ splitView: NSSplitView) {
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        let count = splitView.arrangedSubviews.count
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard count > 1, length > 0 else { return }
        let share = (length - CGFloat(count - 1) * splitView.dividerThickness) / CGFloat(count)
        for index in 0..<(count - 1) {
            splitView.setPosition(CGFloat(index + 1) * share + CGFloat(index) * splitView.dividerThickness, ofDividerAt: index)
        }
    }

    /// Sets the pane commands go to; its selected tab is drawn as current.
    private func makeActive(_ pane: EditorPane) {
        guard activePane !== pane else { return }
        activePane = pane
        refreshTabs()
    }

    /// A pane's text view took focus (a click, or a tab chosen there).
    private func focusChanged(to pane: EditorPane) {
        guard activePane !== pane, panes.contains(where: { $0 === pane }) else { return }
        makeActive(pane)
        updateStatus()
        onActiveDocumentChange?(pane.activeDocument)
        claude.selectionDidChange()
    }

    // MARK: Tab menu

    private final class TabReference {
        weak var pane: EditorPane?
        let index: Int
        init(pane: EditorPane, index: Int) {
            self.pane = pane
            self.index = index
        }
    }

    private func tabMenu(at index: Int, in pane: EditorPane) -> NSMenu? {
        guard pane.documents.indices.contains(index) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func addItem(_ title: String, _ action: Selector, enabled: Bool = true) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = TabReference(pane: pane, index: index)
            menuItem.isEnabled = enabled
            menu.addItem(menuItem)
        }
        let isFile = pane.documents[index].special == nil
        addItem("Split Right", #selector(splitTabRight(_:)), enabled: isFile)
        addItem("Split Down", #selector(splitTabDown(_:)), enabled: isFile)
        menu.addItem(.separator())
        addItem("Close", #selector(closeTabFromMenu(_:)))
        addItem("Close Others", #selector(closeOtherTabs(_:)), enabled: pane.documents.count > 1)
        return menu
    }

    /// The tab a menu item was opened on, selected in its pane.
    private func selectTab(of item: NSMenuItem) -> (EditorPane, Int)? {
        guard let tab = item.representedObject as? TabReference, let pane = tab.pane,
              panes.contains(where: { $0 === pane }), pane.documents.indices.contains(tab.index) else { return nil }
        activate(tab.index, in: pane)
        return (pane, tab.index)
    }

    @objc private func splitTabRight(_ sender: NSMenuItem) {
        if selectTab(of: sender) != nil { splitEditor(.right) }
    }

    @objc private func splitTabDown(_ sender: NSMenuItem) {
        if selectTab(of: sender) != nil { splitEditor(.down) }
    }

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? TabReference, let pane = tab.pane,
              panes.contains(where: { $0 === pane }) else { return }
        closeTab(at: tab.index, in: pane)
    }

    @objc private func closeOtherTabs(_ sender: NSMenuItem) {
        guard let (pane, index) = selectTab(of: sender) else { return }
        let kept = pane.documents[index]
        for document in pane.documents.reversed() where document !== kept {
            guard let tab = pane.documents.firstIndex(where: { $0 === document }) else { continue }
            if !closeTab(at: tab, in: pane) { break }
        }
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
        let renamed = target?.standardizedFileURL != document.url?.standardizedFileURL
        do {
            try document.save(to: target)
        } catch {
            _ = presentError(error)
            return false
        }
        // Blame described the file under its old name.
        if renamed, document.blame != nil {
            document.blame = nil
            blameDidChange(document)
        }
        // A new name can mean a new language.
        for pane in panesShowing(document) {
            pane.textView.lineComment = document.language?.lineComment
            highlightNow(pane)
            refreshChrome(pane)
        }
        if document === activeDocument { onActiveDocumentChange?(document) }
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
        // New text from disk moves the caret; that isn't a jump.
        settle()
        for document in documents where document.reloadIfChangedOnDisk() {
            for pane in panesShowing(document) {
                pane.ruler.updateThickness()
                pane.ruler.needsDisplay = true
                highlightNow(pane)
            }
            loadBlame(document)
            if document === activeDocument { updateStatus() }
        }
    }

    // MARK: Editing commands

    func reveal(_ range: NSRange) {
        guard let textView else { return }
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

    // MARK: Back and Forward

    var canGoBack: Bool { !history.back.isEmpty }
    var canGoForward: Bool { !history.forward.isEmpty }

    func goBack() {
        if let place = history.goBack(from: currentPlace, where: { self.canReach($0) }) { go(to: place) }
    }

    func goForward() {
        if let place = history.goForward(from: currentPlace, where: { self.canReach($0) }) { go(to: place) }
    }

    /// After a session is restored: its tab switches weren't the user's.
    func clearHistory() {
        history = NavigationHistory()
    }

    private var currentPlace: NavigationHistory.Place? {
        guard let pane = activePane else { return nil }
        return place(in: pane)
    }

    /// The caret in `pane`'s file (nil for a special tab or none).
    private func place(in pane: EditorPane) -> NavigationHistory.Place? {
        guard let document = pane.activeDocument, document.special == nil else { return nil }
        return NavigationHistory.Place(document: document, url: document.url, location: pane.textView.selectedRange().location)
    }

    /// Open in a pane, or a file that can be opened again.
    private func canReach(_ place: NavigationHistory.Place) -> Bool {
        if let document = place.document, panes.contains(where: { $0.documents.contains { $0 === document } }) { return true }
        return place.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Shows `place`'s file where it is open (the active pane first), or
    /// opens it again, with the caret there; scrolls only if that is out of view.
    private func go(to place: NavigationHistory.Place) {
        settle()
        let pane: EditorPane
        if let document = place.document, let (owner, index) = location(where: { $0 === document }) {
            if owner.activeIndex == index { focusChanged(to: owner) } else { activate(index, in: owner) }
            pane = owner
        } else if let url = place.url {
            open(url)
            pane = activePane
        } else {
            return
        }
        guard let document = pane.activeDocument, document.special == nil,
              document === place.document || document.url?.standardizedFileURL == place.url?.standardizedFileURL else { return }
        let caret = NSRange(location: min(place.location, document.length), length: 0)
        let origin = pane.scrollView.contentView.bounds.origin
        pane.textView.setSelectedRange(caret)
        pane.textView.scrollRangeToVisible(caret)
        if pane.scrollView.contentView.bounds.origin != origin { pane.textView.centerSelectionInVisibleArea(nil) }
        view.window?.makeFirstResponder(pane.textView)
    }

    /// A caret move of more than `jumpLines` lines in the active pane that
    /// typing, folding and the arrow and page keys didn't make is a jump.
    private func noteJump(in pane: EditorPane, _ notification: Notification) {
        guard !settling, let document = pane.activeDocument, document.special == nil,
              let old = (notification.userInfo?["NSOldSelectedCharacterRange"] as? NSValue)?.rangeValue,
              !EditorViewController.isStepKey(NSApp.currentEvent) else { return }
        let from = min(old.location, document.length)
        let lines = abs(document.line(at: pane.textView.selectedRange().location) - document.line(at: from))
        // Folding moves a caret out of the text it hides; Back can't show that.
        guard lines > NavigationHistory.jumpLines, document.storage.fold(at: from) == nil else { return }
        recordJump(from: NavigationHistory.Place(document: document, url: document.url, location: from))
    }

    /// Arrow, page, Home and End keys without ⌘ move the caret a step at a time.
    private static func isStepKey(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown, !event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return false }
        return (0xF700...0xF703).contains(key) || (0xF729...0xF72D).contains(key)
    }

    /// One jump per event: the caret moves that follow it are part of it.
    private func recordJump(from place: NavigationHistory.Place) {
        guard !settling else { return }
        history.record(place)
        settle()
    }

    private func settle() {
        guard !settling else { return }
        settling = true
        DispatchQueue.main.async { [weak self] in self?.settling = false }
    }

    /// Re-applies the editor size from Theme to every open document.
    func applyEditorFontSize() {
        documents.forEach { $0.applyFont() }
        for pane in panes {
            pane.textView.typingAttributes = Document.baseAttributes
            pane.ruler.updateThickness()
            pane.ruler.needsDisplay = true
        }
        (specialControllers[.diff] as? DiffViewController)?.applyFontSize()
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

    /// Another terminal tab in the open folder (the first one if none is running).
    func newTerminal() {
        let running = terminal.hasStarted
        showTerminal()
        if running { terminal.newTerminal(in: terminalDirectory) }
    }

    /// Another shell beside the focused one, in the open folder.
    func splitTerminal() {
        let running = terminal.hasStarted
        showTerminal()
        if running { terminal.splitTerminal(in: terminalDirectory) }
    }

    /// Ends the focused shell; the panel hides when it was the last one.
    func killTerminal() {
        terminal.killActive()
    }

    func killAllTerminals() {
        terminal.killAll()
        hideTerminal()
    }

    var terminalPanel: TerminalPanel { terminal }

    // MARK: Chrome

    func setRecents(_ urls: [URL]) {
        emptyState.setRecents(urls)
    }

    private func refreshChrome(_ pane: EditorPane) {
        let document = pane.activeDocument
        let special = document?.special
        pane.scrollView.isHidden = document == nil || special != nil
        showSpecial(special, in: pane)
        // Only a lone pane can be empty (others close with their last tab).
        if document == nil {
            if emptyState.superview !== pane.editorArea {
                emptyState.frame = pane.editorArea.bounds
                pane.editorArea.addSubview(emptyState)
            }
            emptyState.isHidden = false
        } else if emptyState.superview === pane.editorArea {
            emptyState.isHidden = true
        }
        refreshTabs()
        refreshBreadcrumbs(pane)
        updateStatus()
    }

    private func refreshBreadcrumbs(_ pane: EditorPane) {
        pane.showBreadcrumbs(pane.activeDocument.flatMap { $0.special == nil ? $0.url : nil }, root: projectRoot)
    }

    private func showSpecial(_ kind: Document.Special?, in pane: EditorPane) {
        // Only the shown special views are on screen; the others keep their state.
        for (other, controller) in specialControllers where other != kind && controller.view.superview === pane.editorArea {
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
            case .diff:
                let diff = DiffViewController()
                diff.onOpenFile = { [weak self] url, line in
                    guard let self else { return }
                    // Into the pane that shows the diff.
                    if let (pane, _) = self.location(where: { $0.special == .diff }) { self.makeActive(pane) }
                    self.open(url)
                    if let line { self.goToLine(line) }
                }
                controller = diff
            }
            specialControllers[kind] = controller
        }
        // The diff reloads each time its tab is shown: the file may have changed.
        if kind == .diff, let target = pane.activeDocument?.diffTarget {
            (controller as? DiffViewController)?.show(target)
        }
        if controller.view.superview !== pane.editorArea {
            controller.view.frame = pane.editorArea.bounds
            controller.view.autoresizingMask = [.width, .height]
            pane.editorArea.addSubview(controller.view)
        }
    }

    private func refreshTabs() {
        // With one pane it is always the current one.
        panes.forEach { $0.refreshTabs(isActive: $0 === activePane || panes.count == 1) }
    }

    private func updateStatus() {
        guard let pane = activePane, let document = pane.activeDocument, document.special == nil else {
            statusBar.showDocument(languageName: nil, readOnly: false, visible: false)
            return
        }
        let selection = pane.textView.selectedRange()
        let line = document.line(at: selection.location)
        let column = selection.location - document.start(ofLine: line) + 1
        statusBar.showPosition(line: line + 1, column: column, selected: selection.length)
        statusBar.showDocument(languageName: document.language?.name, readOnly: document.isReadOnly,
                               blame: document.repository == nil ? nil : document.blame != nil, visible: true)
    }

    // MARK: Blame

    /// Shows or hides who last changed each line of the active file (View ›
    /// Blame, the status bar), in every pane that shows it. Off for every
    /// file until asked, and not saved. git blames the file as saved, so
    /// unsaved changes are saved first (or, with autosave off, asked for).
    func toggleBlame() {
        guard let document = activeDocument, document.special == nil else { return }
        if document.blame != nil {
            document.blame = nil
            blameDidChange(document)
            return
        }
        guard document.repository != nil else {
            statusBar.showMessage("Blame needs a file in a git repository.", isWarning: false)
            return
        }
        if document.isDirty {
            guard EditorViewController.autosaveEnabled else {
                statusBar.showMessage("Save “\(document.displayName)” to see who changed its lines.", isWarning: false)
                return
            }
            guard save(document) else { return }
        }
        let blame = FileBlame()
        blame.onChange = { [weak self, weak document] in
            guard let self, let document else { return }
            self.blameDidChange(document)
        }
        blame.onFailure = { [weak self, weak document] message in
            guard let self, let document else { return }
            document.blame = nil
            self.blameDidChange(document)
            self.statusBar.showMessage(message, isWarning: false)
        }
        document.blame = blame
        loadBlame(document)
        blameDidChange(document)
    }

    private func loadBlame(_ document: Document) {
        guard let blame = document.blame, let url = document.url else { return }
        blame.load(url, lineCount: document.lineCount)
    }

    /// Reads blame again for the saved files showing it (on returning to
    /// Pulse: commits may have been made meanwhile). Nothing runs otherwise.
    func refreshBlame() {
        for document in documents where document.blame?.isLoading == false && !document.isDirty {
            loadBlame(document)
        }
    }

    private func blameDidChange(_ document: Document) {
        for pane in panesShowing(document) { pane.textView.needsDisplay = true }
        if document === activeDocument { updateStatus() }
    }

    // MARK: Highlighting

    private func scheduleHighlight(_ pane: EditorPane, after delay: TimeInterval = 0.08) {
        pane.highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.highlightNow(pane)
        }
        pane.highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Temporary attributes belong to a layout manager, so each pane
    /// highlights what it shows.
    private func highlightNow(_ pane: EditorPane) {
        pane.highlightWork?.cancel()
        guard let document = pane.activeDocument else { return }
        let range = SyntaxHighlighter.rangeToHighlight(textView: pane.textView)
        highlighter.highlight(range: range, in: pane.layoutManager, language: document.language)
    }

    @objc private func didScroll(_ notification: Notification) {
        guard let pane = panes.first(where: { $0.scrollView.contentView === notification.object as? NSClipView }) else { return }
        pane.ruler.needsDisplay = true
        if (pane.activeDocument?.length ?? 0) > SyntaxHighlighter.fullPassLimit { scheduleHighlight(pane, after: 0.05) }
    }

    private func colorSample() -> String {
        guard let storage = activePane.layoutManager.textStorage, storage.length > 0 else { return "none" }
        return String(describing: storage.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }

    /// Prints text-view geometry; used by scripts/screenshot.sh in CI.
    func dumpLayout() {
        let pane = activePane!
        let layoutManager = pane.layoutManager
        let textView = pane.textView
        let scrollView = pane.scrollView
        layoutManager.ensureLayout(for: pane.textContainer)
        let lines = [
            "storage length: \(layoutManager.textStorage?.length ?? -1), glyphs: \(layoutManager.numberOfGlyphs)",
            "textView frame: \(textView.frame), hidden: \(textView.isHidden), superview: \(String(describing: textView.superview))",
            "visibleRect: \(textView.visibleRect), clip bounds: \(scrollView.contentView.bounds)",
            "container size: \(pane.textContainer.size), usedRect: \(layoutManager.usedRect(for: pane.textContainer))",
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
        owner(of: view)?.activeDocument?.undoManager
    }

    /// Before every edit (typing, Pulse's own commands, Undo): the caret move
    /// that follows isn't a jump, and blame moves with the lines (nothing to
    /// do while blame is off).
    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                  replacementStrings: [String]?) -> Bool {
        if replacementStrings != nil { settle() }
        if let replacementStrings, let document = owner(of: textView)?.activeDocument, document.blame != nil {
            document.blameWillChange(affectedRanges.map(\.rangeValue), replacementStrings)
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, let pane = owner(of: textView),
              let document = pane.activeDocument, document.special == nil else { return }
        document.invalidateLines()
        document.isDirty = true
        // Every pane showing this file: one text, so all of them changed.
        for other in panesShowing(document) {
            other.ruler.updateThickness()
            other.ruler.needsDisplay = true
            scheduleHighlight(other)
        }
        scheduleAutosave()
        updateStatus()
        onSessionChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, let pane = owner(of: textView) else { return }
        pane.ruler.needsDisplay = true
        guard pane === activePane else { return }
        noteJump(in: pane, notification)
        updateStatus()
        claude.selectionDidChange()
    }
}

// MARK: Claude Code

extension EditorViewController: ClaudeBridgeHost {
    func claudeSelection() -> ClaudeSelection? {
        guard isViewLoaded, let document = activeDocument, document.special == nil, let url = document.url else { return nil }
        let text = document.storage.string as NSString
        let selected = textView.selectedRange()
        let location = min(selected.location, text.length)
        let range = NSRange(location: location, length: min(selected.length, text.length - location))
        func position(_ offset: Int) -> ClaudeSelection.Position {
            let line = document.line(at: offset)
            return ClaudeSelection.Position(line: line, character: offset - document.start(ofLine: line))
        }
        var shared = ""
        if range.length > 0 {
            // Capped (Claude Code reads only the start), on whole characters.
            let capped = NSRange(location: range.location, length: min(range.length, ClaudeBridge.maxSelectionCharacters))
            shared = text.substring(with: text.rangeOfComposedCharacterSequences(for: capped))
        }
        return ClaudeSelection(url: url, text: shared, start: position(range.location), end: position(NSMaxRange(range)))
    }

    func claudeOpenEditors() -> [ClaudeOpenEditor] {
        documents.compactMap { document in
            guard document.special == nil, let url = document.url else { return nil }
            return ClaudeOpenEditor(url: url, isActive: document === activeDocument, isDirty: document.isDirty)
        }
    }

    func claudeSave(_ url: URL) -> Bool? {
        let target = url.standardizedFileURL
        guard let document = documents.first(where: { $0.special == nil && $0.url?.standardizedFileURL == target }) else {
            return nil
        }
        return !document.isDirty || save(document)
    }

    func claudeConnectionsDidChange(_ count: Int) {
        statusBar.showClaude(connected: count > 0)
    }

    /// `@file#L5-9` for the selection (`@file` with none) into Claude Code's
    /// prompt, then to its terminal, like VS Code's Insert At-Mentioned.
    func sendSelectionToClaude() {
        guard let selection = claudeSelection() else { return }
        guard claude.mention(selection, inShell: terminal.focusedShellPID) else {
            statusBar.showMessage("Claude Code isn't connected. Run claude in the terminal, or /ide in another one.",
                                  isWarning: false)
            return
        }
        // Only to a running terminal: Claude may be connected from another app.
        if terminal.hasStarted { showTerminal() }
    }

    /// Starts the connection without a terminal, for `claude` in another app.
    func connectClaudeFromAnotherTerminal() {
        if claude.start() {
            let name = projectRoot?.lastPathComponent ?? "this window"
            statusBar.showMessage("In Claude Code, run /ide and choose Pulse (\(name)).", isWarning: false)
        } else if !ClaudeBridge.isEnabled {
            statusBar.showMessage("Sharing with Claude Code is off (View › Share Selection with Claude Code).", isWarning: false)
        } else {
            statusBar.showMessage("Claude Code isn't installed: there is no \(ClaudeBridge.configDirectory.path) folder.",
                                  isWarning: false)
        }
    }

    /// Off: Claude disconnects. On: the connection comes back if this window
    /// has terminals (shells already running need `/ide`; new ones connect).
    @objc private func claudeIntegrationDidChange() {
        if !ClaudeBridge.isEnabled {
            claude.stop()
        } else if terminal.hasStarted {
            claude.start()
        }
    }
}
