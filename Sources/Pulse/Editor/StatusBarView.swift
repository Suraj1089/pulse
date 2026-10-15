import AppKit

/// Bottom strip: git branch, caret position, language, indentation, and Pulse's own
/// memory and CPU next to whatever the terminal is running.
final class StatusBarView: NSView {
    static let height: CGFloat = 24

    private let branch = StatusBarView.makeLabel()
    private let position = StatusBarView.makeLabel()
    private let language = StatusBarView.makeLabel()
    private let indentation = StatusBarView.makeLabel()
    private let encoding = StatusBarView.makeLabel()
    private let message = StatusBarView.makeLabel()
    private let resources = StatusBarView.makeLabel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        branch.isHidden = true
        let left = NSStackView(views: [branch, position, language, indentation, encoding])
        left.spacing = 16
        message.isHidden = true
        message.textColor = .systemOrange
        message.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [left, NSView(), message, resources])
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

    func showDocument(languageName: String?, visible: Bool) {
        language.stringValue = languageName ?? "Plain Text"
        for label in [position, language, indentation, encoding] { label.isHidden = !visible }
    }

    func showBranch(_ name: String?) {
        branch.stringValue = name.map { "⎇ " + $0 } ?? ""
        branch.isHidden = name == nil
    }

    /// A message without a dialog: a problem such as a bad keybindings.json
    /// (orange, stays until cleared), or a note that clears itself.
    func showMessage(_ text: String?, isWarning: Bool = true) {
        message.stringValue = text ?? ""
        message.toolTip = text
        message.isHidden = text == nil
        message.textColor = isWarning ? .systemOrange : .secondaryLabelColor
        if let text, !isWarning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.message.stringValue == text { self?.showMessage(nil) }
            }
        }
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
