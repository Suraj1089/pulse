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
        func fragment(_ line: Int) -> (rect: NSRect, characters: NSRange) {
            layoutManager.ensureLayout(for: container)
            var glyphs = NSRange()
            let rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start(line)), effectiveRange: &glyphs)
            return (rect, layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        }
        func top(_ line: Int) -> CGFloat { fragment(line).rect.minY }
        let lineHeight = top(2) - top(1)
        XCTAssertGreaterThan(lineHeight, 0)

        textView.setSelectedRange(NSRange(location: start(2) + 8, length: 0))
        textView.foldAtCaret()
        XCTAssertEqual(storage.fold(at: end(1)), bodyOfB, "the block around the caret")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: end(1), length: 0), "the caret leaves the hidden lines")
        XCTAssertEqual(top(5), top(1) + lineHeight, "the closing brace follows the folded line")
        XCTAssertEqual(fragment(2).rect.height, 0, "hidden lines take no space")
        XCTAssertEqual(fragment(4).rect.height, 0)
        XCTAssertEqual(fragment(1).characters, NSRange(location: start(1), length: end(1) + 1 - start(1)),
                       "the folded line is laid out alone, not with what it hides")
        XCTAssertEqual(storage.string, source, "the text is unchanged")
        XCTAssertEqual(controller.editor.activeDocument?.isDirty, false)

        textView.unfoldAtCaret()
        XCTAssertFalse(hasFolds(storage))
        XCTAssertEqual(top(5), top(1) + 4 * lineHeight)
        XCTAssertEqual(fragment(2).rect.height, lineHeight)
    }

    func testFoldedLinesDrawNothing() throws {
        let hidden = "        let x = " + String(repeating: "1 + ", count: 30) + "1"
        let root = try makeFolder(files: ["a.swift": "func b() {\n" + hidden + "\n}\n"])
        let controller = makeController(opening: [root.appendingPathComponent("a.swift")])
        let textView = try XCTUnwrap(controller.editor.textView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let origin = textView.textContainerOrigin
        func band(_ character: Int) -> NSRect {
            let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: character), effectiveRange: nil)
            // Right of the first line's text and its fold's "⋯".
            return NSRect(x: origin.x + 120, y: origin.y + line.minY + 1, width: 200, height: line.height - 2)
        }
        let hiddenLine = band(11)
        XCTAssertTrue(try hasInk(textView, in: hiddenLine), "the long line shows before folding")
        textView.toggleFold(atLineStart: 0)
        layout(controller)
        XCTAssertFalse(try hasInk(textView, in: band(0)), "its glyphs aren't drawn over the folded line")
        XCTAssertFalse(try hasInk(textView, in: band(12 + (hidden as NSString).length)), "or over the line after it")
    }

    /// Whether `rect` (in the text view) shows anything but one colour.
    private func hasInk(_ textView: NSTextView, in rect: NSRect) throws -> Bool {
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        let area = scroll.convert(rect, from: textView)
        let rep = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: area))
        scroll.cacheDisplay(in: area, to: rep)
        let background = try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent) > 0.15 { return true }
            }
        }
        return false
    }

    func testABlockFoldedInsideAnotherStaysFoldedWhenThatOneOpens() throws {
        let (_, textView, storage) = try open()
        textView.toggleFold(atLineStart: start(1))
        textView.toggleFold(atLineStart: start(0))
        XCTAssertEqual(storage.fold(at: end(0)), NSRange(location: end(0), length: end(7) - end(0)), "the outer fold hides the inner one")
        textView.toggleFold(atLineStart: start(0))
        XCTAssertFalse(storage.isFolded(at: end(0)))
        XCTAssertEqual(storage.fold(at: end(1)), bodyOfB, "the inner block is still folded")

        // Fold All leaves an already folded block as it is: one unfold opens it.
        textView.foldAll()
        textView.unfoldAll()
        XCTAssertFalse(hasFolds(storage))
        textView.toggleFold(atLineStart: start(1))
        textView.foldAll()
        textView.toggleFold(atLineStart: start(0))
        XCTAssertEqual(storage.fold(at: end(1)), bodyOfB)
        textView.toggleFold(atLineStart: start(1))
        XCTAssertFalse(hasFolds(storage))

        // A jump into the inner block opens both.
        textView.toggleFold(atLineStart: start(1))
        textView.toggleFold(atLineStart: start(0))
        textView.setSelectedRange(NSRange(location: start(2) + 8, length: 0))
        XCTAssertFalse(hasFolds(storage))
        XCTAssertEqual(textView.selectedRange().location, start(2) + 8)
    }

    func testMovingPastAFoldKeepsIt() throws {
        let (_, textView, storage) = try open()
        textView.toggleFold(atLineStart: start(1))
        textView.setSelectedRange(NSRange(location: start(1) + 6, length: 0))
        textView.moveDown(nil)
        XCTAssertEqual(textView.selectedRange().location, end(5), "down goes to the line after the block")
        textView.moveUp(nil)
        XCTAssertEqual(textView.selectedRange().location, start(1) + 6, "and up comes back")
        textView.setSelectedRange(NSRange(location: end(7), length: 0))
        for _ in 0..<3 { textView.moveUp(nil) }
        XCTAssertEqual(textView.selectedRange().location, end(1), "up past the closing brace to the end of the folded line")
        textView.setSelectedRange(NSRange(location: start(1), length: 0))
        textView.moveToEndOfLine(nil)
        XCTAssertEqual(textView.selectedRange().location, end(1))
        XCTAssertEqual(storage.fold(at: end(1)), bodyOfB, "still folded")
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

    /// A key or click that reaches into a fold selects it or steps past it;
    /// a jump into one (Find, Go to Line) still opens it.
    func testKeysAndClicksTakeInAFoldWithoutOpeningIt() throws {
        let (_, textView, storage) = try open()
        let window = try XCTUnwrap(textView.window)
        func press(_ key: Int, _ flags: NSEvent.ModifierFlags) throws {
            let characters = String(Character(UnicodeScalar(key)!))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(.function), timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                                       charactersIgnoringModifiers: characters, isARepeat: false,
                                                       keyCode: key == NSRightArrowFunctionKey ? 124 : 123))
            textView.keyDown(with: event)
        }
        textView.toggleFold(atLineStart: start(1))

        textView.setSelectedRange(NSRange(location: end(1), length: 0))
        try press(NSRightArrowFunctionKey, .shift)
        XCTAssertEqual(textView.selectedRange(), bodyOfB, "⇧→ at the end of a folded line selects what it hides")
        try press(NSRightArrowFunctionKey, .shift)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: end(1), length: bodyOfB.length + 1))
        XCTAssertEqual(storage.fold(at: end(1)), bodyOfB, "still folded")

        textView.setSelectedRange(NSRange(location: start(5), length: 0))
        try press(NSLeftArrowFunctionKey, .shift)
        try press(NSLeftArrowFunctionKey, .shift)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: end(1), length: start(5) - end(1)), "and ⇧← from the next line")

        textView.setSelectedRange(NSRange(location: end(1), length: 0))
        try press(NSRightArrowFunctionKey, .option)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: start(5), length: 0), "⌥→ goes past the fold")
        XCTAssertEqual(storage.fold(at: end(1)), bodyOfB)

        // A triple-click on the folded line.
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start(1)), effectiveRange: nil)
        let point = NSPoint(x: textView.textContainerOrigin.x + 40, y: textView.textContainerOrigin.y + line.midY)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: textView.convert(point, to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 3, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: textView.convert(point, to: nil), modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 3, pressure: 1))
        NSApp.postEvent(up, atStart: false)
        textView.mouseDown(with: click)
        XCTAssertEqual(textView.selectedRange().location, start(1))
        XCTAssertGreaterThanOrEqual(NSMaxRange(textView.selectedRange()), NSMaxRange(bodyOfB), "the line and what it hides")
        XCTAssertEqual(storage.fold(at: end(1)), bodyOfB, "a triple-click keeps it folded")

        textView.setSelectedRange(NSRange(location: start(2) + 4, length: 6))
        XCTAssertFalse(hasFolds(storage), "a selection Find makes in hidden text opens it")
    }

    func testABlockAtTheEndOfTheFileFolds() throws {
        let root = try makeFolder(files: ["a.py": "def f():\n    return 1"])
        let controller = makeController(opening: [root.appendingPathComponent("a.py")])
        let textView = try XCTUnwrap(controller.editor.textView)
        let storage = try XCTUnwrap(textView.textStorage)
        textView.toggleFold(atLineStart: 0)
        layout(controller)
        XCTAssertEqual(storage.fold(at: 8), NSRange(location: 8, length: storage.length - 8))
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        XCTAssertEqual(textView.selectedRange().location, 8, "the end of the text is the end of the folded line")
        textView.toggleFold(atLineStart: 0)
        XCTAssertFalse(hasFolds(storage))
    }

    func testDeletingTheLineBreakAfterAFoldOpensIt() throws {
        let (_, textView, storage) = try open()
        textView.toggleFold(atLineStart: start(1))
        textView.setSelectedRange(NSRange(location: start(5), length: 0))
        textView.deleteBackward(nil)
        XCTAssertFalse(hasFolds(storage), "the closing brace would join a hidden line")
        XCTAssertTrue(storage.string.contains("print(x)    }"))
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
