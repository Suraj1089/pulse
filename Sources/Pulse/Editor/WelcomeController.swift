import AppKit

/// The Welcome tab: one narrow column with the common first actions and a
/// few settings. Shown the first time Pulse opens with nothing else open, at
/// every launch if "Show on launch" is ticked, and from Help › Welcome to
/// Pulse. Like the Keyboard Shortcuts tab, it is built when its tab is shown
/// and dropped when the tab closes.
final class WelcomeController: NSViewController {
    static var showsOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: "showWelcomeOnLaunch") }
        set { UserDefaults.standard.set(newValue, forKey: "showWelcomeOnLaunch") }
    }

    private static let columnWidth: CGFloat = 300

    private let appearance = NSSegmentedControl()
    private let autosave = NSSwitch()
    private let install = NSButton(title: "Install", target: nil, action: nil)
    private let showOnLaunch = NSButton(checkboxWithTitle: "Show on launch", target: nil, action: nil)
    private var actionRows: [WelcomeRow] = []

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = WelcomeBackgroundView()

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "Welcome to Pulse")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let version = NSTextField(labelWithString: "Version \(Updater.currentVersion)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        let header = NSStackView(views: [icon, title, version])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 2
        header.setCustomSpacing(10, after: icon)

        actionRows = [
            WelcomeRow(title: "Open a folder…", action: #selector(MainWindowController.openDocument(_:))),
            WelcomeRow(title: "New file", action: #selector(MainWindowController.newFile(_:))),
            WelcomeRow(title: "Go to file", action: #selector(MainWindowController.showGoToFile(_:))),
            WelcomeRow(title: "All commands", action: #selector(MainWindowController.showCommandPalette(_:))),
            WelcomeRow(title: "Terminal", action: #selector(MainWindowController.toggleTerminal(_:))),
        ]
        let actions = rows(actionRows)

        appearance.segmentCount = AppAppearance.allCases.count
        for (index, mode) in AppAppearance.allCases.enumerated() {
            appearance.setLabel(mode.title, forSegment: index)
        }
        appearance.trackingMode = .selectOne
        appearance.controlSize = .small
        appearance.target = self
        appearance.action = #selector(appearanceChanged)

        autosave.controlSize = .mini
        autosave.target = self
        autosave.action = #selector(autosaveChanged)

        install.bezelStyle = .rounded
        install.controlSize = .small
        install.target = self
        install.action = #selector(installCommand)

        let command = NSTextField(labelWithString: "pulse")
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.textColor = .secondaryLabelColor
        let commandLabel = NSStackView(views: [label("Terminal command"), command])
        commandLabel.spacing = 5

        let settings = rows([
            setting(label("Appearance"), appearance),
            setting(commandLabel, install),
            setting(label("Autosave"), autosave),
        ])

        let separator = NSBox()
        separator.boxType = .separator

        showOnLaunch.font = .systemFont(ofSize: 11)
        showOnLaunch.target = self
        showOnLaunch.action = #selector(showOnLaunchChanged)

        let column = NSStackView(views: [header, actions, separator, settings, showOnLaunch])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 16
        column.setCustomSpacing(26, after: header)
        column.setCustomSpacing(20, after: settings)
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            column.widthAnchor.constraint(equalToConstant: WelcomeController.columnWidth),
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
            column.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 24),
            actions.widthAnchor.constraint(equalTo: column.widthAnchor),
            settings.widthAnchor.constraint(equalTo: column.widthAnchor),
            separator.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16),
        ])
        view = root

        // The editor adds and removes this view directly (no view-controller
        // appearance calls), so refresh whenever it lands in the window.
        root.onMoveToWindow = { [weak self] in self?.refresh() }
        // Settings, the pulse command and shortcuts can change from menus,
        // other tabs or keybindings.json while this tab is open.
        for name in [Notification.Name.commandLineToolDidChange, .settingsDidChange, .keyBindingsDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        refresh()
    }

    /// Settings can also change from the menus while the tab is open.
    @objc private func refresh() {
        appearance.selectedSegment = AppAppearance.allCases.firstIndex(of: AppAppearance.current) ?? 0
        autosave.state = EditorViewController.autosaveEnabled ? .on : .off
        showOnLaunch.state = WelcomeController.showsOnLaunch ? .on : .off
        let installed = CommandLineTool.isInstalled
        install.title = installed ? "Installed" : "Install"
        install.isEnabled = !installed
        actionRows.forEach { $0.refreshShortcut() }
    }

    // MARK: Building

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        return field
    }

    private func setting(_ label: NSView, _ control: NSView) -> NSView {
        let row = NSStackView(views: [label, control])
        row.distribution = .equalSpacing
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return row
    }

    private func rows(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 0
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    // MARK: Actions

    @objc private func appearanceChanged() {
        let modes = AppAppearance.allCases
        guard modes.indices.contains(appearance.selectedSegment) else { return }
        AppAppearance.current = modes[appearance.selectedSegment]
    }

    @objc private func autosaveChanged() {
        // Through the menu command, so turning it on also saves right away.
        if (autosave.state == .on) != EditorViewController.autosaveEnabled {
            NSApp.sendAction(#selector(MainWindowController.toggleAutosave(_:)), to: nil, from: self)
        }
    }

    @objc private func installCommand() {
        NSApp.sendAction(#selector(MainWindowController.installCommandLineTool(_:)), to: nil, from: self)
    }

    @objc private func showOnLaunchChanged() {
        WelcomeController.showsOnLaunch = showOnLaunch.state == .on
    }
}

/// A plain row that runs a menu command: its title on the left, the
/// command's current shortcut (it follows rebinding) on the right.
private final class WelcomeRow: NSView {
    private let action: Selector
    private let shortcut = NSTextField(labelWithString: "")

    init(title: String, action: Selector) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        shortcut.stringValue = KeyBindings.display(for: action)
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [label, shortcut])
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The command's current shortcut, after rebinding.
    func refreshShortcut() {
        shortcut.stringValue = KeyBindings.display(for: action)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }

    // Taking mouseDown is what makes AppKit deliver the matching mouseUp.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        setHighlighted(false)
        NSApp.sendAction(action, to: nil, from: self)
    }

    override func accessibilityPerformPress() -> Bool {
        NSApp.sendAction(action, to: nil, from: self)
    }

    private func setHighlighted(_ highlighted: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = highlighted ? Theme.currentLine.cgColor : nil
        }
    }
}

/// The editor background, drawn by the layer (no backing store).
private final class WelcomeBackgroundView: NSView {
    var onMoveToWindow: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.editorBackground.cgColor
    }
}

extension Notification.Name {
    /// The `pulse` command was installed (refreshes the Welcome tab).
    static let commandLineToolDidChange = Notification.Name("PulseCommandLineToolDidChange")
    /// Appearance or autosave changed, from any menu or tab.
    static let settingsDidChange = Notification.Name("PulseSettingsDidChange")
}
