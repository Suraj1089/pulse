import AppKit

/// The Keyboard Shortcuts tab, like VS Code's: search, then double-click a
/// command and press the new keys. The editor creates it when the tab opens
/// and drops it when the tab closes. Changes are saved to keybindings.json.
final class ShortcutsEditor: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let search = NSSearchField()
    private let table = NSTableView()
    private let hint = NSTextField(labelWithString: "")
    private let changeButton = NSButton(title: "Change…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private var rows: [KeyCommand] = []
    private var recording: KeyCommand?
    private var monitor: Any?

    private static let defaultHint = "Double-click a command to change its shortcut."

    deinit {
        stopRecording()
        NotificationCenter.default.removeObserver(self)
    }

    /// Where the keyboard goes when the tab becomes active.
    var initialFirstResponder: NSView { table }

    override func loadView() {
        let content = NSView()
        view = content

        search.placeholderString = "Search commands or keys"
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true

        for (id, title, width) in [("command", "Command", 330.0), ("key", "Keybinding", 140.0), ("source", "Source", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(changeSelected)
        table.setAccessibilityLabel("Keyboard shortcuts")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.stringValue = ShortcutsEditor.defaultHint

        changeButton.target = self
        changeButton.action = #selector(changeSelected)
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        resetButton.target = self
        resetButton.action = #selector(resetSelected)
        let resetAll = NSButton(title: "Reset All", target: self, action: #selector(resetAllShortcuts))

        // Like VS Code's "Open Keyboard Shortcuts (JSON)" button.
        let json = NSButton(image: NSImage(systemSymbolName: "curlybraces", accessibilityDescription: "Open keybindings.json") ?? NSImage(),
                            target: nil, action: #selector(MainWindowController.openKeyboardShortcutsJSON(_:)))
        json.bezelStyle = .texturedRounded
        json.toolTip = "Open Keyboard Shortcuts (JSON)"
        json.setContentHuggingPriority(.required, for: .horizontal)

        let top = NSStackView(views: [search, json])
        top.spacing = 8

        let buttons = NSStackView(views: [hint, NSView(), changeButton, removeButton, resetButton, resetAll])
        buttons.spacing = 8

        [top, scroll, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        updateButtons()
        reload()
        // keybindings.json edited in another tab.
        NotificationCenter.default.addObserver(self, selector: #selector(bindingsChanged),
                                               name: .keyBindingsDidChange, object: nil)
    }

    @objc private func bindingsChanged() {
        if recording == nil { reload() }
    }

    // MARK: Data

    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let selectedID = selected?.id
        rows = KeyBindings.commands.filter { command in
            query.isEmpty
                || command.title.lowercased().contains(query)
                || (command.shortcut?.display.lowercased().contains(query) ?? false)
        }
        table.reloadData()
        if let selectedID, let row = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateButtons()
    }

    private var selected: KeyCommand? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private func updateButtons() {
        let command = selected
        changeButton.isEnabled = command != nil
        removeButton.isEnabled = command?.shortcut != nil
        resetButton.isEnabled = command?.isCustomized ?? false
    }

    @objc private func searchChanged() { reload() }

    // MARK: Recording

    @objc private func changeSelected() {
        guard let command = selected else { return }
        stopRecording()
        recording = command
        hint.stringValue = "Press the new shortcut for “\(command.item.title)”. Esc cancels, ⌫ removes."
        // Only this row changes; a full reload would drop the selection.
        table.reloadData(forRowIndexes: IndexSet(integer: table.selectedRow), columnIndexes: IndexSet(integer: 1))
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            self.record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        guard let command = recording else { return }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain && event.keyCode == 53 {  // Esc
            finish(message: nil)
        } else if plain && (event.keyCode == 51 || event.keyCode == 117) {  // ⌫ / ⌦
            KeyBindings.set(nil, for: command.id)
            finish(message: "Removed the shortcut for “\(command.item.title)”.")
        } else if let shortcut = Shortcut(event: event) {
            let displaced = KeyBindings.set(shortcut, for: command.id)
            finish(message: displaced.map { "\(shortcut.display) was moved from “\($0.title)”." })
        } else {
            NSSound.beep()
            hint.stringValue = "Shortcuts need ⌘ or ⌃ (or a function key). Esc cancels."
        }
    }

    private func finish(message: String?) {
        stopRecording()
        hint.stringValue = message ?? ShortcutsEditor.defaultHint
        reload()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    @objc private func removeSelected() {
        guard let command = selected else { return }
        stopRecording()
        KeyBindings.set(nil, for: command.id)
        finish(message: "Removed the shortcut for “\(command.item.title)”.")
    }

    @objc private func resetSelected() {
        guard let command = selected else { return }
        stopRecording()
        let displaced = KeyBindings.reset(command.id)
        finish(message: displaced.map { "\(command.shortcut?.display ?? "") was moved from “\($0.title)”." })
    }

    @objc private func resetAllShortcuts() {
        stopRecording()
        KeyBindings.resetAll()
        finish(message: "All shortcuts are back to their defaults.")
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if recording != nil { finish(message: nil) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if recording != nil, selected?.id != recording?.id { finish(message: nil) }
        updateButtons()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let command = rows[row]
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView ?? makeCell(column.identifier)
        let text = cell.textField!
        text.textColor = .labelColor
        text.font = .systemFont(ofSize: 12)
        switch column.identifier.rawValue {
        case "command":
            text.stringValue = command.title
            cell.toolTip = command.id
        case "key":
            if recording?.id == command.id {
                text.stringValue = "Press keys…"
                text.textColor = .controlAccentColor
            } else {
                text.stringValue = command.shortcut?.display ?? "—"
                text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                if command.shortcut == nil { text.textColor = .tertiaryLabelColor }
            }
        default:
            text.stringValue = command.isCustomized ? "User" : "Default"
            text.textColor = command.isCustomized ? .controlAccentColor : .secondaryLabelColor
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
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
