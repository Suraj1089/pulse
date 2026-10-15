import AppKit

/// The window's title-bar strip: traffic lights on the left, a centered
/// search field like VS Code's command center (drawn, not a real text field;
/// clicking it opens the palette), and an Update button on the right that
/// exists only while a newer release is available.
final class TitleBarView: NSView {
    /// Matches the standard title bar so the traffic lights stay centered.
    static let height: CGFloat = 28

    let searchField = TitleSearchField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)
        let preferredWidth = searchField.widthAnchor.constraint(equalToConstant: 420)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            searchField.centerXAnchor.constraint(equalTo: centerXAnchor),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 20),
            preferredWidth,
            // Stay clear of the traffic lights on narrow windows.
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 84),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var updateButton: NSButton?
    private var onUpdate: (() -> Void)?

    /// Shows "Update to <version>" at the right end, or removes it (nil).
    func showUpdate(version: String?, action: (() -> Void)? = nil) {
        guard let version else {
            updateButton?.removeFromSuperview()
            updateButton = nil
            return
        }
        onUpdate = action
        let button = updateButton ?? makeUpdateButton()
        button.title = "Update to \(version)"
        button.isEnabled = true
        button.toolTip = "Pulse \(version) is available (you have \(Updater.currentVersion))"
    }

    /// While the download runs.
    func showUpdating() {
        updateButton?.title = "Updating…"
        updateButton?.isEnabled = false
    }

    private func makeUpdateButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(updateClicked))
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        button.bezelColor = .controlAccentColor
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
        ])
        updateButton = button
        return button
    }

    @objc private func updateClicked() { onUpdate?() }

    override var mouseDownCanMoveWindow: Bool { true }

    // A layer color instead of draw(_:) so the strip needs no backing store.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.chromeBackground.cgColor
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        // Honor System Settings › Desktop & Dock › "Double-click a window's title bar to".
        if UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") == "Minimize" {
            window?.performMiniaturize(nil)
        } else {
            window?.performZoom(nil)
        }
    }
}

/// A rounded, field-looking button: magnifier plus the folder name. The
/// shape is layer properties and the text a plain label, so the only pixels
/// stored are the label's.
final class TitleSearchField: NSView {
    var onClick: (() -> Void)?

    var title = "Search" {
        didSet { label.stringValue = title; setAccessibilityLabel(title) }
    }

    private let label = NSTextField(labelWithString: "Search")

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        toolTip = "Go to File (⌘P)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, label])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 5
        layer.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.labelColor.withAlphaComponent(isHovered ? 0.09 : 0.05).cgColor
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // The icon and label are decoration; the whole field is the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
