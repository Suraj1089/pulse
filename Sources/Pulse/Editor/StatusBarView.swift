import AppKit

/// Bottom strip: git branch, the file's mode, caret position, language,
/// indentation, Pulse's own memory and CPU next to whatever the terminal is
/// running, and a bug button.
final class StatusBarView: NSView {
    static let height: CGFloat = 24

    private let branch = StatusBarView.makeLabel()
    private let position = StatusBarView.makeLabel()
    private let language = StatusBarView.makeLabel()
    private let indentation = StatusBarView.makeLabel()
    private let encoding = StatusBarView.makeLabel()
    private let message = StatusBarView.makeLabel()
    private let claude = StatusBarView.makeLabel()
    private let resources = StatusBarView.makeLabel()
    /// Read Only (lock) or Editing (pencil); a click switches, through the
    /// responder chain like File › Read Only.
    private let mode = NSButton(title: "", target: nil, action: #selector(MainWindowController.toggleReadOnly(_:)))
    private var showsReadOnly: Bool?
    /// Help › Report a Bug…, sent up the responder chain to the window.
    private let reportBug = NSButton(image: NSImage(systemSymbolName: "ladybug", accessibilityDescription: "Report a Bug") ?? NSImage(),
                                     target: nil, action: #selector(MainWindowController.reportBug(_:)))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        branch.isHidden = true
        mode.isBordered = false
        mode.imagePosition = .imageLeading
        mode.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        mode.contentTintColor = .secondaryLabelColor
        mode.isHidden = true
        let left = NSStackView(views: [branch, mode, position, language, indentation, encoding])
        left.spacing = 16
        message.isHidden = true
        message.textColor = .systemOrange
        message.lineBreakMode = .byTruncatingTail
        claude.isHidden = true
        claude.stringValue = "✻ Claude Code"
        claude.toolTip = "Claude Code is connected: it sees this window's open file and selection."
        reportBug.isBordered = false
        reportBug.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        reportBug.contentTintColor = .secondaryLabelColor
        reportBug.toolTip = "Report a Bug…"
        reportBug.setAccessibilityLabel("Report a Bug")
        let stack = NSStackView(views: [left, NSView(), message, claude, resources, reportBug])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        resources.toolTip = "Memory (physical footprint) of Pulse itself, and of the shells it started, measured separately."
        encoding.stringValue = "UTF-8"
        indentation.stringValue = "Spaces: 4"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func showPosition(line: Int, column: Int, selected: Int) {
        position.stringValue = selected > 0
            ? "Ln \(line), Col \(column) (\(selected) selected)"
            : "Ln \(line), Col \(column)"
    }

    func showDocument(languageName: String?, readOnly: Bool, visible: Bool) {
        language.stringValue = languageName ?? "Plain Text"
        for view in [position, language, indentation, encoding, mode] as [NSView] { view.isHidden = !visible }
        guard visible, readOnly != showsReadOnly else { return }
        showsReadOnly = readOnly
        let title = readOnly ? "Read Only" : "Editing"
        mode.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        mode.image = NSImage(systemSymbolName: readOnly ? "lock" : "pencil", accessibilityDescription: nil)
        mode.toolTip = readOnly ? "This file is read-only. Click to edit it." : "Click to make this file read-only."
        mode.setAccessibilityLabel(readOnly ? "Read only. Click to edit." : "Editing. Click to make read-only.")
    }

    func showBranch(_ name: String?) {
        branch.stringValue = name.map { "⎇ " + $0 } ?? ""
        branch.isHidden = name == nil
    }

    /// A message without a dialog: a problem such as a bad keybindings.json
    /// (orange, stays until cleared), or a note that clears itself after `duration`.
    func showMessage(_ text: String?, isWarning: Bool = true, duration: TimeInterval = 10) {
        message.stringValue = text ?? ""
        message.toolTip = text
        message.isHidden = text == nil
        message.textColor = isWarning ? .systemOrange : .secondaryLabelColor
        if let text, !isWarning {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                if self?.message.stringValue == text { self?.showMessage(nil) }
            }
        }
    }

    /// Shown while Claude Code is connected to this window.
    func showClaude(connected: Bool) {
        claude.isHidden = !connected
    }

    func showResources(_ snapshot: ResourceSnapshot) {
        var text = "Pulse \(snapshot.appMemory) · CPU \(snapshot.appCPU)"
        if let shells = snapshot.childMemory { text += "   Shell \(shells)" }
        resources.stringValue = text
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
