import AppKit

/// Every Pulse window. Like VS Code, a folder gets its own window: opening
/// one that is already open brings its window forward, an empty window is
/// reused, otherwise a new window opens. Files open in the window whose
/// folder holds them. Also owns what is app-wide rather than per window: the
/// saved session (all windows), the update check and the resource meter.
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [MainWindowController] = []
    /// Tests keep windows off screen.
    var showsWindows = true

    private var terminating = false
    private var availableRelease: Updater.Release?
    private let resources = ResourceMonitor()

    init() {
        resources.onUpdate = { [weak self] snapshot in
            self?.controllers.forEach { $0.showResources(snapshot) }
        }
    }

    // MARK: Windows

    /// A new window, empty or restored from `state`, offset from the last one.
    @discardableResult
    func newWindow(restoring state: SessionState? = nil) -> MainWindowController {
        let controller = MainWindowController()
        controller.manager = self
        if let previous = (front ?? controllers.last)?.window, let window = controller.window {
            // Down and to the right of the window in front, kept on its screen.
            let frame = previous.frame.offsetBy(dx: 26, dy: -26)
            window.setFrame(window.constrainFrameRect(frame, to: previous.screen ?? NSScreen.main), display: false)
        }
        if let state { controller.restore(state) }
        controllers.append(controller)
        if let availableRelease { controller.showUpdate(availableRelease) }
        if showsWindows { controller.showWindow(nil) }
        return controller
    }

    /// The window the user is working in.
    var front: MainWindowController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow] {
            if let controller = window?.windowController as? MainWindowController,
               controllers.contains(where: { $0 === controller }) { return controller }
        }
        return controllers.last
    }

    /// Routes `pulse <paths>`, Finder, File › Open and Open Recent (see the type comment).
    func open(_ urls: [URL], from source: MainWindowController? = nil) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let target: MainWindowController
            if isDirectory.boolValue {
                // Compared standardized, opened as given.
                if let existing = controllers.first(where: { $0.root?.standardizedFileURL == url.standardizedFileURL }) {
                    target = existing
                } else if let candidate = source ?? front, candidate.isEmpty {
                    target = candidate
                } else {
                    target = newWindow()
                }
            } else {
                target = controllers.first { $0.contains(url) } ?? source ?? front ?? newWindow()
            }
            target.open([url])
            if showsWindows { target.showWindow(nil) }
        }
    }

    // MARK: Closing

    /// A window that isn't the last one won't be restored, so its unsaved
    /// untitled buffers are asked about first. The last window's are kept by
    /// session recovery, as before.
    func windowShouldClose(_ controller: MainWindowController) -> Bool {
        guard !terminating, controllers.count > 1 else { return true }
        return controller.editor.closeUnsavedUntitledDocuments()
    }

    func windowWillClose(_ controller: MainWindowController) {
        controller.prepareForQuit()
        guard !terminating, controllers.count > 1 else { saveSession(); return }
        controllers.removeAll { $0 === controller }
        saveSession()
    }

    // MARK: Session

    /// Restores every saved window; false when there was nothing to restore.
    func restoreSession() -> Bool {
        let states = SessionState.loadAll()
        states.forEach { newWindow(restoring: $0) }
        return !states.isEmpty
    }

    /// `extra`: a window not (yet) managed here, such as one built by tests.
    func saveSession(including extra: MainWindowController? = nil) {
        var windows = controllers
        if let extra, !windows.contains(where: { $0 === extra }) { windows.append(extra) }
        SessionState.saveAll(windows.map(\.sessionState))
    }

    func prepareForQuit() {
        terminating = true
        controllers.forEach { $0.prepareForQuit() }
        saveSession()
    }

    // MARK: App activation

    func appDidBecomeActive() {
        controllers.forEach { $0.appDidBecomeActive() }
        resources.start()
        Updater.checkIfDue { [weak self] release in
            if let release { self?.offer(release) }
        }
    }

    func appDidResignActive() {
        resources.stop()
        controllers.forEach { $0.appDidResignActive() }
        saveSession()
    }

    /// A newer release: every window (and any opened later) shows Update.
    func offer(_ release: Updater.Release) {
        availableRelease = release
        controllers.forEach { $0.showUpdate(release) }
    }
}
