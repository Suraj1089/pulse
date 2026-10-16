import AppKit
import SwiftTerm

/// The integrated terminal. The SwiftTerm view and the shell are created the
/// first time the panel is shown, never at launch. Hiding the panel keeps the
/// shell alive; "Kill Terminal" ends it.
final class TerminalPanel: NSView, LocalProcessTerminalViewDelegate {
    var onTitleChange: ((String) -> Void)?

    private var terminalView: LocalProcessTerminalView?
    private let header = NSTextField(labelWithString: "Terminal")
    private var isRunning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hasStarted: Bool { terminalView != nil }

    func startIfNeeded(in directory: URL?) {
        guard terminalView == nil else { return }
        let view = LocalProcessTerminalView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.font = Theme.terminalFont
        view.processDelegate = self
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        terminalView = view
        applyColors()

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser
        view.startProcess(executable: shell, args: [], environment: nil, execName: "-" + shellName,
                          currentDirectory: (directory ?? home).path)
        isRunning = true
        header.stringValue = "Terminal — \(shellName)"
    }

    /// SwiftTerm turns its colors into fixed values when they are set, so
    /// they are set again whenever light/dark changes (View › Appearance or macOS).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        guard let terminalView else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            terminalView.nativeBackgroundColor = Theme.editorBackground
            terminalView.nativeForegroundColor = Theme.text
        }
    }

    /// View › Font Size › Terminal; a running shell keeps going, its grid reflows.
    func applyFontSize() {
        terminalView?.font = Theme.terminalFont
    }

    func focus() {
        if let terminalView { window?.makeFirstResponder(terminalView) }
    }

    /// Ends the shell (and anything it started) and frees the view.
    func kill() {
        terminalView?.terminate()
        terminalView?.removeFromSuperview()
        terminalView = nil
        isRunning = false
        header.stringValue = "Terminal"
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.header.stringValue = "Terminal — exited. Toggle the panel to start a new shell."
            self.terminalView?.removeFromSuperview()
            self.terminalView = nil
        }
    }
}
