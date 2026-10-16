import AppKit
import XCTest
@testable import Pulse

/// Split Editor Right / Down: panes with their own tabs that share a file's
/// text (one storage, a layout manager per pane) and give it back on close.
final class SplitEditorTests: PulseTestCase {
    private static let a = "let a = 1\nlet b = 2\n"

    private func project() throws -> (URL, MainWindowController) {
        let root = try makeFolder(files: ["a.swift": SplitEditorTests.a, "b.swift": "let c = 3\n"])
        let controller = makeController(opening: [root, root.appendingPathComponent("a.swift")])
        return (root, controller)
    }

    private func frameInWindow(_ view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    func testSplitRightShowsTheFileSideBySideWithOneCopyOfItsText() throws {
        let (_, controller) = try project()
        let editor = controller.editor
        let document = try XCTUnwrap(editor.activeDocument)
        XCTAssertEqual(editor.panes.count, 1)
        XCTAssertEqual(document.storage.layoutManagers.count, 1, "nothing extra until a split")

        controller.splitEditorRight(nil)
        layout(controller)
        XCTAssertEqual(editor.panes.count, 2)
        let left = editor.panes[0]
        let right = editor.panes[1]
        XCTAssertTrue(left.activeDocument === document)
        XCTAssertTrue(right.activeDocument === document)
        XCTAssertTrue(editor.activePane === right, "the new pane has focus")
        XCTAssertEqual(document.storage.layoutManagers.count, 2, "one text, a layout manager per pane")
        XCTAssertEqual(editor.documents.count, 1, "the same document, not a copy")
        let leftFrame = frameInWindow(left)
        let rightFrame = frameInWindow(right)
        XCTAssertLessThanOrEqual(leftFrame.maxX, rightFrame.minX + 1, "side by side")
        XCTAssertEqual(leftFrame.width, rightFrame.width, accuracy: 2, "and the same width")

        // Typing in one pane shows in the other.
        right.textView.setSelectedRange(NSRange(location: 0, length: 0))
        right.textView.insertText("// hi\n", replacementRange: right.textView.selectedRange())
        layout(controller)
        XCTAssertEqual(left.textView.string, "// hi\n" + SplitEditorTests.a)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(editor.textView.string, left.textView.string)
    }

    func testSplitDownStacksThePanes() throws {
        let (_, controller) = try project()
        controller.splitEditorDown(nil)
        layout(controller)
        XCTAssertEqual(controller.editor.panes.count, 2)
        let top = frameInWindow(controller.editor.panes[0])
        let bottom = frameInWindow(controller.editor.panes[1])
        XCTAssertGreaterThanOrEqual(top.minY, bottom.maxY - 1, "one above the other (window coordinates grow upward)")
        XCTAssertEqual(top.width, bottom.width, accuracy: 2)
        XCTAssertEqual(top.height, bottom.height, accuracy: 2)
    }

    func testEachPaneKeepsItsOwnTabsAndCommandsGoToTheFocusedOne() throws {
        let (root, controller) = try project()
        let editor = controller.editor
        let a = try XCTUnwrap(editor.activeDocument)
        controller.splitEditorRight(nil)
        editor.open(root.appendingPathComponent("b.swift"))
        layout(controller)
        let left = editor.panes[0]
        let right = editor.panes[1]
        XCTAssertEqual(left.documents.map(\.displayName), ["a.swift"])
        XCTAssertEqual(right.documents.map(\.displayName), ["a.swift", "b.swift"])
        XCTAssertEqual(editor.activeDocument?.displayName, "b.swift")
        XCTAssertEqual(editor.documents.map(\.displayName), ["a.swift", "b.swift"], "each file once")
        // Switching tabs on the right must not drag the left pane along.
        XCTAssertEqual(left.textView.string, SplitEditorTests.a)
        XCTAssertEqual(right.textView.string, "let c = 3\n")
        XCTAssertEqual(a.storage.layoutManagers.count, 1)

        // Focusing the left pane makes it the one commands and the status bar follow.
        controller.window?.makeFirstResponder(left.textView)
        XCTAssertTrue(editor.activePane === left)
        XCTAssertEqual(editor.activeDocument?.displayName, "a.swift")
        XCTAssertTrue(editor.textView === left.textView)
        controller.nextTab(nil)
        XCTAssertEqual(editor.activeDocument?.displayName, "a.swift", "the left pane has one tab")
        XCTAssertEqual(right.activeDocument?.displayName, "b.swift", "and the right one is untouched")
    }

    func testClosingAPanesLastTabClosesThePaneAndGivesItsMemoryBack() throws {
        let (_, controller) = try project()
        let editor = controller.editor
        let document = try XCTUnwrap(editor.activeDocument)
        controller.splitEditorRight(nil)
        layout(controller)
        let right = editor.panes[1]

        controller.closeTab(nil)
        layout(controller)
        XCTAssertEqual(editor.panes.count, 1)
        XCTAssertNil(right.superview)
        XCTAssertEqual(document.storage.layoutManagers.count, 1, "the closed pane let go of the text")
        XCTAssertTrue(editor.activeDocument === document, "still open in the other pane")
        XCTAssertEqual(frameInWindow(editor.panes[0]).width, frameInWindow(editor.statusBar).width, accuracy: 2,
                       "the remaining pane takes the whole width")
    }

    func testClosingAFileEverywhereClosesItInEveryPane() throws {
        let (root, controller) = try project()
        let editor = controller.editor
        controller.splitEditorDown(nil)
        editor.open(root.appendingPathComponent("b.swift"))
        let index = try XCTUnwrap(editor.documents.firstIndex { $0.displayName == "a.swift" })
        XCTAssertTrue(editor.closeDocument(at: index))
        XCTAssertEqual(editor.documents.map(\.displayName), ["b.swift"])
        XCTAssertEqual(editor.panes.count, 1, "the pane that only had it closed")
    }

    func testTheTabMenuSplitsAndClosesButNeverSplitsASpecialTab() throws {
        let (root, controller) = try project()
        let editor = controller.editor
        editor.open(root.appendingPathComponent("b.swift"))
        let menu = try XCTUnwrap(editor.panes[0].tabBar.menuForTab?(0))
        XCTAssertEqual(menu.items.map(\.title), ["Split Right", "Split Down", "", "Close", "Close Others"])

        let down = try XCTUnwrap(menu.items.first { $0.title == "Split Down" })
        NSApp.sendAction(try XCTUnwrap(down.action), to: down.target, from: down)
        XCTAssertEqual(editor.panes.count, 2)
        XCTAssertEqual(editor.activeDocument?.displayName, "a.swift", "the tab the menu was opened on")

        // Close Others in the first pane leaves just b.swift there.
        let first = editor.panes[0]
        let bIndex = try XCTUnwrap(first.documents.firstIndex { $0.displayName == "b.swift" })
        let others = try XCTUnwrap(first.tabBar.menuForTab?(bIndex)?.items.first { $0.title == "Close Others" })
        NSApp.sendAction(try XCTUnwrap(others.action), to: others.target, from: others)
        XCTAssertEqual(first.documents.map(\.displayName), ["b.swift"])
        XCTAssertEqual(editor.panes.count, 2, "a.swift is still open below")

        editor.openSpecial(.welcome)
        XCTAssertFalse(editor.canSplitEditor, "special tabs show one view at a time")
        let pane = try XCTUnwrap(editor.activePane)
        let welcome = try XCTUnwrap(pane.tabBar.menuForTab?(try XCTUnwrap(pane.activeIndex)))
        XCTAssertEqual(welcome.items.first?.isEnabled, false)
        let before = editor.panes.count
        controller.splitEditorRight(nil)
        XCTAssertEqual(editor.panes.count, before)
    }

    func testTheSessionKeepsTheFilesOfEveryPane() throws {
        let (root, controller) = try project()
        controller.splitEditorRight(nil)
        controller.editor.open(root.appendingPathComponent("b.swift"))
        let paths = controller.sessionState.entries.compactMap(\.path)
        XCTAssertEqual(paths, [root.appendingPathComponent("a.swift").path, root.appendingPathComponent("b.swift").path])
    }
}
