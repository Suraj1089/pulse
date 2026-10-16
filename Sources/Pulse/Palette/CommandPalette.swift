import AppKit

struct PaletteCommand {
    let title: String
    let shortcut: String
    let run: () -> Void
}

private struct PaletteRow {
    let title: String
    let detail: String
    let matched: [Int]       // character offsets in `title` to bold
    let run: () -> Void
}

/// One floating panel for three modes, chosen by the first character of the
/// query: files (default), commands (`>`), and go to line (`:`).
final class CommandPalette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var commands: () -> [PaletteCommand] = { [] }
    var files: (@escaping ([String]) -> Void) -> Void = { $0([]) }
    var openFile: (String) -> Void = { _ in }
    var goToLine: (Int) -> Void = { _ in }

    private let panel: PalettePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [PaletteRow] = []
    private var filePaths: [String] = []
    private var heightConstraint: NSLayoutConstraint!
    private var session = 0
    private static let rowHeight: CGFloat = 30
    private static let maxRows = 10

    override init() {
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 60),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        buildUI()
    }

    private func buildUI() {
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.colorSpace = .sRGB  // 4-byte pixels on wide-gamut displays (see MainWindowController)
        panel.hasShadow = true
        panel.onResignKey = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = CommandPalette.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        [field, separator, scroll].forEach(background.addSubview)
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            heightConstraint,
        ])
    }

    // MARK: Showing

    var isVisible: Bool { panel.isVisible }

    func show(over window: NSWindow, initialText: String) {
        field.stringValue = initialText
        field.placeholderString = "Go to file  ·  > commands  ·  : line"
        filePaths = []
        session += 1
        let current = session
        files { [weak self] paths in
            guard let self, self.session == current else { return }
            self.filePaths = paths
            self.refresh()
        }
        refresh()
        let width: CGFloat = min(620, window.frame.width - 80)
        let frame = window.frame
        let height = panelHeight()
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 110 - height, width: width, height: height), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (initialText as NSString).length, length: 0)
    }

    func close() {
        guard panel.isVisible else { return }
        session += 1
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        rows = []
        filePaths = []
        table.reloadData()
    }

    private func panelHeight() -> CGFloat {
        let visibleRows = min(rows.count, CommandPalette.maxRows)
        let listHeight = visibleRows == 0 ? 0 : CGFloat(visibleRows) * CommandPalette.rowHeight + 2
        heightConstraint.constant = listHeight
        return 14 + 22 + 12 + 1 + 4 + listHeight + 6 + (visibleRows == 0 ? 6 : 0)
    }

    // MARK: Filtering

    private func refresh() {
        let query = field.stringValue
        if query.hasPrefix(">") {
            let text = query.dropFirst().trimmingCharacters(in: .whitespaces)
            rows = commands().compactMap { command -> (Fuzzy.Score, PaletteRow)? in
                guard let score = Fuzzy.score(text, in: command.title) else { return nil }
                return (score, PaletteRow(title: command.title, detail: command.shortcut, matched: score.positions, run: command.run))
            }
            .sorted { $0.0.value > $1.0.value }
            .map { $0.1 }
        } else if query.hasPrefix(":") {
            let number = Int(query.dropFirst().trimmingCharacters(in: .whitespaces))
            rows = [PaletteRow(
                title: number.map { "Go to line \($0)" } ?? "Type a line number",
                detail: "", matched: [],
                run: { [weak self] in if let number { self?.goToLine(number) } }
            )]
        } else {
            let text = query.trimmingCharacters(in: .whitespaces)
            var scored: [(Fuzzy.Score, String)] = []
            for path in filePaths {
                if text.isEmpty {
                    scored.append((Fuzzy.Score(value: 0, positions: []), path))
                } else if let score = Fuzzy.score(text, in: path, preferTail: true) {
                    scored.append((score, path))
                }
                if text.isEmpty && scored.count >= 200 { break }
            }
            scored.sort { $0.0.value != $1.0.value ? $0.0.value > $1.0.value : $0.1.count < $1.1.count }
            rows = scored.prefix(200).map { score, path in
                PaletteRow(title: path, detail: "", matched: score.positions, run: { [weak self] in self?.openFile(path) })
            }
        }
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        if panel.isVisible, let parent = panel.parent {
            let height = panelHeight()
            let frame = parent.frame
            let width = panel.frame.width
            panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 110 - height, width: width, height: height), display: true)
        }
    }

    private func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else { NSSound.beep(); return }
        let action = rows[row].run
        close()
        action()
    }

    @objc private func rowClicked() {
        if table.clickedRow >= 0 {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            runSelected()
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(); return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let next = max(0, min(rows.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("PaletteCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteCell ?? PaletteCell(identifier: id)
        let item = rows[row]
        let title = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        let bold = NSFont.systemFont(ofSize: 13, weight: .bold)
        let length = (item.title as NSString).length
        for position in item.matched where position < length {
            title.addAttribute(.font, value: bold, range: NSRange(location: position, length: 1))
        }
        cell.title.attributedStringValue = title
        cell.detail.stringValue = item.detail
        return cell
    }
}

private final class PaletteCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.lineBreakMode = .byTruncatingHead
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        [title, detail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class PalettePanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Subsequence matching with bonuses for consecutive characters and word
/// starts. Good enough for paths and command names, and allocation-light.
enum Fuzzy {
    struct Score {
        let value: Int
        let positions: [Int]
    }

    static func score(_ query: String, in candidate: String, preferTail: Bool = false) -> Score? {
        if query.isEmpty { return Score(value: 0, positions: []) }
        let needle = Array(query.lowercased().utf16)
        let hay = Array(candidate.utf16)
        let lowerHay = Array(candidate.lowercased().utf16)
        guard lowerHay.count == hay.count else { return nil }
        let tailStart = preferTail ? (hay.lastIndex(of: 47).map { $0 + 1 } ?? 0) : 0 // after last '/'

        var positions: [Int] = []
        positions.reserveCapacity(needle.count)
        var value = 0
        var j = 0
        var previous = -2
        for (i, c) in lowerHay.enumerated() where j < needle.count {
            guard c == needle[j] else { continue }
            var bonus = 1
            if i == previous + 1 { bonus += 5 }
            if i == 0 || [47, 95, 45, 46, 32].contains(hay[i - 1]) { bonus += 4 } // / _ - . space
            if i > 0, hay[i] >= 65, hay[i] <= 90, hay[i - 1] >= 97, hay[i - 1] <= 122 { bonus += 3 } // camelCase
            if i >= tailStart { bonus += 2 }
            value += bonus
            positions.append(i)
            previous = i
            j += 1
        }
        guard j == needle.count else { return nil }
        return Score(value: value * 100 - hay.count, positions: positions)
    }
}
