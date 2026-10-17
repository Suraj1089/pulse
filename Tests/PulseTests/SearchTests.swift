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

    private func search(_ query: String, in root: URL, ripgrep: Bool, caseSensitive: Bool = false, filter: PathFilter = PathFilter(),
                        file: StaticString = #filePath, line: UInt = #line) -> [SearchFileResult] {
        var results: [SearchFileResult]?
        let search = ProjectSearch()
        search.run(query: query, root: root, caseSensitive: caseSensitive, filter: filter, index: FileIndex(root: root),
                   useRipgrep: ripgrep) { found, _ in
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

    func testCommonWordStopsAtTheMatchCap() throws {
        let line = "let value = 1\n"
        var files: [String: String] = [:]
        for index in 0..<30 { files["file\(index).swift"] = String(repeating: line, count: 150) }
        files["crlf.swift"] = "a\r\nlet value = 2\r\n"
        let root = try makeFolder(files: files)
        for ripgrep in modes {
            for query in ["value", "let value"] {
                var found: (results: [SearchFileResult], truncated: Bool)?
                let search = ProjectSearch()
                search.run(query: query, root: root, caseSensitive: false, index: FileIndex(root: root),
                           useRipgrep: ripgrep) { found = ($0, $1) }
                wait(timeout: 10, "search results") { found != nil }
                let total = found?.results.reduce(0) { $0 + $1.matches.count } ?? 0
                XCTAssertEqual(total, ProjectSearch.maxMatches, "\(query) ripgrep=\(ripgrep)")
                XCTAssertEqual(found?.truncated, true, "\(query) ripgrep=\(ripgrep)")
            }
            let crlf = search("value = 2", in: root, ripgrep: ripgrep).first?.matches.first
            XCTAssertEqual(crlf?.preview, "let value = 2", "no \\r in a CRLF line's preview (ripgrep=\(ripgrep))")
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

    // MARK: Files to include / exclude

    func testPathFilterFollowsVSCodePatterns() {
        let paths = ["src/a.ts", "src/a.tsx", "src/util/b.ts", "src/test/c.ts", "lib/src/d.ts", "test/e.ts", "README.md", "Docs/Guide.MD"]
        func kept(_ include: String, _ exclude: String = "") -> [String] {
            paths.filter(PathFilter(include: include, exclude: exclude).matches)
        }
        XCTAssertEqual(kept("*.ts"), ["src/a.ts", "src/util/b.ts", "src/test/c.ts", "lib/src/d.ts", "test/e.ts"], "a name matches at any depth")
        XCTAssertEqual(kept("src"), ["src/a.ts", "src/a.tsx", "src/util/b.ts", "src/test/c.ts", "lib/src/d.ts"],
                       "a folder takes everything in it, at any depth")
        XCTAssertEqual(kept("./src"), ["src/a.ts", "src/a.tsx", "src/util/b.ts", "src/test/c.ts"], "./ ties it to the project folder")
        XCTAssertEqual(kept("src/**/*.ts"), ["src/a.ts", "src/util/b.ts", "src/test/c.ts", "lib/src/d.ts"])
        XCTAssertEqual(kept("*.{ts,tsx}", "test"), ["src/a.ts", "src/a.tsx", "src/util/b.ts", "lib/src/d.ts"],
                       "braces are alternatives, and an exclude beats an include")
        XCTAssertEqual(kept("*.md"), ["README.md", "Docs/Guide.MD"], "case doesn't matter")
        XCTAssertEqual(kept("", "src, *.md"), ["test/e.ts"])
        XCTAssertEqual(kept("*, ./"), paths, "including everything restricts nothing")
        XCTAssertTrue(PathFilter(include: " , ", exclude: ",").isEmpty)
        XCTAssertEqual(PathFilter.split("*.{ts,tsx}, docs ,,src"), ["*.{ts,tsx}", "docs", "src"])
        XCTAssertEqual(PathFilter(include: "./src, a[1]", exclude: "*.md").ripgrepArguments, [
            "--iglob", "/src", "--iglob", "/src/**", "--iglob", #"**/a\[1\]"#, "--iglob", #"**/a\[1\]/**"#,
            "--iglob", "!**/*.md", "--iglob", "!**/*.md/**",
        ], "includes first: ripgrep lets the last matching glob win")
    }

    func testIncludeAndExcludeLimitTheSearch() throws {
        let root = try makeFolder(files: [
            "src/app.ts": "let needle = 1\n",
            "src/app.test.ts": "let needle = 2\n",
            "src/vendor/lib.ts": "let needle = 3\n",
            "docs/notes.md": "let needle\n",
        ])
        for ripgrep in modes {
            let lines = search("needle", in: root, ripgrep: ripgrep, filter: PathFilter(include: "src", exclude: "vendor, *.test.ts"))
            XCTAssertEqual(lines.map(\.relativePath), ["src/app.ts"], "ripgrep=\(ripgrep)")
            let blocks = search("let needle", in: root, ripgrep: ripgrep, filter: PathFilter(include: "*.ts", exclude: "./src/vendor"))
            XCTAssertEqual(Set(blocks.map(\.relativePath)), ["src/app.ts", "src/app.test.ts"], "multi-word search too (ripgrep=\(ripgrep))")
        }
    }

    func testSearchDetailsShowIncludeAndExcludeFields() throws {
        let root = try makeFolder(files: [
            "src/app.ts": "needle\n",
            "src/app.test.ts": "needle\n",
            "docs/notes.md": "needle\n",
        ])
        let controller = makeController(opening: [root])
        controller.findInProject(nil)
        layout(controller)
        func patternField(_ label: String) -> NSTextField? {
            views(NSTextField.self, in: controller).first { $0.accessibilityLabel() == label }
        }
        XCTAssertNil(patternField("Files to include"), "built the first time they are shown")

        let toggle = try XCTUnwrap(views(NSButton.self, in: controller).first { $0.toolTip == "Toggle search details" })
        toggle.performClick(nil)
        layout(controller)
        let include = try XCTUnwrap(patternField("Files to include"))
        let exclude = try XCTUnwrap(patternField("Files to exclude"))
        XCTAssertGreaterThan(include.frame.width, 100, "the fields span the sidebar")

        let query = try XCTUnwrap(views(NSSearchField.self, in: controller).first { $0.placeholderString == "Search project" })
        let results = try XCTUnwrap(outline("Search results", in: controller))
        func files() -> [String] {
            (0..<results.numberOfRows).compactMap { (results.item(atRow: $0) as? SearchFileResult)?.relativePath }.sorted()
        }
        controller.window?.makeFirstResponder(nil)  // showing the fields focused the include field; end that edit
        query.stringValue = "needle"
        include.stringValue = "src"
        exclude.stringValue = "*.test.ts"
        include.sendAction(include.action, to: include.target)  // Return in the field
        wait(timeout: 10, "filtered results") { files() == ["src/app.ts"] }

        toggle.performClick(nil)
        wait(timeout: 10, "hidden patterns no longer apply") { files() == ["docs/notes.md", "src/app.test.ts", "src/app.ts"] }
    }
}
