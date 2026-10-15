import AppKit

/// The single Pulse window: sidebar + editor. Menu commands arrive here
/// through the responder chain.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let splitController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    var sidebarForTesting: SidebarViewController { sidebar }
    let editor = EditorViewController()
    private let palette = CommandPalette()
    private let titleBar = TitleBarView()
    private let resources = ResourceMonitor()
    private var sidebarItem: NSSplitViewItem!

    private(set) var root: URL?
    private var fileIndex: FileIndex?
    private var sessionWork: DispatchWorkItem?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.title = "Pulse"
        super.init(window: window)

        // A plain split item, not a "sidebar" one: on macOS 26 those float as an
        // inset glass card. Like VS Code, the sidebar is a flush column level with
        // the tabs, separated from the editor by a thin divider.
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)  // keeps its width as the window resizes
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 360
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(editorItem)
        splitController.splitView.autosaveName = "PulseSidebarSplit"
        splitController.splitView.dividerStyle = .thin

        // Title strip on top, sidebar + editor below it.
        let content = NSViewController()
        content.view = NSView()
        content.addChild(splitController)
        let splitView = splitController.view
        [titleBar, splitView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: content.view.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: TitleBarView.height),
            splitView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
        ])
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 640, height: 420)
        if !window.setFrameUsingName("PulseMainWindow") { window.center() }
        // First launch: a sidebar wide enough for nested file names. Later
        // launches use the width the user left it at (autosaved).
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames PulseSidebarSplit") == nil {
            splitController.splitView.setPosition(250, ofDividerAt: 0)
        }
        window.setFrameAutosaveName("PulseMainWindow")
        window.delegate = self

        wire()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func wire() {
        sidebar.fileTree.onOpenFile = { [weak self] url in self?.editor.open(url) }
        sidebar.fileTree.onFilesChanged = { [weak self] in self?.fileIndex?.invalidate() }
        sidebar.searchPanel.onOpenMatch = { [weak self] url, match in
            guard let self else { return }
            self.editor.open(url)
            self.editor.reveal(line: match.line, column: match.column, length: match.length)
        }
        editor.onActiveDocumentChange = { [weak self] document in
            guard let self else { return }
            self.window?.title = document?.displayName ?? "Pulse"
            self.window?.representedURL = document?.url
            if let url = document?.url { self.sidebar.fileTree.reveal(url) }
        }
        editor.onSessionChange = { [weak self] in self?.scheduleSessionSave() }
        editor.onDidSave = { [weak self] document in
            guard let self else { return }
            self.sidebar.sourceControl.refresh()
            if document.url?.standardizedFileURL == KeyBindings.fileURL.standardizedFileURL {
                self.editor.statusBar.showMessage(KeyBindings.reloadFromFile().map { "keybindings.json: \($0)" })
            }
        }
        // The visual editor rewrote keybindings.json: refresh an open, unedited JSON tab.
        NotificationCenter.default.addObserver(forName: .keyBindingsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.editor.reloadChangedDocuments()
        }
        sidebar.sourceControl.onOpenFile = { [weak self] url in self?.editor.open(url) }
        editor.onOpenRequest = { [weak self] in self?.openDocument(nil) }
        editor.onOpenRecent = { [weak self] url in self?.open([url]) }
        editor.setRecents(RecentFolders.all)

        resources.onUpdate = { [weak self] snapshot in self?.editor.statusBar.showResources(snapshot) }

        titleBar.searchField.onClick = { [weak self] in
            guard let self else { return }
            if self.root == nil { self.showCommandPalette(nil) } else { self.showGoToFile(nil) }
        }

        palette.commands = { [weak self] in self?.paletteCommands() ?? [] }
        palette.files = { [weak self] completion in
            guard let index = self?.fileIndex else { completion([]); return }
            index.withPaths(completion)
        }
        palette.openFile = { [weak self] path in
            guard let self, let root = self.root else { return }
            self.editor.open(root.appendingPathComponent(path))
        }
        palette.goToLine = { [weak self] line in self?.editor.goToLine(line) }
    }

    // MARK: Opening

    func open(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                setRoot(url)
            } else {
                if root == nil { setRoot(url.deletingLastPathComponent()) }
                editor.open(url)
            }
        }
    }

    func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        root = url
        fileIndex = url.map { FileIndex(root: $0) }
        sidebar.fileTree.setRoot(url)
        sidebar.searchPanel.root = url
        sidebar.searchPanel.index = fileIndex
        sidebar.searchPanel.clear()
        sidebar.sourceControl.root = url
        showBranch()
        editor.terminalDirectory = url
        titleBar.searchField.title = url?.lastPathComponent ?? "Search"
        if let url {
            RecentFolders.add(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            editor.setRecents(RecentFolders.all)
        }
        scheduleSessionSave()
    }

    // MARK: Session

    func restoreSession() {
        guard let state = SessionState.load() else { return }
        if let path = state.root, FileManager.default.fileExists(atPath: path) {
            setRoot(URL(fileURLWithPath: path, isDirectory: true))
        }
        for entry in state.entries {
            let document: Document?
            if let special = entry.special {
                document = Document(special: special)
            } else if let path = entry.path {
                let url = URL(fileURLWithPath: path)
                if let text = entry.unsavedText {
                    document = Document(url: url, text: text)
                    document?.isDirty = true
                } else {
                    document = try? Document.open(url)
                }
            } else if let text = entry.unsavedText {
                document = Document(url: nil, text: text)
                document?.isDirty = true
            } else {
                document = nil
            }
            guard let document else { continue }
            document.selectedRange = NSRange(location: min(entry.selection, document.length), length: 0)
            editor.add(document, activate: false)
        }
        if let active = state.active, editor.documents.indices.contains(active) {
            editor.activate(active)
        } else if !editor.documents.isEmpty {
            editor.activate(0)
        }
        if state.terminalOpen { editor.showTerminal() }
    }

    func scheduleSessionSave() {
        sessionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func saveSession() {
        sessionWork?.cancel()
        if let active = editor.activeDocument { active.selectedRange = editor.textView.selectedRange() }
        let entries = editor.documents.map { document in
            SessionState.Entry(
                path: document.url?.path,
                unsavedText: document.isDirty ? document.storage.string : nil,
                selection: document.selectedRange.location,
                special: document.special
            )
        }
        SessionState(root: root?.path, entries: entries, active: editor.activeIndex,
                     terminalOpen: editor.isTerminalVisible).save()
    }

    /// Called when Pulse quits or the window closes.
    func prepareForQuit() {
        if EditorViewController.autosaveEnabled { editor.saveNamedDocuments() }
        saveSession()
    }

    // MARK: App activation

    // MARK: Terminal command

    /// Release builds: once, without asking (see CommandLineTool).
    func installCommandLineToolIfNeeded() {
        CommandLineTool.installAutomaticallyIfNeeded { [weak self] outcome in
            if case .installed(let folder) = outcome {
                self?.editor.statusBar.showMessage("Installed the pulse command in \(folder). Run “pulse .” in a terminal.", isWarning: false)
            }
        }
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        CommandLineTool.install { [weak self] outcome in
            if case .needsPassword = outcome {
                CommandLineTool.installWithPassword { self?.report(outcome: $0) }
            } else {
                self?.report(outcome: outcome)
            }
        }
    }

    private func report(outcome: CommandLineTool.Outcome) {
        guard let window else { return }
        let alert = NSAlert()
        switch outcome {
        case .installed(let folder), .alreadyInstalled(let folder):
            alert.messageText = "The pulse command is installed"
            alert.informativeText = "It's in \(folder). Open a new terminal and run “pulse .” to open a folder, or “pulse file.swift” to open a file."
            NotificationCenter.default.post(name: .commandLineToolDidChange, object: nil)
        case .unavailable(let reason):
            alert.messageText = "Couldn't install the pulse command"
            alert.informativeText = reason
            // The by-hand fallback, when this copy of Pulse has the script to link to.
            if FileManager.default.isExecutableFile(atPath: CommandLineTool.script.path) {
                alert.informativeText += "\n\nTo install it yourself, run this in Terminal:\n\(CommandLineTool.manualCommand)"
                alert.addButton(withTitle: "Copy Command")
                alert.addButton(withTitle: "Close")
            }
        case .needsPassword:
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard case .unavailable(_) = outcome, response == .alertFirstButtonReturn,
                  alert.buttons.count > 1 else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(CommandLineTool.manualCommand, forType: .string)
        }
    }

    // MARK: Updates

    /// At launch and on activation; Updater limits real checks to once a day.
    func checkForUpdatesIfDue() {
        Updater.checkIfDue { [weak self] release in
            guard let self, let release else { return }
            self.offer(release)
        }
    }

    private func offer(_ release: Updater.Release) {
        titleBar.showUpdate(version: release.version) { [weak self] in self?.install(release) }
    }

    private func install(_ release: Updater.Release) {
        titleBar.showUpdating()
        Updater.install(release) { [weak self] error in
            guard let self, let window = self.window else { return }
            self.offer(release)
            let alert = NSAlert()
            alert.messageText = "Pulse couldn't update itself"
            alert.informativeText = error.text
            alert.addButton(withTitle: "Open Releases Page")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            }
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.latest { [weak self] result in
            guard let self, let window = self.window else { return }
            let alert = NSAlert()
            switch result {
            case .success(let release) where Updater.isVersion(release.version, newerThan: Updater.currentVersion):
                self.offer(release)
                alert.messageText = "Pulse \(release.version) is available"
                alert.informativeText = "You have \(Updater.currentVersion). Pulse will quit, update and reopen with your tabs."
                alert.addButton(withTitle: "Update Now")
                alert.addButton(withTitle: "Later")
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { self.install(release) }
                }
            case .success:
                alert.messageText = "Pulse is up to date"
                alert.informativeText = "You have version \(Updater.currentVersion), the latest release."
                alert.beginSheetModal(for: window)
            case .failure(let error):
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = error.text
                alert.beginSheetModal(for: window)
            }
        }
    }

    func appDidBecomeActive() {
        sidebar.fileTree.refresh()
        fileIndex?.invalidate()
        editor.reloadChangedDocuments()
        checkForUpdatesIfDue()
        showBranch()
        sidebar.sourceControl.refresh()
        resources.start()
    }

    func appDidResignActive() {
        resources.stop()
        if EditorViewController.autosaveEnabled { editor.saveNamedDocuments() }
        saveSession()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        prepareForQuit()
    }

    // MARK: Commands (responder chain)

    @objc func newFile(_ sender: Any?) { editor.newDocument() }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a folder to work in, or files to open."
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc func saveDocument(_ sender: Any?) { editor.saveActive() }
    @objc func saveDocumentAs(_ sender: Any?) { editor.saveActive(as: true) }
    @objc func saveAllDocuments(_ sender: Any?) { editor.saveAll() }
    @objc func closeTab(_ sender: Any?) { editor.closeActive() }
    @objc func nextTab(_ sender: Any?) { editor.selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { editor.selectTab(offset: -1) }

    @objc func showCommandPalette(_ sender: Any?) { showPalette(">") }
    @objc func showGoToFile(_ sender: Any?) { showPalette("") }
    @objc func showGoToLine(_ sender: Any?) { showPalette(":") }

    private func showPalette(_ prefix: String) {
        guard let window else { return }
        palette.show(over: window, initialText: prefix)
    }

    @objc func findInProject(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        sidebar.showSearch(seed: editor.selectedText)
    }

    @objc func showFiles(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        sidebar.showFiles()
    }

    /// Replaces NSSplitViewController.toggleSidebar(_:), which only acts on
    /// "sidebar"-behavior items.
    @objc func toggleSidebarVisibility(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
    }

    @objc func showSourceControl(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        sidebar.showSourceControl()
    }

    /// Reads .git/HEAD; no process. Runs on folder change and app activation.
    private func showBranch() {
        let branch = root.flatMap(GitStatus.repositoryRoot).flatMap(GitStatus.branch)
        editor.statusBar.showBranch(branch)
    }

    @objc func openKeyboardShortcuts(_ sender: Any?) { editor.openSpecial(.keyboardShortcuts) }

    @objc func openKeyboardShortcutsJSON(_ sender: Any?) {
        KeyBindings.ensureFile()
        editor.open(KeyBindings.fileURL)
    }

    @objc func toggleTerminal(_ sender: Any?) { editor.toggleTerminal() }
    @objc func killTerminal(_ sender: Any?) { editor.killTerminal() }
    @objc func toggleComment(_ sender: Any?) { editor.textView.toggleLineComment() }
    @objc func indentLines(_ sender: Any?) { editor.textView.shiftLines(right: true) }
    @objc func outdentLines(_ sender: Any?) { editor.textView.shiftLines(right: false) }
    // ⌘+ / ⌘− / ⌘0 resize the area being worked in; View › Font Size names one.
    @objc func zoomIn(_ sender: Any?) { changeFontSize(of: focusedFontArea, by: 1) }
    @objc func zoomOut(_ sender: Any?) { changeFontSize(of: focusedFontArea, by: -1) }
    @objc func resetZoom(_ sender: Any?) { changeFontSize(of: focusedFontArea, by: nil) }
    @objc func editorFontBigger(_ sender: Any?) { changeFontSize(of: .editor, by: 1) }
    @objc func editorFontSmaller(_ sender: Any?) { changeFontSize(of: .editor, by: -1) }
    @objc func editorFontReset(_ sender: Any?) { changeFontSize(of: .editor, by: nil) }
    @objc func sidebarFontBigger(_ sender: Any?) { changeFontSize(of: .sidebar, by: 1) }
    @objc func sidebarFontSmaller(_ sender: Any?) { changeFontSize(of: .sidebar, by: -1) }
    @objc func sidebarFontReset(_ sender: Any?) { changeFontSize(of: .sidebar, by: nil) }
    @objc func terminalFontBigger(_ sender: Any?) { changeFontSize(of: .terminal, by: 1) }
    @objc func terminalFontSmaller(_ sender: Any?) { changeFontSize(of: .terminal, by: -1) }
    @objc func terminalFontReset(_ sender: Any?) { changeFontSize(of: .terminal, by: nil) }

    /// The terminal or the sidebar when the keyboard is in them, else the editor.
    private var focusedFontArea: FontArea {
        guard let focused = window?.firstResponder as? NSView else { return .editor }
        if editor.terminalContains(focused) { return .terminal }
        if focused.isDescendant(of: sidebar.view) { return .sidebar }
        return .editor
    }

    /// nil resets the area to its default size.
    func changeFontSize(of area: FontArea, by delta: CGFloat?) {
        Theme.setFontSize(delta.map { Theme.fontSize(for: area) + $0 }, for: area)
        switch area {
        case .editor:
            editor.applyEditorFontSize()
            // A terminal that follows the editor's size (never set on its own) follows it now too.
            editor.applyTerminalFontSize()
        case .sidebar: sidebar.applyFontSize()
        case .terminal: editor.applyTerminalFontSize()
        }
        let size = Theme.fontSize(for: area)
        let points = size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
        editor.statusBar.showMessage("\(area.title) font: \(points) pt", isWarning: false, duration: 2)
    }

    // MARK: Welcome and appearance

    @objc func showWelcome(_ sender: Any?) { editor.openSpecial(.welcome) }

    /// At launch: the first time Pulse opens with nothing to show, and every
    /// launch when "Show on launch" is ticked.
    func showWelcomeIfNeeded() {
        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: "welcomeShown")
        defaults.set(true, forKey: "welcomeShown")
        let isEmpty = root == nil && editor.documents.isEmpty
        if (firstLaunch && isEmpty) || WelcomeController.showsOnLaunch {
            editor.openSpecial(.welcome)
        }
    }

    @objc func useAutoAppearance(_ sender: Any?) { AppAppearance.current = .auto }
    @objc func useLightAppearance(_ sender: Any?) { AppAppearance.current = .light }
    @objc func useDarkAppearance(_ sender: Any?) { AppAppearance.current = .dark }
    @objc func toggleWordWrap(_ sender: Any?) { editor.toggleWrap() }

    @objc func toggleAutosave(_ sender: Any?) {
        EditorViewController.autosaveEnabled.toggle()
        if EditorViewController.autosaveEnabled { editor.saveNamedDocuments() }
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = editor.activeDocument?.url ?? root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copyFilePath(_ sender: Any?) {
        guard let url = editor.activeDocument?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Text commands need a text tab, not a special one like Keyboard Shortcuts.
        let hasDocument = editor.activeDocument.map { $0.special == nil } ?? false
        switch menuItem.action {
        case #selector(toggleAutosave(_:)):
            menuItem.state = EditorViewController.autosaveEnabled ? .on : .off
            return true
        case #selector(toggleWordWrap(_:)):
            menuItem.state = EditorViewController.wrapLines ? .on : .off
            return true
        case #selector(toggleTerminal(_:)):
            menuItem.title = editor.isTerminalVisible ? "Hide Terminal" : "Show Terminal"
            return true
        case #selector(useAutoAppearance(_:)):
            menuItem.state = AppAppearance.current == .auto ? .on : .off
            return true
        case #selector(useLightAppearance(_:)):
            menuItem.state = AppAppearance.current == .light ? .on : .off
            return true
        case #selector(useDarkAppearance(_:)):
            menuItem.state = AppAppearance.current == .dark ? .on : .off
            return true
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(toggleComment(_:)),
             #selector(indentLines(_:)), #selector(outdentLines(_:)), #selector(showGoToLine(_:)),
             #selector(copyFilePath(_:)):
            return hasDocument
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return editor.documents.count > 1
        case #selector(findInProject(_:)), #selector(showGoToFile(_:)), #selector(showSourceControl(_:)):
            return root != nil
        default:
            return true
        }
    }

    // MARK: Palette commands

    private func paletteCommands() -> [PaletteCommand] {
        // Shortcut labels come from the live menu, so they follow rebinding.
        func command(_ title: String, _ action: Selector, to target: AnyObject? = nil) -> PaletteCommand {
            PaletteCommand(title: title, shortcut: KeyBindings.display(for: action)) { [weak self] in
                NSApp.sendAction(action, to: target ?? self, from: nil)
            }
        }
        var commands: [PaletteCommand] = [
            command("File: New File", #selector(newFile(_:))),
            command("File: Open…", #selector(openDocument(_:))),
            command("File: Save", #selector(saveDocument(_:))),
            command("File: Save As…", #selector(saveDocumentAs(_:))),
            command("File: Save All", #selector(saveAllDocuments(_:))),
            command("File: Close Tab", #selector(closeTab(_:))),
            command("File: Toggle Autosave", #selector(toggleAutosave(_:))),
            command("File: Reveal in Finder", #selector(revealInFinder(_:))),
            command("File: Copy Path", #selector(copyFilePath(_:))),
            command("Go: Go to File", #selector(showGoToFile(_:))),
            command("Go: Go to Line", #selector(showGoToLine(_:))),
            command("Go: Next Tab", #selector(nextTab(_:))),
            command("Go: Previous Tab", #selector(previousTab(_:))),
            command("Search: Find in Project", #selector(findInProject(_:))),
            command("Edit: Toggle Line Comment", #selector(toggleComment(_:))),
            command("Edit: Indent Lines", #selector(indentLines(_:))),
            command("Edit: Outdent Lines", #selector(outdentLines(_:))),
            command("View: Toggle Sidebar", #selector(toggleSidebarVisibility(_:))),
            command("View: Show Files", #selector(showFiles(_:))),
            command("View: Show Source Control", #selector(showSourceControl(_:))),
            command("View: Toggle Word Wrap", #selector(toggleWordWrap(_:))),
            command("View: Zoom In", #selector(zoomIn(_:))),
            command("View: Zoom Out", #selector(zoomOut(_:))),
            command("View: Reset Zoom", #selector(resetZoom(_:))),
            command("Editor: Bigger Font", #selector(editorFontBigger(_:))),
            command("Editor: Smaller Font", #selector(editorFontSmaller(_:))),
            command("Editor: Reset Font Size", #selector(editorFontReset(_:))),
            command("Sidebar: Bigger Font", #selector(sidebarFontBigger(_:))),
            command("Sidebar: Smaller Font", #selector(sidebarFontSmaller(_:))),
            command("Sidebar: Reset Font Size", #selector(sidebarFontReset(_:))),
            command("Terminal: Bigger Font", #selector(terminalFontBigger(_:))),
            command("Terminal: Smaller Font", #selector(terminalFontSmaller(_:))),
            command("Terminal: Reset Font Size", #selector(terminalFontReset(_:))),
            command("Preferences: Appearance: Auto", #selector(useAutoAppearance(_:))),
            command("Preferences: Appearance: Light", #selector(useLightAppearance(_:))),
            command("Preferences: Appearance: Dark", #selector(useDarkAppearance(_:))),
            command("Help: Welcome", #selector(showWelcome(_:))),
            command("Terminal: Toggle Terminal", #selector(toggleTerminal(_:))),
            command("Terminal: Kill Terminal", #selector(killTerminal(_:))),
            command("Preferences: Open Keyboard Shortcuts", #selector(openKeyboardShortcuts(_:))),
            command("Pulse: Check for Updates", #selector(checkForUpdates(_:))),
            command("Shell Command: Install 'pulse' Command in PATH", #selector(installCommandLineTool(_:))),
            command("Preferences: Open Keyboard Shortcuts (JSON)", #selector(openKeyboardShortcutsJSON(_:))),
        ]
        for url in RecentFolders.all.prefix(5) where url != root {
            commands.append(PaletteCommand(title: "Open Recent: \(url.lastPathComponent)", shortcut: "") { [weak self] in
                self?.open([url])
            })
        }
        return commands
    }
}
