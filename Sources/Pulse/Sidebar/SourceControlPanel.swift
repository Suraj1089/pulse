import AppKit

private final class ChangeSection: NSObject {
    let title: String
    let isStaged: Bool
    var items: [ChangeItem] = []

    init(title: String, isStaged: Bool) {
        self.title = title
        self.isStaged = isStaged
        super.init()
    }
}

private final class ChangeItem: NSObject {
    let change: GitChange
    init(_ change: GitChange) {
        self.change = change
        super.init()
    }
}

/// Source Control, like VS Code's: staged and unstaged changes with their
/// status letters, and hover buttons to stage (+) or unstage (−) a file or a
/// whole section. git runs only while this is on screen or when asked.
final class SourceControlPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: ((URL) -> Void)?

    /// The folder open in Pulse; the repository is found from it.
    var root: URL? {
        didSet {
            repository = root.flatMap(GitStatus.repositoryRoot)
            sections = []
            if isViewLoaded { outline.reloadData() }
            refresh()
        }
    }

    private var repository: URL?
    private let git = GitStatus()
    private let summary = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var sections: [ChangeSection] = []
    private var refreshWork: DispatchWorkItem?

    override func loadView() {
        let container = NSView()

        summary.font = .systemFont(ofSize: 11, weight: .semibold)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.translatesAutoresizingMaskIntoConstraints = false

        let reload = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") ?? NSImage(),
                              target: self, action: #selector(refreshNow))
        reload.isBordered = false
        reload.toolTip = "Refresh"
        reload.contentTintColor = .secondaryLabelColor
        reload.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.headerView = nil
        // Plain rows on the sidebar's flat chrome color (a source list expects
        // a glass background and draws a black selection without one).
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 8
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.setAccessibilityLabel("Source control changes")

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        [summary, reload, scroll].forEach(container.addSubview)
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            summary.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: reload.leadingAnchor, constant: -6),
            reload.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
            reload.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshNow()
    }

    /// Re-reads git status if the panel is on screen; coalesces bursts such
    /// as autosave writing several files.
    func refresh() {
        guard isViewLoaded, view.window != nil else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshNow() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc private func refreshNow() {
        refreshWork?.cancel()
        guard isViewLoaded else { return }
        guard let repository else {
            git.cancel()
            show(nil, message: root == nil ? "No folder open" : "Not a git repository")
            return
        }
        git.run(repository: repository) { [weak self] snapshot in
            self?.show(snapshot, message: GitStatus.git == nil ? "git is not installed" : "Could not read git status")
        }
    }

    private func show(_ snapshot: GitSnapshot?, message: String) {
        guard let snapshot else {
            summary.stringValue = message
            sections = []
            outline.reloadData()
            return
        }
        var built: [ChangeSection] = []
        if !snapshot.staged.isEmpty {
            let section = ChangeSection(title: "Staged Changes", isStaged: true)
            section.items = snapshot.staged.map(ChangeItem.init)
            built.append(section)
        }
        if !snapshot.changes.isEmpty {
            let section = ChangeSection(title: "Changes", isStaged: false)
            section.items = snapshot.changes.map(ChangeItem.init)
            built.append(section)
        }
        sections = built
        let count = snapshot.staged.count + snapshot.changes.count
        summary.stringValue = "\(snapshot.branch.uppercased())  ·  " + (count == 0 ? "NO CHANGES" : "\(count) CHANGED")
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    // MARK: Staging

    /// Stages (from Changes) or unstages (from Staged Changes), then refreshes.
    private func toggleStage(_ changes: [GitChange], staged: Bool) {
        guard let repository, !changes.isEmpty else { return }
        let finish: (String?) -> Void = { [weak self] error in
            guard let self else { return }
            self.refreshNow()
            if let error { self.summary.stringValue = error.components(separatedBy: "\n").first ?? error }
        }
        if staged {
            // Unstaging a rename restores both the new and the old path.
            let paths = changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
            GitStatus.unstage(paths, repository: repository, completion: finish)
        } else {
            GitStatus.stage(changes.map(\.path), repository: repository, completion: finish)
        }
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        if let item = item as? ChangeItem, let repository, item.change.kind != .deleted {
            onOpenFile?(repository.appendingPathComponent(item.change.path))
        } else if let section = item as? ChangeSection {
            if outline.isItemExpanded(section) { outline.collapseItem(section) } else { outline.expandItem(section) }
        }
    }

    // MARK: Outline

    /// View › Font Size › Sidebar: new row heights, rows redrawn in place.
    func applyFontSize() {
        guard isViewLoaded else { return }
        let rows = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.noteHeightOfRows(withIndexesChanged: rows)
        outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        return (item as? ChangeSection)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = item as? ChangeSection { return section.items[index] }
        return sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ChangeSection
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { Theme.sidebarRowHeight() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ChangeRow")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? ChangeCell ?? ChangeCell(id)
        cell.badge.font = .monospacedSystemFont(ofSize: Theme.fontSize(for: .sidebar) - 2, weight: .semibold)
        if let section = item as? ChangeSection {
            cell.textField?.attributedStringValue = NSAttributedString(string: section.title, attributes: [
                .font: Theme.sidebarFont(offset: -2, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            cell.badge.stringValue = "\(section.items.count)"
            cell.badge.textColor = .secondaryLabelColor
            cell.toolTip = nil
            cell.configureAction(staged: section.isStaged, all: true) { [weak self, weak section] in
                guard let section else { return }
                self?.toggleStage(section.items.map(\.change), staged: section.isStaged)
            }
        } else if let item = item as? ChangeItem {
            let change = item.change
            let deleted = change.kind == .deleted
            var nameAttributes: [NSAttributedString.Key: Any] = [
                .font: Theme.sidebarFont(offset: -1), .foregroundColor: SourceControlPanel.color(for: change.kind),
            ]
            if deleted { nameAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let title = NSMutableAttributedString(string: (change.path as NSString).lastPathComponent, attributes: nameAttributes)
            let folder = (change.path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                title.append(NSAttributedString(string: "  " + folder, attributes: [
                    .font: Theme.sidebarFont(offset: -2), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            cell.textField?.attributedStringValue = title
            cell.badge.stringValue = String(change.kind.rawValue)
            cell.badge.textColor = SourceControlPanel.color(for: change.kind)
            cell.toolTip = change.path
            let staged = (outlineView.parent(forItem: item) as? ChangeSection)?.isStaged ?? false
            cell.configureAction(staged: staged, all: false) { [weak self] in
                self?.toggleStage([change], staged: staged)
            }
        }
        return cell
    }

    static func color(for kind: GitChange.Kind) -> NSColor {
        switch kind {
        case .modified, .renamed: return Theme.gitModified
        case .added, .untracked: return Theme.gitAdded
        case .deleted, .conflicted: return Theme.gitDeleted
        }
    }
}

/// Name on the left, status letter (or section count) on the right, and a
/// stage/unstage button that appears while the pointer is over the row.
private final class ChangeCell: NSTableCellView {
    let badge = NSTextField(labelWithString: "")
    private let action = NSButton()
    private var onAction: (() -> Void)?

    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        action.isBordered = false
        action.imagePosition = .imageOnly
        action.contentTintColor = .secondaryLabelColor
        action.isHidden = true
        action.target = self
        action.action = #selector(actionClicked)
        [text, action, badge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: 16),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "+" stages, "−" unstages; `all` is the section-header version.
    func configureAction(staged: Bool, all: Bool, perform: @escaping () -> Void) {
        let label = staged ? (all ? "Unstage All Changes" : "Unstage Changes") : (all ? "Stage All Changes" : "Stage Changes")
        action.image = NSImage(systemSymbolName: staged ? "minus" : "plus", accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        action.toolTip = label
        action.setAccessibilityLabel(label)
        onAction = perform
        action.isHidden = !isPointerInside
        // The button only shows on hover; VoiceOver gets the same action on the row.
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: label) { perform(); return true }])
    }

    @objc private func actionClicked() { onAction?() }

    // MARK: Hover

    private var isPointerInside = false {
        didSet { action.isHidden = !isPointerInside }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isPointerInside = false
    }
}
