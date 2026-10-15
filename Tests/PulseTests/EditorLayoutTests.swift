import AppKit
import XCTest
@testable import Pulse

/// The gutter floats over the clip view; code must never start under it.
final class EditorLayoutTests: PulseTestCase {
    private func lines(_ count: Int, prefix: String = "// line") -> String {
        (0..<count).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n"
    }

    func testShortFileStartsRightOfTheGutter() throws {
        let root = try makeFolder(files: ["main.swift": "import AppKit\n"])
        let controller = makeController(opening: [root.appendingPathComponent("main.swift")])
        assertTextClearsGutter(controller)
    }

    func testGutterWidthChangesKeepTextVisible() throws {
        let root = try makeFolder(files: ["a.swift": lines(98), "b.swift": lines(998)])
        let controller = makeController(opening: [root.appendingPathComponent("a.swift")])
        let editor = controller.editor
        for name in ["a.swift", "b.swift"] {
            editor.open(root.appendingPathComponent(name))
            layout(controller)
            let before = editor.textView.enclosingScrollView!.verticalRulerView!.ruleThickness
            assertTextClearsGutter(controller, name)
            // One more line: 99 → 100 keeps three digits, 999 → 1000 widens the gutter.
            type("x\n", at: 0, in: controller)
            assertTextClearsGutter(controller, "\(name) +1 line")
            let after = editor.textView.enclosingScrollView!.verticalRulerView!.ruleThickness
            if name == "b.swift" { XCTAssertGreaterThan(after, before) } else { XCTAssertEqual(after, before) }
            // And back: the gutter narrows without leaving a gap or hiding text.
            editor.textView.undoManager?.undo()
            layout(controller)
            XCTAssertEqual(editor.textView.enclosingScrollView!.verticalRulerView!.ruleThickness, before)
            assertTextClearsGutter(controller, "\(name) undo")
        }
    }

    func testWrappedLinesFitTheVisibleWidth() throws {
        let long = String(repeating: "word ", count: 400) + "\n"
        let root = try makeFolder(files: ["long.txt": long + lines(998)])
        let controller = makeController(opening: [root.appendingPathComponent("long.txt")])
        let editor = controller.editor
        editor.toggleWrap()
        layout(controller)
        assertWrapFits(controller, "wrap on")
        assertTextClearsGutter(controller, "wrap on")
        // Crossing 1000 lines widens the gutter; the wrap width must follow.
        type("x\n", at: (editor.textView.string as NSString).length, in: controller)
        assertWrapFits(controller, "wider gutter")
        assertTextClearsGutter(controller, "wider gutter")
        editor.toggleWrap()
        layout(controller)
        assertTextClearsGutter(controller, "wrap off")
        XCTAssertGreaterThan(editor.textView.frame.width, editor.textView.enclosingScrollView!.contentView.bounds.width)
    }

    func testWrapAppliesToAFileOpenedJustBefore() throws {
        // The text view still has the previous tab's width when wrap turns on.
        let root = try makeFolder(files: ["a.swift": "import AppKit\n", "long.txt": String(repeating: "wrap me ", count: 300) + "END\n"])
        let controller = makeController(opening: [root.appendingPathComponent("a.swift")])
        controller.editor.open(root.appendingPathComponent("long.txt"))
        controller.editor.toggleWrap()
        layout(controller)
        assertWrapFits(controller, "toggled right after open")
        let textView = controller.editor.textView!
        let firstLine = textView.layoutManager!.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let end = textView.layoutManager!.lineFragmentRect(forGlyphAt: textView.layoutManager!.glyphIndexForCharacter(at: (textView.string as NSString).length - 2), effectiveRange: nil)
        XCTAssertGreaterThan(end.minY, firstLine.maxY, "the long line wraps onto more rows")
    }

    func testTabSwitchesRestoreScrollAndKeepTextVisible() throws {
        let long = "let value = " + String(repeating: "x", count: 600) + "\n"
        let root = try makeFolder(files: ["short.swift": "import AppKit\n", "long.swift": long + lines(300)])
        let controller = makeController(opening: [root.appendingPathComponent("short.swift")])
        let editor = controller.editor
        let scroll = try XCTUnwrap(editor.textView.enclosingScrollView)
        editor.open(root.appendingPathComponent("long.swift"))
        layout(controller)

        // Scroll down, then far right along the long first line.
        scrollText(scroll, to: NSPoint(x: 0, y: 1200))
        layout(controller)
        let savedY = textOrigin(scroll).y
        XCTAssertGreaterThan(savedY, 1000)
        editor.selectTab(offset: -1)
        layout(controller)
        assertTextClearsGutter(controller, "short after long")
        editor.selectTab(offset: 1)
        layout(controller)
        XCTAssertEqual(textOrigin(scroll).y, savedY, accuracy: 1, "scroll position restored")
        XCTAssertEqual(textOrigin(scroll).x, 0, accuracy: 0.5)

        // Caret at the end of the long line scrolls right; back to the line start shows column 0.
        editor.reveal(NSRange(location: (long as NSString).length - 1, length: 0))
        layout(controller)
        XCTAssertGreaterThan(textOrigin(scroll).x, 100)
        editor.selectTab(offset: -1)
        editor.selectTab(offset: 1)
        layout(controller)
        XCTAssertGreaterThan(textOrigin(scroll).x, 100, "horizontal position restored")
        editor.reveal(NSRange(location: 0, length: 0))
        layout(controller)
        assertTextClearsGutter(controller, "back at column 0")
    }

    func testZoomKeepsTextRightOfTheGutter() throws {
        let root = try makeFolder(files: ["main.swift": lines(50)])
        let controller = makeController(opening: [root.appendingPathComponent("main.swift")])
        for delta: CGFloat in [6, 6, -12] {
            controller.changeFontSize(of: .editor, by: delta)
            layout(controller)
            assertTextClearsGutter(controller, "zoom \(delta)")
        }
    }

    // MARK: Helpers

    // The ruler floats over the clip view, which marks the strip it covers
    // with contentInsets: visible text starts at bounds origin + insets.
    private func textOrigin(_ scroll: NSScrollView) -> NSPoint {
        let clip = scroll.contentView
        return NSPoint(x: clip.bounds.minX + clip.contentInsets.left, y: clip.bounds.minY + clip.contentInsets.top)
    }

    private func scrollText(_ scroll: NSScrollView, to point: NSPoint) {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: point.x - clip.contentInsets.left, y: point.y - clip.contentInsets.top))
        scroll.reflectScrolledClipView(clip)
    }

    private func visibleWidth(_ scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView
        return clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right
    }

    /// Types through the text view, as a key press would.
    private func type(_ text: String, at location: Int, in controller: MainWindowController) {
        let textView = controller.editor.textView!
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.insertText(text, replacementRange: textView.selectedRange())
        layout(controller)
    }

    /// The first visible line's first glyph sits exactly the text inset plus
    /// line padding to the right of the gutter, in window coordinates.
    private func assertTextClearsGutter(_ controller: MainWindowController, _ label: String = "",
                                        file: StaticString = #filePath, line: UInt = #line) {
        layout(controller)
        let textView = controller.editor.textView!
        let scroll = textView.enclosingScrollView!
        let ruler = scroll.verticalRulerView!
        guard let layoutManager = textView.layoutManager, layoutManager.numberOfGlyphs > 0 else {
            return XCTFail("no glyphs \(label)", file: file, line: line)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: textView.characterIndexForInsertion(at: NSPoint(x: 0, y: textOrigin(scroll).y + 20)))
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphX = fragment.minX + layoutManager.location(forGlyphAt: glyph).x + textView.textContainerOrigin.x
        let textInWindow = textView.convert(NSPoint(x: glyphX, y: fragment.midY), to: nil).x
        let gutterEdge = ruler.convert(NSPoint(x: ruler.bounds.maxX, y: 0), to: nil).x
        let expected = textView.textContainerOrigin.x + textView.textContainer!.lineFragmentPadding
        XCTAssertEqual(textInWindow - gutterEdge, expected, accuracy: 0.5, "text start vs gutter \(label)", file: file, line: line)
    }

    private func assertWrapFits(_ controller: MainWindowController, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let textView = controller.editor.textView!
        let scroll = textView.enclosingScrollView!
        XCTAssertEqual(textView.frame.width, visibleWidth(scroll), accuracy: 0.5, label, file: file, line: line)
        let used = textView.layoutManager!.usedRect(for: textView.textContainer!)
        let rightEdgeInWindow = textView.convert(NSPoint(x: used.maxX + textView.textContainerOrigin.x, y: 0), to: nil).x
        let clipRightInWindow = scroll.contentView.convert(NSPoint(x: scroll.contentView.bounds.maxX, y: 0), to: nil).x
        XCTAssertLessThanOrEqual(rightEdgeInWindow, clipRightInWindow + 0.5, "wrapped text ends inside the view \(label)", file: file, line: line)
    }
}
