import AppKit

/// Shown when no file is open: open a folder, start a file, or pick a
/// recent project.
final class EmptyStateView: NSView {
    var onOpen: (() -> Void)?
    var onNewFile: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private let stack = NSStackView()
    private let recentStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let title = NSTextField(labelWithString: "Pulse")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "A light, native code editor.")
        subtitle.textColor = .secondaryLabelColor

        let open = makeButton("Open…", shortcut: "⌘O", action: #selector(openClicked))
        let newFile = makeButton("New File", shortcut: "⌘N", action: #selector(newClicked))
        let buttons = NSStackView(views: [open, newFile])
        buttons.spacing = 10

        let hints = NSTextField(labelWithString: "⌘P  Go to file     ⇧⌘P  Commands     ⌃`  Terminal     ⇧⌘F  Search")
        hints.font = .systemFont(ofSize: 11)
        hints.textColor = .tertiaryLabelColor

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        [title, subtitle, buttons, recentStack, hints].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(22, after: recentStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeButton(_ title: String, shortcut: String, action: Selector) -> NSButton {
        let button = NSButton(title: "\(title)   \(shortcut)", target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }

    func setRecents(_ urls: [URL]) {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !urls.isEmpty else { return }
        let header = NSTextField(labelWithString: "RECENT")
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        recentStack.addArrangedSubview(header)
        for url in urls.prefix(6) {
            let button = NSButton(title: url.lastPathComponent, target: self, action: #selector(recentClicked(_:)))
            button.isBordered = false
            button.contentTintColor = .linkColor
            button.toolTip = url.path
            button.identifier = NSUserInterfaceItemIdentifier(url.path)
            recentStack.addArrangedSubview(button)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
    }

    @objc private func openClicked() { onOpen?() }
    @objc private func newClicked() { onNewFile?() }
    @objc private func recentClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onOpenRecent?(URL(fileURLWithPath: path))
    }
}
