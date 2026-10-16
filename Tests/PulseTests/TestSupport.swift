import AppKit
import XCTest
@testable import Pulse

/// Base class for Pulse's end-to-end tests. Each test gets its own temporary
/// folder, its own session file, and restored preferences, so tests never
/// touch the user's real session or settings and never depend on each other.
/// Windows stay off screen and the app never activates, so tests cannot take
/// keyboard focus from whatever the user is doing.
class PulseTestCase: XCTestCase {
    private(set) var temp: URL!
    private var savedDefaults: [String: Any?] = [:]
    private var originalSessionURL: URL!
    private var originalKeyBindingsURL: URL!
    private var controllers: [MainWindowController] = []

    private static let preferenceKeys = ["autosave", "wrapLines", "editorFontSize", "sidebarFontSize", "terminalFontSize",
                                         "recentFolders", "appearance", "welcomeShown", "showWelcomeOnLaunch",
                                         "cliInstallFolder"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // /var is a symlink to /private/var. Use the canonical path, which is
        // what directory listings return (URL.resolvingSymlinksInPath strips
        // "/private" instead).
        let canonical = try XCTUnwrap(realpath(folder.path, nil))
        temp = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        originalSessionURL = SessionState.fileURL
        SessionState.fileURL = temp.appendingPathComponent("session.json")
        originalKeyBindingsURL = KeyBindings.fileURL
        KeyBindings.fileURL = temp.appendingPathComponent("keybindings.json")
        for key in PulseTestCase.preferenceKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.editor.killTerminal()
            controller.window?.orderOut(nil)
        }
        controllers = []
        // Let pending autosave/session work run against the temp folder, not later.
        spin(0.1)
        SessionState.fileURL = originalSessionURL
        KeyBindings.fileURL = originalKeyBindingsURL
        for (key, value) in savedDefaults {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: temp)
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    /// Creates a folder of files under the test's temp directory.
    @discardableResult
    func makeFolder(_ name: String = "project", files: [String: String]) throws -> URL {
        let root = temp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Runs git in `directory`; fails the test on a non-zero exit.
    @discardableResult
    func git(_ arguments: String..., in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let git = try XCTUnwrap(GitStatus.git, "git is not installed", file: file, line: line)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", directory.path, "-c", "user.name=Pulse Tests", "-c", "user.email=tests@pulse.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")): \(output)", file: file, line: line)
        return output
    }

    // MARK: App

    /// A real Pulse window controller, off screen, optionally opened on `urls`.
    func makeController(opening urls: [URL] = []) -> MainWindowController {
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 700), display: false)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        if !urls.isEmpty { controller.open(urls) }
        layout(controller)
        return controller
    }

    func layout(_ controller: MainWindowController) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
    }

    /// Runs the main run loop so dispatched work (debounces, git, search) can finish.
    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins the run loop until `condition` holds or `timeout` passes.
    @discardableResult
    func wait(timeout: TimeInterval = 5, _ message: String = "condition", file: StaticString = #filePath, line: UInt = #line,
              until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(message)", file: file, line: line)
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    // MARK: Views

    func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    func frameView(_ controller: MainWindowController) -> NSView {
        controller.window!.contentView!.superview!
    }

    func views<T: NSView>(_ type: T.Type, in controller: MainWindowController) -> [T] {
        allSubviews(of: frameView(controller)).compactMap { $0 as? T }
    }

    /// The outline view with the given accessibility label ("Files", "Search results", ...).
    func outline(_ label: String, in controller: MainWindowController) -> NSOutlineView? {
        views(NSOutlineView.self, in: controller).first { $0.accessibilityLabel() == label && $0.window != nil }
    }

    /// Visible label strings, in view-tree order.
    func labels(in view: NSView) -> [String] {
        allSubviews(of: view).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
    }

    /// The text shown in each row of an outline, flattened.
    func rowTexts(_ outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).map { row in
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { return "" }
            return labels(in: cell).joined(separator: " | ").isEmpty
                ? ((cell as? NSTableCellView)?.textField?.stringValue ?? "")
                : ([(cell as? NSTableCellView)?.textField?.stringValue ?? ""] + labels(in: cell).dropFirst()).joined(separator: " | ")
        }
    }

    /// A real mouse click delivered through the window, as AppKit would.
    func click(_ view: NSView, at point: NSPoint? = nil, clickCount: Int = 1) {
        let window = view.window!
        let local = point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let location = view.convert(local, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
        }
        // The app is never active, so the window would take a click as the
        // "first mouse" that only activates it. Deliver it to the view under
        // the pointer, as the window does once active. Tables track the mouse
        // in a loop that reads the next event; queue the mouse-up first so
        // that loop ends.
        guard let target = window.contentView?.superview?.hitTest(location) else {
            return XCTFail("nothing to click at \(location)")
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        target.mouseDown(with: event(.leftMouseDown))
        spin(0.05)
    }

}
