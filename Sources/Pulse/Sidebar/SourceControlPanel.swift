import AppKit

private final class ChangeSection: NSObject {
    let title: String
    var items: [ChangeItem] = []

    init(title: String) {
        self.title = title
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

/// A view-only Source Control list, like VS Code's: staged and unstaged
/// changes with their status letters. git runs only while this is on screen.
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
        outline.style = .sourceList
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
            let section = ChangeSection(title: "Staged Changes")
            section.items = snapshot.staged.map(ChangeItem.init)
            built.append(section)
        }
        if !snapshot.changes.isEmpty {
            let section = ChangeSection(title: "Changes")
            section.items = snapshot.changes.map(ChangeItem.init)
            built.append(section)
        }
        sections = built
        let count = snapshot.staged.count + snapshot.changes.count
        summary.stringValue = "\(snapshot.branch.uppercased())  ·  " + (count == 0 ? "NO CHANGES" : "\(count) CHANGED")
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
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

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 22 }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ChangeRow")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? ChangeCell ?? ChangeCell(id)
        if let section = item as? ChangeSection {
            cell.textField?.attributedStringValue = NSAttributedString(string: section.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            cell.badge.stringValue = "\(section.items.count)"
            cell.badge.textColor = .secondaryLabelColor
            cell.toolTip = nil
        } else if let item = item as? ChangeItem {
            let change = item.change
            let deleted = change.kind == .deleted
            var nameAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: SourceControlPanel.color(for: change.kind),
            ]
            if deleted { nameAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let title = NSMutableAttributedString(string: (change.path as NSString).lastPathComponent, attributes: nameAttributes)
            let folder = (change.path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                title.append(NSAttributedString(string: "  " + folder, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            cell.textField?.attributedStringValue = title
            cell.badge.stringValue = String(change.kind.rawValue)
            cell.badge.textColor = SourceControlPanel.color(for: change.kind)
            cell.toolTip = change.path
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

/// Name on the left, status letter (or section count) on the right.
private final class ChangeCell: NSTableCellView {
    let badge = NSTextField(labelWithString: "")

    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        [text, badge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
