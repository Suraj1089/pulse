import AppKit
import SwiftTerm

/// The integrated terminal panel, like VS Code's: tabs of terminals, each tab
/// one or more side-by-side panes, each pane its own shell started in the
/// open folder. Nothing is created until the panel is first shown; every
/// extra terminal is created only when asked for (+ or split). Hiding the
/// panel keeps the shells alive; a shell that exits removes its pane, and
/// `onEmpty` fires when the last one is gone.
final class TerminalPanel: NSView {
    var onTitleChange: ((String) -> Void)?
    /// The last terminal closed or exited.
    var onEmpty: (() -> Void)?
    /// Extra variables for each new shell (Claude Code's IDE connection),
    /// asked for when the shell starts.
    var environment: (() -> [String])?

    private var tabs: [TerminalTab] = []
    private var activeTab: TerminalTab?
    private let tabStrip = NSStackView()
    private let content = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let title = NSTextField(labelWithString: "TERMINAL")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.setContentHuggingPriority(.required, for: .horizontal)

        tabStrip.spacing = 2
        tabStrip.setHuggingPriority(.defaultLow, for: .horizontal)

        let add = TerminalPanel.headerButton("plus", "New Terminal (⌃⇧`)", #selector(MainWindowController.newTerminal(_:)))
        let split = TerminalPanel.headerButton("square.split.2x1", "Split Terminal (⌘\\)", #selector(MainWindowController.splitTerminal(_:)))
        let trash = TerminalPanel.headerButton("trash", "Kill Terminal", #selector(MainWindowController.killTerminal(_:)))

        let header = NSStackView(views: [title, tabStrip, NSView(), add, split, trash])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 6)
        [header, content].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Header buttons send menu commands through the responder chain, so
    /// they behave exactly like View › New Terminal and friends.
    private static func headerButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    // MARK: State

    var hasStarted: Bool { !tabs.isEmpty }
    var terminalCount: Int { tabs.reduce(0) { $0 + $1.sessions.count } }
    var tabCount: Int { tabs.count }
    /// Panes in the tab on screen (for tests and the tab title).
    var activePaneCount: Int { activeTab?.sessions.count ?? 0 }
    var activeDirectories: [URL] { activeTab?.sessions.map(\.directory) ?? [] }

    /// The first terminal, when the panel is shown with none running.
    func startIfNeeded(in directory: URL?) {
        if tabs.isEmpty { newTerminal(in: directory) }
    }

    /// A new tab with one shell in `directory` (the open folder).
    func newTerminal(in directory: URL?) {
        let tab = TerminalTab()
        tabs.append(tab)
        add(TerminalSession(directory: directory), to: tab)
        select(tab)
    }

    /// Another shell beside the focused one, in the same tab.
    func splitTerminal(in directory: URL?) {
        guard let tab = activeTab else { newTerminal(in: directory); return }
        add(TerminalSession(directory: directory), to: tab)
    }

    /// Ends the focused shell (or the last one in the tab on screen).
    func killActive() {
        if let session = focusedSession { close(session) }
    }

    /// Ends every shell and frees every view.
    func killAll() {
        tabs.flatMap(\.sessions).forEach { $0.terminate() }
        tabs.forEach { $0.split.removeFromSuperview() }
        tabs = []
        activeTab = nil
        refreshTabs()
    }

    func focus() {
        if let session = focusedSession ?? activeTab?.sessions.last { window?.makeFirstResponder(session.view) }
    }

    /// The focused shell's process id, to find the Claude Code running in it.
    var focusedShellPID: pid_t? {
        guard let pid = focusedSession?.shellPID, pid > 0 else { return nil }
        return pid
    }

    /// View › Font Size › Terminal; running shells keep going, their grids reflow.
    func applyFontSize() {
        tabs.flatMap(\.sessions).forEach { $0.view.font = Theme.terminalFont }
    }

    /// SwiftTerm turns its colors into fixed values when they are set, so
    /// they are set again whenever light/dark changes (View › Appearance or macOS).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tabs.flatMap(\.sessions).forEach(applyColors)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
    }

    // MARK: Tabs and panes

    private var focusedSession: TerminalSession? {
        guard let tab = activeTab else { return nil }
        if let responder = window?.firstResponder as? NSView,
           let session = tab.sessions.first(where: { responder.isDescendant(of: $0.view) }) {
            return session
        }
        return tab.sessions.last
    }

    private func add(_ session: TerminalSession, to tab: TerminalTab) {
        session.view.font = Theme.terminalFont
        applyColors(session)
        session.onTitleChange = { [weak self, weak tab] title in
            self?.onTitleChange?(title)
            // Shells title their window "user@host:/path/to/folder"; the tab
            // shows the last part ("folder", or the running command).
            let short = (title as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
            if let tab, !short.isEmpty { tab.title = short; self?.refreshTabs() }
        }
        session.onExit = { [weak self] session in self?.close(session) }
        tab.sessions.append(session)
        tab.split.addArrangedSubview(session.view)
        equalize(tab)
        session.start(adding: environment?() ?? [])
        refreshTabs()
        window?.makeFirstResponder(session.view)
    }

    private func close(_ session: TerminalSession) {
        guard let tab = tabs.first(where: { $0.sessions.contains { $0 === session } }) else { return }
        session.terminate()
        session.view.removeFromSuperview()
        tab.sessions.removeAll { $0 === session }
        if tab.sessions.isEmpty {
            let index = tabs.firstIndex { $0 === tab } ?? 0
            tab.split.removeFromSuperview()
            tabs.remove(at: index)
            if activeTab === tab {
                activeTab = nil
                if !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)]) }
            }
        } else {
            equalize(tab)
        }
        refreshTabs()
        if tabs.isEmpty { onEmpty?() } else { focus() }
    }

    /// Splitting or closing a pane leaves every pane in the tab the same width.
    private func equalize(_ tab: TerminalTab) {
        let split = tab.split
        split.adjustSubviews()
        split.layoutSubtreeIfNeeded()
        let count = split.arrangedSubviews.count
        guard count > 1, split.bounds.width > 0 else { return }
        let pane = (split.bounds.width - CGFloat(count - 1) * split.dividerThickness) / CGFloat(count)
        for index in 0..<(count - 1) {
            split.setPosition(CGFloat(index + 1) * pane + CGFloat(index) * split.dividerThickness, ofDividerAt: index)
        }
    }

    private func select(_ tab: TerminalTab) {
        activeTab?.split.removeFromSuperview()
        activeTab = tab
        tab.split.frame = content.bounds
        tab.split.autoresizingMask = [.width, .height]
        content.addSubview(tab.split)
        refreshTabs()
        focus()
    }

    private func refreshTabs() {
        tabStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // A single terminal needs no tab bar of its own: the header says TERMINAL.
        guard tabs.count > 1 || (tabs.first?.sessions.count ?? 0) > 1 else { return }
        for (index, tab) in tabs.enumerated() {
            let panes = tab.sessions.count > 1 ? " (\(tab.sessions.count))" : ""
            let button = TerminalTabButton(title: "\(index + 1): \(tab.title)\(panes)", selected: tab === activeTab) { [weak self, weak tab] in
                if let tab { self?.select(tab) }
            }
            tabStrip.addArrangedSubview(button)
        }
    }

    private func applyColors(_ session: TerminalSession) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            session.view.nativeBackgroundColor = Theme.editorBackground
            session.view.nativeForegroundColor = Theme.text
        }
    }
}

/// One tab: its panes side by side.
private final class TerminalTab {
    let split: NSSplitView = {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        return split
    }()
    var title: String
    /// Owns the sessions (SwiftTerm only keeps a weak delegate).
    var sessions: [TerminalSession] = []

    init() {
        title = ((ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") as NSString).lastPathComponent
    }
}

/// One shell and its SwiftTerm view. The session reads the shell's output
/// itself, on the main queue into one buffer shared by every terminal, and
/// feeds it to the view as it arrives. SwiftTerm's LocalProcess reads through
/// DispatchIO, which allocates a new buffer of up to 128 KB for every read (a
/// PTY read returns at most 1 KB) and then queues a copy of each read (up to
/// 4 MB); a burst of output churned enough heap to add 15–70 MB until it settled.
/// Here the PTY's own buffer is the only queue: while Pulse is busy, the shell
/// waits, as in any terminal.
private final class TerminalSession: TerminalViewDelegate {
    let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let directory: URL
    var onTitleChange: ((String) -> Void)?
    var onExit: ((TerminalSession) -> Void)?
    private(set) var shellPID: pid_t = 0
    private var pty: Int32 = -1
    private var outputSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var running = false

    /// Every terminal reads into this one: reads and feeds happen on the main queue.
    private static var buffer = [UInt8](repeating: 0, count: 16 * 1024)

    init(directory: URL?) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
        view.terminalDelegate = self
    }

    deinit {
        outputSource?.cancel()
        exitSource?.cancel()
    }

    /// `extra` goes on top of SwiftTerm's usual environment.
    func start(adding extra: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let environment = Terminal.getEnvironmentVariables(termName: "xterm-256color") + extra
        var size = windowSize()
        guard let (pid, pty) = PseudoTerminalHelpers.fork(andExec: shell, args: ["-" + (shell as NSString).lastPathComponent],
                                                          env: environment, currentDirectory: directory.path,
                                                          desiredWindowSize: &size) else { return }
        shellPID = pid
        self.pty = pty
        running = true
        _ = fcntl(pty, F_SETFL, fcntl(pty, F_GETFL) | O_NONBLOCK)

        let outputSource = DispatchSource.makeReadSource(fileDescriptor: pty, queue: .main)
        outputSource.setEventHandler { [weak self] in self?.readOutput() }
        outputSource.setCancelHandler { close(pty) }
        outputSource.resume()
        self.outputSource = outputSource

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            self?.exited()
        }
        exitSource.resume()
        self.exitSource = exitSource
    }

    func terminate() {
        closeOutput()
        guard running else { return }
        running = false
        kill(shellPID, SIGTERM)
    }

    /// Feeds what the shell wrote, up to a buffer at a time, for at most 8 ms;
    /// the source fires again while more is waiting, so typing and drawing
    /// carry on during a flood.
    private func readOutput() {
        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000
        var count = 0
        while true {
            let n = Self.buffer.withUnsafeMutableBytes { read(pty, $0.baseAddress! + count, $0.count - count) }
            let error = n < 0 ? errno : 0
            if n > 0 {
                count += n
                if count < Self.buffer.count { continue }
            } else if error == EINTR {
                continue
            }
            // The buffer is full, the shell has nothing more for now, or its output ended.
            if count > 0 {
                view.feed(byteArray: Self.buffer[..<count])
                count = 0
            }
            if n == 0 || (n < 0 && error != EAGAIN) { closeOutput(); return }
            if n < 0 || DispatchTime.now().uptimeNanoseconds >= deadline { return }
        }
    }

    private func closeOutput() {
        outputSource?.cancel()   // its cancel handler closes the PTY
        outputSource = nil
        pty = -1
    }

    private func exited() {
        exitSource?.cancel()
        guard running else { return }
        running = false
        onExit?(self)
    }

    /// What the shell sees as its window: cells, and pixels for programs that draw images.
    private func windowSize() -> winsize {
        let terminal = view.getTerminal()
        let cell = view.cellSizeInPixels(source: terminal) ?? (width: 0, height: 0)
        return winsize(ws_row: UInt16(clamping: terminal.rows), ws_col: UInt16(clamping: terminal.cols),
                       ws_xpixel: UInt16(clamping: cell.width * terminal.cols), ws_ypixel: UInt16(clamping: cell.height * terminal.rows))
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard pty >= 0 else { return }
        data.withUnsafeBytes { bytes in
            DispatchIO.write(toFileDescriptor: pty, data: DispatchData(bytes: bytes), runningHandlerOn: .main) { _, _ in }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard pty >= 0 else { return }
        var size = windowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: pty, windowSize: &size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitleChange?(title)
    }

    /// OSC 52 copy and paste, as SwiftTerm's LocalProcessTerminalView does them.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A tab in the terminal header: "2: zsh (2)".
private final class TerminalTabButton: NSButton {
    private let onSelect: () -> Void

    init(title: String, selected: Bool, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .recessed
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        setButtonType(.pushOnPushOff)
        state = selected ? .on : .off
        target = self
        action = #selector(clicked)
        lineBreakMode = .byTruncatingMiddle
        widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        toolTip = title
        setAccessibilityLabel("Terminal \(title)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { onSelect() }
}
