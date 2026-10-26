import AppKit
import XCTest
@testable import Pulse

/// Go › Back and Forward: the places the caret jumped from (another file, or
/// more than ten lines away), bounded, without holding closed files.
final class NavigationTests: PulseTestCase {
    private static let text = (1...200).map { "line \($0)" }.joined(separator: "\n") + "\n"

    private func project() throws -> (URL, MainWindowController) {
        let root = try makeFolder(files: ["a.swift": NavigationTests.text, "b.swift": NavigationTests.text])
        let controller = makeController(opening: [root, root.appendingPathComponent("a.swift")])
        // Let the event that opened the file end (see EditorViewController.settling).
        spin(0.02)
        return (root, controller)
    }

    /// The active file's name and the caret's zero-based line.
    private func position(_ editor: EditorViewController) -> String {
        guard let document = editor.activeDocument else { return "none" }
        return "\(document.displayName):\(document.line(at: editor.textView.selectedRange().location))"
    }

    func testBackAndForwardRetraceJumpsInAFile() throws {
        let (_, controller) = try project()
        let editor = controller.editor
        XCTAssertFalse(editor.canGoBack)
        editor.goToLine(120)
        spin(0.02)
        editor.goToLine(30)
        spin(0.02)
        XCTAssertEqual(position(editor), "a.swift:29")

        controller.goBack(nil)
        XCTAssertEqual(position(editor), "a.swift:119")
        controller.goBack(nil)
        XCTAssertEqual(position(editor), "a.swift:0", "where the file opened")
        XCTAssertFalse(editor.canGoBack)
        controller.goForward(nil)
        XCTAssertEqual(position(editor), "a.swift:119")
        controller.goForward(nil)
        XCTAssertEqual(position(editor), "a.swift:29")
        XCTAssertFalse(editor.canGoForward)

        // A new jump after going back drops what Forward had.
        controller.goBack(nil)
        spin(0.02)
        editor.goToLine(180)
        spin(0.02)
        XCTAssertFalse(editor.canGoForward)
    }

    func testSmallMovesAndTypingAreNotJumps() throws {
        let (_, controller) = try project()
        let editor = controller.editor
        editor.goToLine(8)
        spin(0.02)
        XCTAssertFalse(editor.canGoBack, "a few lines away")
        // A long paste moves the caret 60 lines, by an edit.
        editor.textView.insertText(String(repeating: "pasted\n", count: 60), replacementRange: editor.textView.selectedRange())
        spin(0.02)
        XCTAssertEqual(position(editor), "a.swift:67")
        XCTAssertFalse(editor.canGoBack, "typing and pasting are not jumps")
    }

    func testBackReturnsToTheFileJumpedFromAndReopensItOnceClosed() throws {
        let (root, controller) = try project()
        let editor = controller.editor
        editor.goToLine(40)
        spin(0.02)
        editor.open(root.appendingPathComponent("b.swift"))
        spin(0.02)
        XCTAssertEqual(position(editor), "b.swift:0")

        controller.goBack(nil)
        XCTAssertEqual(position(editor), "a.swift:39")
        controller.goForward(nil)
        XCTAssertEqual(position(editor), "b.swift:0")

        let index = try XCTUnwrap(editor.documents.firstIndex { $0.displayName == "a.swift" })
        editor.closeDocument(at: index)
        XCTAssertEqual(editor.documents.map(\.displayName), ["b.swift"])
        controller.goBack(nil)
        XCTAssertEqual(position(editor), "a.swift:39", "opened again from disk")
        XCTAssertEqual(editor.documents.count, 2)
    }

    func testOpeningASearchResultInAnotherFileIsOneJump() throws {
        let (root, controller) = try project()
        let editor = controller.editor
        editor.goToLine(10)
        spin(0.02)
        // What the search panel does with a match: open its file, then reveal it.
        editor.open(root.appendingPathComponent("b.swift"))
        editor.reveal(line: 150, column: 0, length: 4)
        spin(0.02)
        XCTAssertEqual(position(editor), "b.swift:149")

        controller.goBack(nil)
        XCTAssertEqual(position(editor), "a.swift:9", "straight back to where the search started")
        XCTAssertFalse(editor.canGoBack)
    }

    func testBackGoesToThePaneThatHasTheFile() throws {
        let (root, controller) = try project()
        let editor = controller.editor
        editor.goToLine(60)
        spin(0.02)
        editor.open(root.appendingPathComponent("b.swift"))
        spin(0.02)
        // b.swift in a new pane on the right; a.swift is only in the left one.
        controller.splitEditorRight(nil)
        layout(controller)
        spin(0.02)
        let left = editor.panes[0]
        let right = editor.panes[1]
        XCTAssertTrue(editor.activePane === right)

        controller.goBack(nil)
        XCTAssertTrue(editor.activePane === left)
        XCTAssertEqual(position(editor), "a.swift:59")
        XCTAssertEqual(right.documents.map(\.displayName), ["b.swift"], "not opened again in the right pane")
    }

    func testBackAndForwardAreRebindableGoCommands() throws {
        KeyBindings.register(MainMenu.build())
        let back = try XCTUnwrap(KeyBindings.command(id: "go.back"))
        let forward = try XCTUnwrap(KeyBindings.command(id: "go.forward"))
        XCTAssertEqual(back.defaultShortcut?.config, "ctrl+-")
        XCTAssertEqual(forward.defaultShortcut?.config, "ctrl+_", "⌃⇧-")

        let (_, controller) = try project()
        XCTAssertFalse(controller.validateMenuItem(back.item), "nothing to go back to")
        controller.editor.goToLine(100)
        spin(0.02)
        XCTAssertTrue(controller.validateMenuItem(back.item))
        XCTAssertFalse(controller.validateMenuItem(forward.item))

        KeyBindings.set(Shortcut(config: "cmd+alt+left"), for: "go.back")
        XCTAssertEqual(KeyBindings.display(for: #selector(MainWindowController.goBack(_:))), "⌥⌘←")
        KeyBindings.resetAll()
    }

    func testHistoryIsBoundedAndKeepsNoDocument() throws {
        var history = NavigationHistory()
        var document: Document? = Document(url: nil, text: "x")
        history.record(NavigationHistory.Place(document: document, url: nil, location: 0))
        weak var released = document
        document = nil
        XCTAssertNil(released, "a place doesn't keep its document alive")
        XCTAssertNil(history.back.first?.document)
        let skipped = history.goBack(from: nil) { $0.document != nil || $0.url != nil }
        XCTAssertNil(skipped, "a closed untitled buffer is skipped")

        let url = temp.appendingPathComponent("a.swift")
        for location in 0..<(NavigationHistory.limit + 20) {
            history.record(NavigationHistory.Place(document: nil, url: url, location: location))
        }
        XCTAssertEqual(history.back.count, NavigationHistory.limit)
        XCTAssertEqual(history.back.first?.location, 20, "the oldest places go first")
    }
}
