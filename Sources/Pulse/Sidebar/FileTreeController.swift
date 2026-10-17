import AppKit

final class FileTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpenFile: ((URL) -> Void)?
    var onFilesChanged: (() -> Void)?

    private(set) var root: FileNode?
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let header = NSTextField(labelWithString: "")
    private let cellID = NSUserInterfaceItemIdentifier("FileCell")

    override func viewDidLayout() {
        super.viewDidLayout()
        // Keep the single column exactly as wide as the sidebar so names
        // truncate at the sidebar edge, not at a default column width.
        let width = scroll.contentSize.width
        if let column = outline.tableColumns.first, width > 0, abs(column.width - width) > 0.5 {
            column.width = width
        }
    }

    override func loadView() {
        let container = NSView()

        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        // Plain rows on the sidebar's flat chrome color (a source list expects
        // a glass background and draws a black selection without one).
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = Theme.sidebarRowHeight()
        outline.indentationPerLevel = 10
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.setAccessibilityLabel("Files")

        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    /// View › Font Size › Sidebar: taller rows, and the visible ones redrawn
    /// in place so expanded folders stay expanded.
    func applyFontSize() {
        guard isViewLoaded else { return }
        outline.rowHeight = Theme.sidebarRowHeight()
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    func setRoot(_ url: URL?) {
        root = url.map { FileNode(url: $0, isDirectory: true) }
        header.stringValue = url?.lastPathComponent.uppercased() ?? ""
        outline.reloadData()
    }

    func refresh() {
        guard let root else { return }
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
        root.refresh()
        outline.reloadItem(nil, reloadChildren: true)
        if let selected { revealNow(selected) }
    }

    /// Expands the folders above `url` and selects it; nil (a tab without a
    /// file) clears the selection.
    func reveal(_ url: URL?) {
        // Deferred one turn so a just-reloaded outline has created its rows.
        DispatchQueue.main.async { [weak self] in self?.revealNow(url) }
    }

    private func revealNow(_ url: URL?) {
        guard let url else { outline.deselectAll(nil); return }
        guard let root else { return }
        let rootPath = root.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { outline.deselectAll(nil); return }
        var current = root
        for part in path.dropFirst(rootPath.count + 1).split(separator: "/") {
            guard let next = current.children.first(where: { $0.name == part }) else { return }
            if next.isDirectory { outline.expandItem(next) }
            current = next
        }
        let row = outline.row(forItem: current)
        guard row >= 0 else { outline.deselectAll(nil); return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? root else { return 0 }
        return node.isDirectory ? node.children.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? FileNode) ?? root!
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("FileRow")
        if let row = outlineView.makeView(withIdentifier: id, owner: self) as? FileTreeRowView { return row }
        let row = FileTreeRowView()
        row.identifier = id
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = node.name
        cell.textField?.font = Theme.sidebarFont()
        cell.imageView?.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.fontSize(for: .sidebar) - 1, weight: .regular)
        cell.imageView?.image = NSImage(
            systemSymbolName: node.isDirectory ? "folder" : "doc",
            accessibilityDescription: nil
        )
        cell.imageView?.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellID
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func rowClicked() {
        activate(row: outline.clickedRow)
    }

    /// What a click on `row` does: toggle a folder, open a file.
    func activate(row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpenFile?(node.url)
        }
    }

    // MARK: Context menu

    private var menuTarget: FileNode? {
        let row = outline.clickedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : root
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard root != nil else { return }
        menu.addItem(withTitle: "New File…", action: #selector(newFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Folder…", action: #selector(newFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self
        if outline.clickedRow >= 0 {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrash), keyEquivalent: "").target = self
        }
    }

    private func targetFolder() -> URL? {
        guard let node = menuTarget else { return nil }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    @objc private func newFile() {
        guard let folder = targetFolder(), let name = askForName(title: "New File") else { return }
        let url = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        refresh()
        onFilesChanged?()
        onOpenFile?(url)
    }

    @objc private func newFolder() {
        guard let folder = targetFolder(), let name = askForName(title: "New Folder") else { return }
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        refresh()
        onFilesChanged?()
    }

    @objc private func revealInFinder() {
        guard let node = menuTarget else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPath() {
        guard let node = menuTarget else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    @objc private func moveToTrash() {
        guard let node = menuTarget, node !== root else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([node.url]) { [weak self] _, _ in
            self?.refresh()
            self?.onFilesChanged?()
        }
    }

    private func askForName(title: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.contains("/") ? nil : name
    }
}

/// The open file's row stays clearly marked while the editor has focus: an
/// accent tint instead of the faint gray AppKit draws for a table that isn't
/// focused. With the tree focused, the standard selection is drawn.
final class FileTreeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard !isEmphasized else { return super.drawSelection(in: dirtyRect) }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        bounds.fill()
    }
}
