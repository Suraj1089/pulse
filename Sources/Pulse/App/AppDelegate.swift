import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let windows = WindowManager.shared
    private var launched = false
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Used by scripts/screenshot.sh to capture both appearances.
        switch ProcessInfo.processInfo.environment["PULSE_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: AppAppearance.current.apply()
        }
        NSApp.mainMenu = MainMenu.build()
        // Every window from last time, or one empty window.
        if !windows.restoreSession() { windows.newWindow() }

        // `Pulse path/to/folder` from a shell, or `swift run Pulse .`
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        pendingURLs += arguments.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
        let launchedWithFiles = !pendingURLs.isEmpty
        if launchedWithFiles {
            windows.open(pendingURLs)
            pendingURLs = []
        }
        launched = true
        windows.front?.showWelcomeIfNeeded(launchedWithFiles: launchedWithFiles)

        NSApp.activate(ignoringOtherApps: true)
        windows.front?.installCommandLineToolIfNeeded()

        // Used by scripts/memory-check.sh to measure a split editor.
        if ProcessInfo.processInfo.environment["PULSE_SPLIT_EDITOR"] == "1" {
            windows.front?.editor.splitEditor(.right)
        }
        // Used by scripts/memory-check.sh to measure the terminal scenario.
        if ProcessInfo.processInfo.environment["PULSE_OPEN_TERMINAL"] == "1" {
            windows.front?.editor.showTerminal()
        }
        if ProcessInfo.processInfo.environment["PULSE_DEBUG_LAYOUT"] == "1", let editor = windows.front?.editor {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { editor.dumpLayout() }
        }
    }

    /// `pulse <paths>`, Finder and the Dock: folders get their own window.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingURLs += urls
            return
        }
        windows.open(urls)
    }

    @objc func newWindow(_ sender: Any?) {
        windows.newWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let front = windows.front { front.showWindow(nil) } else { windows.newWindow() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        windows.appDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        windows.appDidResignActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows.prepareForQuit()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
