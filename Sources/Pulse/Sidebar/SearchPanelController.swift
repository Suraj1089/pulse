import AppKit

private final class MatchItem: NSObject {
    let file: SearchFileResult
    let match: SearchMatch

    init(file: SearchFileResult, match: SearchMatch) {
        self.file = file
        self.match = match
        super.init()
    }
}

final class SearchPanelController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenMatch: ((URL, SearchMatch) -> Void)?
    var root: URL?
    var index: FileIndex?

    private let field = NSSearchField()
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let search = ProjectSearch()
    private var results: [SearchFileResult] = []
    private var items: [ObjectIdentifier: [MatchItem]] = [:]

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

        field.placeholderString = "Search project"
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.target = self
        field.action = #selector(runSearch)
        field.translatesAutoresizingMaskIntoConstraints = false

        caseButton.setButtonType(.pushOnPushOff)
        caseButton.bezelStyle = .recessed
        caseButton.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        caseButton.toolTip = "Match case"
        caseButton.target = self
        caseButton.action = #selector(runSearch)
        caseButton.translatesAutoresizingMaskIntoConstraints = false

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
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
        outline.setAccessibilityLabel("Search results")

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        [field, caseButton, summary, scroll].forEach(container.addSubview)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            caseButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            caseButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            caseButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            caseButton.widthAnchor.constraint(equalToConstant: 30),
            summary.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            summary.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    func focus(with text: String?) {
        if let text, !text.isEmpty, !text.contains("\n") { field.stringValue = text }
        view.window?.makeFirstResponder(field)
        if !field.stringValue.isEmpty { runSearch() }
    }

    func clear() {
        search.cancel()
        results = []
        items = [:]
        summary.stringValue = ""
        outline.reloadData()
    }

    @objc private func runSearch() {
        let query = field.stringValue
        guard !query.isEmpty, let root, let index else { clear(); return }
        summary.stringValue = "Searching…"
        search.run(query: query, root: root, caseSensitive: caseButton.state == .on, index: index) { [weak self] results, truncated in
            guard let self else { return }
            self.results = results
            self.items = [:]
            for file in results {
                self.items[ObjectIdentifier(file)] = file.matches.map { MatchItem(file: file, match: $0) }
            }
            let total = results.reduce(0) { $0 + $1.matches.count }
            if total == 0 {
                self.summary.stringValue = "No results"
            } else {
                let fileWord = results.count == 1 ? "file" : "files"
                let resultWord = total == 1 ? "result" : "results"
                self.summary.stringValue = "\(total)\(truncated ? "+" : "") \(resultWord) in \(results.count) \(fileWord)"
            }
            self.outline.reloadData()
            self.outline.expandItem(nil, expandChildren: true)
        }
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        if let match = item as? MatchItem {
            onOpenMatch?(match.file.url, match.match)
        } else if let file = item as? SearchFileResult {
            if outline.isItemExpanded(file) { outline.collapseItem(file) } else { outline.expandItem(file) }
        }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return results.count }
        if let file = item as? SearchFileResult { return items[ObjectIdentifier(file)]?.count ?? 0 }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let file = item as? SearchFileResult { return items[ObjectIdentifier(file)]![index] }
        return results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SearchFileResult
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is SearchFileResult ? 22 : 20
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier(item is SearchFileResult ? "FileRow" : "MatchRow")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        if let file = item as? SearchFileResult {
            let title = NSMutableAttributedString(string: file.url.lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ])
            let folder = (file.relativePath as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                title.append(NSAttributedString(string: "  " + folder, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            cell.textField?.attributedStringValue = title
            cell.toolTip = file.relativePath
        } else if let match = item as? MatchItem {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let text = NSMutableAttributedString(string: "\(match.match.line)  ", attributes: [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            let preview = NSMutableAttributedString(string: match.match.preview, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
            ])
            let highlight = NSRange(location: match.match.previewStart, length: match.match.length)
            if match.match.length > 0, NSMaxRange(highlight) <= preview.length {
                preview.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.5), range: highlight)
            }
            text.append(preview)
            cell.textField?.attributedStringValue = text
            cell.toolTip = nil
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
