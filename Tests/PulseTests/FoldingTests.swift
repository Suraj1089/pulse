import AppKit
import XCTest
@testable import Pulse

/// Code folding by indentation (Editor/Folding.swift).
final class FoldingTests: PulseTestCase {
    private let lines = [
        "struct A {",        // 0
        "    func b() {",    // 1
        "        let x = 1", // 2
        "",                  // 3
        "        print(x)",  // 4
        "    }",             // 5
        "",                  // 6
        "    func c() {}",   // 7
        "}",                 // 8
        "let after = 2",     // 9
    ]
    private var source: String { lines.joined(separator: "\n") + "\n" }
    private func start(_ line: Int) -> Int { lines.prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 } }
    private func end(_ line: Int) -> Int { start(line) + (lines[line] as NSString).length }
    /// Folding line 1 hides its line break and lines 2 to 4, up to line 4's line break.
    private var bodyOfB: NSRange { NSRange(location: end(1), length: end(4) - end(1)) }

    private func open() throws -> (MainWindowController, CodeTextView, NSTextStorage) {
        let root = try makeFolder(files: ["a.swift": source])
        let controller = makeController(opening: [root, root.appendingPathComponent("a.swift")])
        let textView = try XCTUnwrap(controller.editor.textView)
        return (controller, textView, try XCTUnwrap(textView.textStorage))
    }

    private func hasFolds(_ storage: NSTextStorage) -> Bool {
        var found = false
        storage.enumerateAttribute(.folded, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { found = true }
        }
        return found
    }

    func testBlocksFollowIndentation() {
        let text = source as NSString
        XCTAssertEqual(Folding.region(ofLineAt: start(1), in: text, tabWidth: 4), bodyOfB, "blank lines inside count")
        XCTAssertEqual(Folding.region(ofLineAt: start(0), in: text, tabWidth: 4), NSRange(location: end(0), length: end(7) - end(0)),
                       "the closing brace stays visible")
        XCTAssertNil(Folding.region(ofLineAt: start(7), in: text, tabWidth: 4), "nothing deeper follows")
        XCTAssertNil(Folding.region(ofLineAt: start(3), in: text, tabWidth: 4), "blank")
        XCTAssertNil(Folding.region(ofLineAt: start(9), in: text, tabWidth: 4), "last line")
        XCTAssertTrue(Folding.startsBlock(lineAt: start(1), in: text, tabWidth: 4))
        XCTAssertFalse(Folding.startsBlock(lineAt: start(2), in: text, tabWidth: 4))
        XCTAssertEqual(Folding.indent(ofLineAt: 0, in: "\t  x" as NSString, tabWidth: 4), 6)
        XCTAssertNil(Folding.indent(ofLineAt: 0, in: "   \n" as NSString, tabWidth: 4))
    }

    func testFoldingHidesTheLinesAndUnfoldingBringsThemBack() throws {
        let (controller, textView, storage) = try open()
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        // Laid out first: with non-contiguous layout an unlaid line's position is an estimate.
        func top(_ line: Int) -> CGFloat {
            layoutManager.ensureLayout(for: container)
            return layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start(line)), effectiveRange: nil).minY
        }
        func property(at character: Int) -> NSLayoutManager.GlyphProperty {
            layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length))
            return layoutManager.propertyForGlyph(at: layoutManager.glyphIndexForCharacter(at: character))
        }
        let lineHeight = top(2) - top(1)
        XCTAssertGreaterThan(lineHeight, 0)

        textView.setSelectedRange(NSRange(location: start(2) + 8, length: 0))
        textView.foldAtCaret()
        XCTAssertEqual(storage.fold(at: end(1)), bodyOfB, "the block around the caret")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: end(1), length: 0), "the caret leaves the hidden lines")
        XCTAssertEqual(top(5), top(1) + lineHeight, "the closing brace follows the folded line")
        XCTAssertEqual(property(at: start(2) + 8), .null, "hidden text draws nothing")
        XCTAssertEqual(property(at: end(1)), .controlCharacter, "the hidden line break doesn't break the line")
        XCTAssertEqual(storage.string, source, "the text is unchanged")
        XCTAssertEqual(controller.editor.activeDocument?.isDirty, false)

        textView.unfoldAtCaret()
        XCTAssertFalse(hasFolds(storage))
        XCTAssertEqual(top(5), top(1) + 4 * lineHeight)
        XCTAssertNotEqual(property(at: start(2) + 8), .null)
    }

    func testTheCaretStepsOverAFold() throws {
        let (_, textView, storage) = try open()
        textView.toggleFold(atLineStart: start(1))
        XCTAssertEqual(storage.fold(at: end(1)), bodyOfB)

        textView.setSelectedRange(NSRange(location: end(1), length: 0))
        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange().location, start(5), "right goes to the next visible line")
        textView.moveLeft(nil)
        XCTAssertEqual(textView.selectedRange().location, end(1), "left comes back")
        textView.setSelectedRange(NSRange(location: end(4), length: 0))
        XCTAssertEqual(textView.selectedRange().location, end(1), "past the fold (a click, End) is the end of the folded line")
        XCTAssertNotNil(storage.fold(at: end(1)))

        textView.setSelectedRange(NSRange(location: start(2) + 8, length: 0))
        XCTAssertFalse(hasFolds(storage), "a jump into the block (Go to Line, Find) unfolds it")
    }

    func testTypingNextToAFoldKeepsIt() throws {
        let (_, textView, storage) = try open()
        textView.typingAttributes = [.folded: true, .font: Theme.editorFont]
        XCTAssertNil(textView.typingAttributes[.folded], "typed text never starts out hidden")

        textView.toggleFold(atLineStart: start(1))
        textView.setSelectedRange(NSRange(location: end(1), length: 0))
        textView.insertText(" // b", replacementRange: textView.selectedRange())
        XCTAssertFalse(storage.isFolded(at: end(1)), "the typed text shows")
        XCTAssertEqual(storage.fold(at: end(1) + 5), NSRange(location: bodyOfB.location + 5, length: bodyOfB.length))
    }

    func testEditingPartOfAFoldUnfoldsIt() throws {
        let (_, textView, storage) = try open()
        textView.toggleFold(atLineStart: start(1))
        textView.insertText("", replacementRange: NSRange(location: end(1) - 1, length: 3))
        XCTAssertFalse(hasFolds(storage))
    }

    func testFoldAllFoldsTheOutermostBlocks() throws {
        let (_, textView, storage) = try open()
        textView.setSelectedRange(NSRange(location: start(4) + 8, length: 0))
        textView.foldAll()
        XCTAssertEqual(storage.fold(at: end(0)), NSRange(location: end(0), length: end(7) - end(0)))
        XCTAssertFalse(storage.isFolded(at: start(9)))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: end(0), length: 0))
        textView.unfoldAll()
        XCTAssertFalse(hasFolds(storage))
    }

    func testTheGutterAndThePlaceholderToggleFolds() throws {
        let (controller, textView, storage) = try open()
        let ruler = controller.editor.activePane.ruler
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        XCTAssertTrue(textView.foldPlaceholders(in: textView.visibleRect).isEmpty)

        // The chevron column of line 1.
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start(1)), effectiveRange: nil)
        let point = ruler.convert(NSPoint(x: 0, y: fragment.midY + textView.textContainerOrigin.y), from: textView)
        XCTAssertEqual(ruler.lineStart(at: NSPoint(x: ruler.ruleThickness - 8, y: point.y)), start(1))
        textView.toggleFold(atLineStart: start(1))
        layout(controller)
        ruler.display()

        // The "⋯" after the folded line unfolds it.
        let placeholder = try XCTUnwrap(textView.foldPlaceholders(in: textView.visibleRect).first)
        XCTAssertEqual(placeholder.fold, bodyOfB)
        let window = try XCTUnwrap(textView.window)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: textView.convert(NSPoint(x: placeholder.rect.midX, y: placeholder.rect.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        textView.mouseDown(with: click)
        XCTAssertFalse(hasFolds(storage))
    }
}
