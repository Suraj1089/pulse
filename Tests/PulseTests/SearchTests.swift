import AppKit
import XCTest
@testable import Pulse

/// Project search, including blocks of code that span lines. Each search
/// test runs with ripgrep (when installed) and with the built-in scan.
final class SearchTests: PulseTestCase {
    private let snippet = "'&:hover': { backgroundColor: theme.palette.grey[100] },"

    private func fixture() throws -> URL {
        try makeFolder(files: [
            "one-line.tsx": "const a = {\n  '&:hover': { backgroundColor: theme.palette.grey[100] },\n};\n",
            "multi-line.tsx": "const b = {\n  '&:hover': {\n    backgroundColor: theme.palette.grey[100],\n  },\n};\n",
            "crlf.tsx": "x\r\n  '&:hover': {\r\n backgroundColor: theme.palette.grey[100] },\r\n",
            "other.tsx": "const c = { color: 'red' };\n",
        ])
    }

    private func search(_ query: String, in root: URL, ripgrep: Bool, caseSensitive: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) -> [SearchFileResult] {
        var results: [SearchFileResult]?
        let search = ProjectSearch()
        search.run(query: query, root: root, caseSensitive: caseSensitive, index: FileIndex(root: root), useRipgrep: ripgrep) { found, _ in
            results = found
        }
        wait(timeout: 10, "search results", file: file, line: line) { results != nil }
        return results ?? []
    }

    private var modes: [Bool] {
        ProjectSearch.ripgrep == nil ? [false] : [true, false]
    }

    func testOneLineQueryFindsTheBlockHoweverItIsWrapped() throws {
        let root = try fixture()
        for ripgrep in modes {
            let results = search(snippet, in: root, ripgrep: ripgrep)
            let files = results.map(\.relativePath).sorted()
            // multi-line.tsx has a trailing comma after [100], so the one-line snippet doesn't match it exactly.
            XCTAssertTrue(files.contains("one-line.tsx"), "ripgrep=\(ripgrep): \(files)")
            XCTAssertTrue(files.contains("crlf.tsx"), "spans CRLF lines (ripgrep=\(ripgrep)): \(files)")
            XCTAssertFalse(files.contains("other.tsx"))
        }
    }

    func testPastedMultiLineBlockIsFoundWithDifferentIndentation() throws {
        let root = try fixture()
        let pasted = "'&:hover': {\n        backgroundColor: theme.palette.grey[100],\n},"
        for ripgrep in modes {
            let results = search(pasted, in: root, ripgrep: ripgrep)
            let match = try XCTUnwrap(results.first { $0.relativePath == "multi-line.tsx" }?.matches.first, "ripgrep=\(ripgrep)")
            XCTAssertEqual(match.line, 2, "the block starts on line 2")
            XCTAssertEqual(match.column, 2, "after the indentation")
            XCTAssertEqual(match.preview, "'&:hover': {", "the preview is the first line of the block")
            XCTAssertEqual(match.previewStart, 0)
            let expected = "'&:hover': {\n    backgroundColor: theme.palette.grey[100],\n  },"
            XCTAssertEqual(match.length, (expected as NSString).length, "the match covers the whole block")
        }
    }

    func testBlockSearchIsCaseInsensitiveUnlessAsked() throws {
        let root = try fixture()
        for ripgrep in modes {
            XCTAssertFalse(search("BACKGROUNDCOLOR: THEME.palette", in: root, ripgrep: ripgrep).isEmpty, "ripgrep=\(ripgrep)")
            XCTAssertTrue(search("BACKGROUNDCOLOR: THEME.palette", in: root, ripgrep: ripgrep, caseSensitive: true).isEmpty)
        }
    }

    func testSingleWordsStillSearchLineByLine() throws {
        let root = try fixture()
        for ripgrep in modes {
            let results = search("palette", in: root, ripgrep: ripgrep)
            XCTAssertEqual(Set(results.map(\.relativePath)), ["one-line.tsx", "multi-line.tsx", "crlf.tsx"], "ripgrep=\(ripgrep)")
            XCTAssertEqual(results.first { $0.relativePath == "multi-line.tsx" }?.matches.first?.line, 3)
        }
    }

    func testPatternTreatsEveryCharacterLiterally() {
        let words = ProjectSearch.words(of: "a.b (c)  [d]+\n{e}|f")
        XCTAssertEqual(words, ["a.b", "(c)", "[d]+", "{e}|f"])
        XCTAssertNil(ProjectSearch.words(of: "  single  "), "one word stays a plain search")
        XCTAssertEqual(ProjectSearch.ripgrepPattern(["a.b", "[d]+"]), #"a\.b\s+\[d\]\+"#)
    }

    func testFindInProjectSeedsAMultiLineSelectionAndRevealSelectsTheBlock() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("multi-line.tsx")
        let controller = makeController(opening: [root, file])
        let editor = controller.editor
        let block = "'&:hover': {\n    backgroundColor: theme.palette.grey[100],\n  },"
        let text = editor.textView.string as NSString
        editor.textView.setSelectedRange(text.range(of: block))

        controller.findInProject(nil)
        layout(controller)
        let field = try XCTUnwrap(views(NSSearchField.self, in: controller).first { $0.placeholderString == "Search project" })
        XCTAssertEqual(field.stringValue, "'&:hover': { backgroundColor: theme.palette.grey[100], },")

        let results = try XCTUnwrap(outline("Search results", in: controller))
        wait(timeout: 10, "results in the panel") { results.numberOfRows > 0 }
        let match = try XCTUnwrap(search(field.stringValue, in: root, ripgrep: ProjectSearch.ripgrep != nil)
            .first { $0.relativePath == "multi-line.tsx" }?.matches.first)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.reveal(line: match.line, column: match.column, length: match.length)
        XCTAssertEqual(editor.selectedText, block, "opening the result selects the whole block")
    }
}
