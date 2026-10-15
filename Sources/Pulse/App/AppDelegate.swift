import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Used by scripts/screenshot.sh to capture both appearances.
        switch ProcessInfo.processInfo.environment["PULSE_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        NSApp.mainMenu = MainMenu.build()
        let controller = MainWindowController()
        windowController = controller
        controller.restoreSession()

        // `Pulse path/to/folder` from a shell, or `swift run Pulse .`
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        pendingURLs += arguments.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
        if !pendingURLs.isEmpty {
            controller.open(pendingURLs)
            pendingURLs = []
        }

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Used by scripts/memory-check.sh to measure the terminal scenario.
        if ProcessInfo.processInfo.environment["PULSE_OPEN_TERMINAL"] == "1" {
            controller.editor.showTerminal()
        }
        if ProcessInfo.processInfo.environment["PULSE_DEBUG_LAYOUT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { controller.editor.dumpLayout() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let windowController else {
            pendingURLs += urls
            return
        }
        windowController.open(urls)
        windowController.showWindow(nil)
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        ShortcutsPanel.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showWindow(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        windowController?.appDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        windowController?.appDidResignActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.prepareForQuit()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
