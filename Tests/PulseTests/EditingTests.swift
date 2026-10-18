import AppKit
import XCTest
@testable import Pulse

/// Line commands, and edits, Undo and Copy on files large enough to take
/// Pulse's own paths for large changes (`CodeTextView.largeChange`).
final class EditingTests: PulseTestCase {
    private static let swift = "func a() {\n    let x = 1\n\n}\n"

    private func open(_ name: String, _ text: String) throws -> (MainWindowController, CodeTextView, Document) {
        let root = try makeFolder(files: [name: text])
        let controller = makeController(opening: [root, root.appendingPathComponent(name)])
        let editor = controller.editor
        return (controller, try XCTUnwrap(editor.textView), try XCTUnwrap(editor.activeDocument))
    }

    /// Undo groups close at the end of a run loop pass, as after a real event.
    private func step(_ change: () -> Void) {
        change()
        spin(0.01)
    }

    func testIndentOutdentAndCommentTheSelectedLines() throws {
        let (_, textView, document) = try open("a.swift", EditingTests.swift)
        step { textView.selectAll(nil); textView.shiftLines(right: true) }
        XCTAssertEqual(textView.string, "    func a() {\n        let x = 1\n\n    }\n", "blank lines stay blank")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: (textView.string as NSString).length - 1))
        step { textView.shiftLines(right: false) }
        XCTAssertEqual(textView.string, EditingTests.swift)

        step { textView.toggleLineComment() }
        XCTAssertEqual(textView.string, "// func a() {\n//     let x = 1\n\n// }\n")
        step { textView.toggleLineComment() }
        XCTAssertEqual(textView.string, EditingTests.swift)

        // Only the caret's line, at the smallest indent of the lines touched.
        step { textView.setSelectedRange(NSRange(location: 15, length: 0)); textView.toggleLineComment() }
        XCTAssertEqual(textView.string, "func a() {\n    // let x = 1\n\n}\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 11, length: 16))
        step { textView.shiftLines(right: false) }
        XCTAssertEqual(textView.string, "func a() {\n// let x = 1\n\n}\n")

        for _ in 0..<2 { step { document.undoManager.undo() } }
        XCTAssertEqual(textView.string, EditingTests.swift)
    }

    func testLargeChangesUndoAndRedo() throws {
        let lines = (0..<30_000).map { "row \($0), value \($0 * 7)\n" }.joined()
        XCTAssertGreaterThan((lines as NSString).length, CodeTextView.largeChange)
        let (_, textView, document) = try open("rows.csv", lines)
        let undo = document.undoManager

        // Indent every line (one change per line), then delete everything.
        step { textView.selectAll(nil); textView.shiftLines(right: true) }
        let indented = lines.split(separator: "\n").map { "    " + $0 + "\n" }.joined()
        XCTAssertEqual(textView.string, indented)
        step { textView.selectAll(nil); textView.delete(nil) }
        XCTAssertEqual(textView.string, "")
        step { undo.undo() }
        XCTAssertEqual(textView.string, indented)
        XCTAssertFalse(undo.canUndo, "Undo keeps one large change")
        step { undo.redo() }
        XCTAssertEqual(textView.string, "")
        step { undo.undo() }
        XCTAssertEqual(textView.string, indented)
        XCTAssertTrue(document.isDirty)

        // A small edit after a large change has its own Undo.
        step { textView.setSelectedRange(NSRange(location: 0, length: 0)); textView.insertText("x", replacementRange: textView.selectedRange()) }
        step { undo.undo() }
        XCTAssertEqual(textView.string, indented)
        step { undo.redo() }
        XCTAssertEqual(textView.string, "x" + indented)

        // Typing over a large selection.
        step { textView.selectAll(nil); textView.insertText("y", replacementRange: textView.selectedRange()) }
        XCTAssertEqual(textView.string, "y")
        step { undo.undo() }
        XCTAssertEqual(textView.string, "x" + indented)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: textView.textStorage!.length), "the restored text is selected")
    }

    func testReplaceAllInALargeFileUndoesAndKeepsHistory() throws {
        let lines = (0..<30_000).map { "row \($0), status active\n" }.joined()
        let (_, textView, document) = try open("rows.csv", lines)
        let undo = document.undoManager
        step { textView.setSelectedRange(NSRange(location: 0, length: 0)); textView.insertText("x", replacementRange: textView.selectedRange()) }

        // What the find bar's Replace All does: one change over every match.
        let text = textView.string as NSString
        var matches: [NSRange] = []
        var searched = NSRange(location: 0, length: text.length)
        while case let found = text.range(of: "active", options: .literal, range: searched), found.location != NSNotFound {
            matches.append(found)
            searched = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        XCTAssertEqual(matches.count, 30_000)
        step {
            XCTAssertTrue(textView.shouldChangeText(inRanges: matches.map { NSValue(range: $0) },
                                                    replacementStrings: Array(repeating: "on", count: matches.count)))
            for range in matches.reversed() { textView.replaceCharacters(in: range, with: "on") }
            textView.didChangeText()
        }
        let replaced = "x" + lines.replacingOccurrences(of: "active", with: "on")
        XCTAssertEqual(textView.string, replaced)
        step { undo.undo() }
        XCTAssertEqual(textView.string, "x" + lines)
        step { undo.redo() }
        XCTAssertEqual(textView.string, replaced)
        step { undo.undo() }
        step { undo.undo() }
        XCTAssertEqual(textView.string, lines, "the edit before Replace All still undoes")
    }

    func testPastingLargeTextUndoesAndRedoes() throws {
        let (controller, _, _) = try open("a.txt", "")
        let editor = controller.editor
        let textView = try XCTUnwrap(editor.textView), undo = try XCTUnwrap(editor.activeDocument?.undoManager)
        let big = String(repeating: "0123456789abcdef\n", count: 20_000)
        step { textView.insertText(big, replacementRange: NSRange(location: 0, length: 0)) }
        XCTAssertEqual(textView.string, big)
        step { undo.undo() }
        XCTAssertEqual(textView.string, "")
        step { undo.redo() }
        XCTAssertEqual(textView.string, big)
        step { undo.undo() }
        XCTAssertEqual(textView.string, "")

        // Paste, from a private pasteboard: never the user's clipboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PulseTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("日本 " + big, forType: .string)
        step { XCTAssertTrue(textView.readSelection(from: pasteboard)) }
        XCTAssertEqual(textView.string, "日本 " + big)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: textView.textStorage!.length, length: 0))
        step { undo.undo() }
        XCTAssertEqual(textView.string, "")
    }

    func testCopyPasteAndGrowthStayWithinTheLimits() throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let text = String(repeating: line, count: 90_000)  // 9 MB
        let (_, textView, document) = try open("big.txt", text)
        var refusals: [String] = []
        textView.onRefuse = { refusals.append($0) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PulseTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        textView.selectAll(nil)
        XCTAssertFalse(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes), "over 8 MB")
        XCTAssertEqual(pasteboard.string(forType: .string), "before")

        // Under 8 MB, but the file would pass 16 MB.
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: line, count: 80_000), forType: .string)  // 8,000,000 bytes
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.readSelection(from: pasteboard))
        XCTAssertEqual(document.length, (text as NSString).length)
        XCTAssertEqual(refusals.count, 2)
        XCTAssertTrue(refusals.allSatisfy { $0.hasPrefix("Pulse") })
    }

    func testCopyingALargeSelection() throws {
        let text = String(repeating: "naïve 日本 row\n", count: 30_000)
        let (_, textView, _) = try open("words.txt", text)
        // A private pasteboard: never the user's clipboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PulseTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        // What Copy writes: NSTextView's types for the selection, not `.string`.
        textView.selectAll(nil)
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), text)

        textView.setSelectedRange(NSRange(location: 6, length: 2))
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "日本")
    }

    func testOpeningAndSavingKeepTheText() throws {
        let root = try makeFolder(files: ["empty.txt": ""])
        let utf8 = root.appendingPathComponent("utf8.txt"), latin1 = root.appendingPathComponent("latin1.txt")
        try "naïve 日本 ✓\n".write(to: utf8, atomically: true, encoding: .utf8)
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: latin1)  // "café\n" in Latin-1: not UTF-8
        let document = try Document.open(utf8)
        XCTAssertEqual(document.storage.string, "naïve 日本 ✓\n")
        XCTAssertEqual(try Document.open(latin1).storage.string, "café\n")

        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: utf8.path)
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "→ ")
        try document.save()
        XCTAssertEqual(try String(contentsOf: utf8, encoding: .utf8), "→ naïve 日本 ✓\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: utf8.path)[.posixPermissions] as? Int, 0o750)
        XCTAssertEqual(try Document.open(root.appendingPathComponent("empty.txt")).length, 0)

        // Saved a chunk at a time: emoji (two UTF-16 units) across every chunk boundary.
        let large = String(repeating: "a 日本 😀 row\n", count: 60_000)
        document.storage.setAttributedString(NSAttributedString(string: large))
        try document.save()
        XCTAssertEqual(try String(contentsOf: utf8, encoding: .utf8), large)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       ["empty.txt", "latin1.txt", "utf8.txt"], "no temporary file left behind")
    }
}
