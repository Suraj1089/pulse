import AppKit
import XCTest
@testable import Pulse

/// Multiple windows: one per folder, like VS Code. Each test has its own
/// WindowManager with windows kept off screen.
final class WindowTests: PulseTestCase {
    private var manager: WindowManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        manager = WindowManager()
        manager.showsWindows = false
    }

    override func tearDownWithError() throws {
        for controller in manager.controllers {
            controller.editor.killAllTerminals()
            controller.window?.orderOut(nil)
        }
        manager = nil
        try super.tearDownWithError()
    }

    private func roots() -> [URL?] { manager.controllers.map(\.root) }

    func testEachFolderGetsItsOwnWindowAndReopeningOneReusesIt() throws {
        let a = try makeFolder("a", files: ["a.swift": "\n"])
        let b = try makeFolder("b", files: ["b.swift": "\n"])
        manager.open([a])
        manager.open([b])
        XCTAssertEqual(roots(), [a, b], "a second folder opens a second window")
        manager.open([a])
        XCTAssertEqual(manager.controllers.count, 2, "an open folder reuses its window")
    }

    func testAnEmptyWindowIsReusedForTheNextFolder() throws {
        let a = try makeFolder("a", files: ["a.swift": "\n"])
        let empty = manager.newWindow()
        XCTAssertTrue(empty.isEmpty)
        manager.open([a])
        XCTAssertEqual(manager.controllers.count, 1)
        XCTAssertTrue(manager.controllers[0] === empty)
        XCTAssertEqual(empty.root, a)
    }

    func testFilesOpenInTheWindowWhoseFolderHoldsThem() throws {
        let a = try makeFolder("a", files: ["a.swift": "\n"])
        let b = try makeFolder("b", files: ["src/b.swift": "\n"])
        manager.open([a])
        manager.open([b])
        manager.open([b.appendingPathComponent("src/b.swift")], from: manager.controllers[0])
        XCTAssertEqual(manager.controllers.count, 2)
        XCTAssertEqual(manager.controllers[1].editor.activeDocument?.url?.lastPathComponent, "b.swift")
        XCTAssertNil(manager.controllers[0].editor.activeDocument, "not in the window that asked")
    }

    func testEveryWindowIsSavedAndRestoredWithItsFrame() throws {
        let a = try makeFolder("a", files: ["a.swift": "let a = 1\n"])
        let b = try makeFolder("b", files: ["b.swift": "let b = 2\n"])
        manager.open([a, a.appendingPathComponent("a.swift")])
        manager.open([b])
        let frame = NSRect(x: 120, y: 140, width: 900, height: 600)
        manager.controllers[1].window?.setFrame(frame, display: false)
        manager.saveSession()

        let restored = WindowManager()
        restored.showsWindows = false
        defer { restored.controllers.forEach { $0.window?.orderOut(nil) } }
        XCTAssertTrue(restored.restoreSession())
        XCTAssertEqual(restored.controllers.map(\.root), [a, b])
        XCTAssertEqual(restored.controllers[0].editor.activeDocument?.url?.lastPathComponent, "a.swift")
        XCTAssertEqual(restored.controllers[1].window?.frame, frame)
    }

    func testASingleWindowSessionFromAnOlderPulseStillLoads() throws {
        let a = try makeFolder("a", files: ["a.swift": "\n"])
        let legacy = #"{"root":"\#(a.path)","entries":[],"terminalOpen":false}"#
        try legacy.write(to: SessionState.fileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(manager.restoreSession())
        XCTAssertEqual(roots(), [a])
    }

    func testClosingAWindowDropsItFromTheSessionButTheLastOneIsKept() throws {
        let a = try makeFolder("a", files: ["a.swift": "\n"])
        let b = try makeFolder("b", files: ["b.swift": "\n"])
        manager.open([a])
        manager.open([b])
        manager.windowWillClose(manager.controllers[0])
        XCTAssertEqual(SessionState.loadAll().map(\.root), [b.path])
        manager.windowWillClose(manager.controllers[0])
        XCTAssertEqual(SessionState.loadAll().map(\.root), [b.path], "the last window reopens next launch")
    }

    func testClosingAWindowAsksAboutUnsavedUntitledText() throws {
        let a = try makeFolder("a", files: ["a.swift": "\n"])
        manager.open([a])
        let other = manager.newWindow()
        XCTAssertTrue(manager.windowShouldClose(other), "nothing unsaved: closes right away")
        XCTAssertTrue(manager.windowShouldClose(manager.controllers[0]))
    }

    func testAnUpdateShowsInEveryWindowIncludingNewOnes() throws {
        manager.newWindow()
        let release = Updater.Release(version: "9.9.9", zip: URL(string: "https://example.invalid/Pulse.zip")!,
                                      page: URL(string: "https://example.invalid")!)
        manager.offer(release)
        manager.newWindow()
        for controller in manager.controllers {
            let titles = views(NSButton.self, in: controller).map(\.title)
            XCTAssertTrue(titles.contains("Update to 9.9.9"), "\(titles)")
        }
    }

    func testNewWindowsCascade() throws {
        let first = manager.newWindow()
        let second = manager.newWindow()
        let a = try XCTUnwrap(first.window?.frame), b = try XCTUnwrap(second.window?.frame)
        XCTAssertEqual(b.minX - a.minX, 26, accuracy: 1, "to the right")
        XCTAssertEqual(b.maxY - a.maxY, -26, accuracy: 1, "and down")
    }
}
