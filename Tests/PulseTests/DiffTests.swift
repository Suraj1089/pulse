import AppKit
import XCTest
@testable import Pulse

final class DiffTests: PulseTestCase {
    // MARK: Parsing

    func testParsesAUnifiedDiff() {
        let output = """
        diff --git a/app.js b/app.js
        index 1111111..2222222 100644
        --- a/app.js
        +++ b/app.js
        @@ -1,3 +1,4 @@ function -start() {
         const a = 1
        -const b = 2
        +const b = 3
        +const c = 4
         export { a }
        @@ -10,2 +11,2 @@
        -old()
        +new()
        \\ No newline at end of file

        """
        let diff = GitDiff.parse(Data(output.utf8))
        XCTAssertEqual(diff.kinds, [.hunk, .context, .removed, .added, .added, .context, .hunk, .removed, .added, .note])
        XCTAssertEqual(diff.oldNumbers, [0, 1, 2, 0, 0, 3, 0, 10, 0, 0])
        XCTAssertEqual(diff.newNumbers, [0, 1, 0, 2, 3, 4, 0, 0, 11, 0])
        XCTAssertEqual(diff.added, 3)
        XCTAssertEqual(diff.removed, 2)
        XCTAssertEqual(diff.changeLines, [2, 7])
        XCTAssertFalse(diff.isBinary)
        XCTAssertFalse(diff.isTruncated)
        XCTAssertFalse(diff.isWholeFile)

        // Within a change, the k-th removed line pairs with the k-th added line.
        XCTAssertEqual(diff.partner(of: 2), 3)
        XCTAssertEqual(diff.partner(of: 3), 2)
        XCTAssertNil(diff.partner(of: 4), "an added line with no removed line to pair with")
        XCTAssertEqual(diff.partner(of: 7), 8)
        XCTAssertNil(diff.partner(of: 1), "context")

        // The text holds each line once, without its marker, and lineStarts point at them.
        let text = diff.text as NSString
        XCTAssertEqual(text.substring(with: NSRange(location: diff.lineStarts[3], length: 11)), "const b = 3")
        XCTAssertEqual(diff.line(containing: diff.lineStarts[4] + 2), 4)
        XCTAssertEqual(diff.line(containing: 0), 0)
    }

    func testParsesAWholeFileDiffWithoutItsHunkHeader() {
        let output = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1,6 +1,6 @@
         one
        -two
        +2
         three
         four
        -five
        +5
         six

        """
        let diff = GitDiff.parse(Data(output.utf8), wholeFile: true)
        XCTAssertTrue(diff.isWholeFile)
        XCTAssertEqual(diff.kinds, [.context, .removed, .added, .context, .context, .removed, .added, .context])
        XCTAssertEqual(diff.oldNumbers, [1, 2, 0, 3, 4, 5, 0, 6])
        XCTAssertEqual(diff.newNumbers, [1, 0, 2, 3, 4, 0, 5, 6])
        XCTAssertEqual(diff.changeLines, [1, 5])
        XCTAssertEqual(diff.text, "one\ntwo\n2\nthree\nfour\nfive\n5\nsix\n")
        XCTAssertEqual((diff.text as NSString).substring(with: diff.range(ofLine: 7)), "six")
    }

    func testEditedPartOfAChangedLine() {
        func edited(_ old: String, _ new: String) -> [String]? {
            let text = (old + "\n" + new) as NSString
            let a = NSRange(location: 0, length: (old as NSString).length)
            let b = NSRange(location: a.length + 1, length: (new as NSString).length)
            return GitDiff.editedRanges(in: text, a, b).map { [text.substring(with: $0.0), text.substring(with: $0.1)] }
        }
        XCTAssertEqual(edited("let b = 2", "let b = 3"), ["2", "3"])
        XCTAssertEqual(edited("f(a)", "f(a, b)"), ["", ", b"], "an insertion")
        XCTAssertEqual(edited("if ready and blocks.exists():", "if ready and not fleet() \\"),
                       ["blocks.exists():", "not fleet() \\"])
        XCTAssertNil(edited("import Foundation", "let total = 12"), "a rewrite is left as a whole-line change")
        XCTAssertNil(edited("same", "same"))
        XCTAssertNil(edited("", "added"))
    }

    func testHunkHeaderRangesIgnoreTheFunctionName() {
        let (old, new) = GitDiff.hunkStarts("@@ -12,7 +40,9 @@ func move(-1, +2)")
        XCTAssertEqual(old, 12)
        XCTAssertEqual(new, 40)
    }

    func testParsesACombinedConflictDiff() {
        let output = """
        diff --cc notes.txt
        index 1111111,2222222..0000000
        --- a/notes.txt
        +++ b/notes.txt
        @@@ -1,1 -1,1 +1,5 @@@
        ++<<<<<<< HEAD
         +ours
        ++=======
        + theirs
        ++>>>>>>> branch

        """
        let diff = GitDiff.parse(Data(output.utf8))
        XCTAssertEqual(diff.kinds, [.hunk, .added, .added, .added, .added, .added])
        XCTAssertEqual(diff.newNumbers, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual((diff.text as NSString).substring(with: NSRange(location: diff.lineStarts[2], length: 4)), "ours")
    }

    func testBinaryFilesHaveNoLines() {
        let output = "diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n"
        let diff = GitDiff.parse(Data(output.utf8))
        XCTAssertTrue(diff.isBinary)
        XCTAssertTrue(diff.isEmpty)
    }

    func testVeryLongDiffsAreCutOff() {
        var output = "diff --git a/big.txt b/big.txt\n@@ -0,0 +1,70000 @@\n"
        output += String(repeating: "+line\n", count: 70_000)
        let diff = GitDiff.parse(Data(output.utf8))
        XCTAssertTrue(diff.isTruncated)
        XCTAssertEqual(diff.lineCount, GitDiff.maxLines)
    }

    func testArgumentsPerKindOfChange() throws {
        let repo = URL(fileURLWithPath: "/tmp/repo")
        XCTAssertEqual(GitDiffLoader.arguments(for: GitDiffTarget(repository: repo, path: "a.swift", staged: false, kind: .modified), wholeFile: false),
                       ["diff", "--no-color", "--no-ext-diff", "--", "a.swift"])
        XCTAssertEqual(GitDiffLoader.arguments(for: GitDiffTarget(repository: repo, path: "a.swift", staged: false, kind: .modified), wholeFile: true),
                       ["diff", "--no-color", "--no-ext-diff", "--unified=50000", "--", "a.swift"])
        XCTAssertEqual(GitDiffLoader.arguments(for: GitDiffTarget(repository: repo, path: "new.swift", staged: false, kind: .untracked), wholeFile: false),
                       ["diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", "new.swift"])
        XCTAssertEqual(GitDiffLoader.arguments(for: GitDiffTarget(repository: repo, path: "b.swift", originalPath: "a.swift", staged: true, kind: .renamed), wholeFile: false),
                       ["diff", "--no-color", "--no-ext-diff", "--cached", "-M", "--", "a.swift", "b.swift"])
    }

    // MARK: The diff tab, against a real repository

    private func makeRepository() throws -> URL {
        let root = try makeFolder(files: ["main.swift": "let a = 1\nlet b = 2\nprint(a + b)\n"])
        try git("init", "-q", in: root)
        try git("add", "-A", in: root)
        try git("commit", "-q", "-m", "first", in: root)
        return root
    }

    private func diffView(in controller: MainWindowController) -> DiffTextView? {
        views(DiffTextView.self, in: controller).first
    }

    func testDiffTabShowsWorkingTreeChanges() throws {
        let root = try makeRepository()
        try "let a = 1\nlet b = 3\nprint(a + b)\nprint(\"done\")\n".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let controller = makeController(opening: [root])

        controller.editor.openDiff(GitDiffTarget(repository: root, path: "main.swift", staged: false, kind: .modified))
        layout(controller)
        XCTAssertEqual(controller.editor.activeDocument?.special, .diff)
        XCTAssertEqual(controller.editor.activeDocument?.displayName, "main.swift (Changes)")
        wait(timeout: 10, "the diff") { diffView(in: controller)?.diff != nil }

        let view = try XCTUnwrap(diffView(in: controller))
        let diff = try XCTUnwrap(view.diff)
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
        XCTAssertTrue(diff.text.isEmpty, "only the text view keeps the text")
        XCTAssertEqual(view.string, "let a = 1\nlet b = 2\nlet b = 3\nprint(a + b)\nprint(\"done\")\n", "the whole file, no @@ lines")
        XCTAssertFalse(view.isEditable)
    }

    func testDiffTabShowsTheWholeFileAndOpensAtTheFirstChange() throws {
        let lines = (1...200).map { "line \($0)" }
        let root = try makeFolder(files: ["long.txt": lines.joined(separator: "\n") + "\n"])
        try git("init", "-q", in: root)
        try git("add", "-A", in: root)
        try git("commit", "-q", "-m", "first", in: root)
        var edited = lines
        edited[119] = "line one hundred and twenty"
        try (edited.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
        let controller = makeController(opening: [root])

        controller.editor.openDiff(GitDiffTarget(repository: root, path: "long.txt", staged: false, kind: .modified))
        layout(controller)
        wait(timeout: 10, "the diff") { diffView(in: controller)?.diff != nil }
        let view = try XCTUnwrap(diffView(in: controller))
        let diff = try XCTUnwrap(view.diff)
        XCTAssertTrue(diff.isWholeFile)
        XCTAssertEqual(diff.lineCount, 201, "every line of the file, plus the removed one")
        XCTAssertTrue(view.string.hasPrefix("line 1\nline 2\n"))
        XCTAssertTrue(view.string.hasSuffix("line 200\n"))
        XCTAssertEqual(diff.changeLines, [119])
        XCTAssertEqual(diff.partner(of: 119), 120)
        XCTAssertGreaterThan(view.visibleRect.minY, 0, "scrolled to the change, not left at the top")
    }

    func testAFileTooLongToShowWholeShowsItsChanges() throws {
        let lines = (1...60_000).map(String.init)
        let root = try makeFolder(files: ["huge.txt": lines.joined(separator: "\n") + "\n"])
        try git("init", "-q", in: root)
        try git("add", "-A", in: root)
        try git("commit", "-q", "-m", "first", in: root)
        var edited = lines
        edited[30_000] = "changed"
        try (edited.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("huge.txt"), atomically: true, encoding: .utf8)
        let controller = makeController(opening: [root])

        controller.editor.openDiff(GitDiffTarget(repository: root, path: "huge.txt", staged: false, kind: .modified))
        layout(controller)
        wait(timeout: 20, "the diff") { diffView(in: controller)?.diff != nil }
        let diff = try XCTUnwrap(diffView(in: controller)?.diff)
        XCTAssertFalse(diff.isWholeFile)
        XCTAssertFalse(diff.isTruncated)
        XCTAssertEqual(diff.kinds.first, .hunk)
        XCTAssertEqual(diff.lineCount, 9, "the hunk header, the removed and added line, three lines either side")
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 1)
    }

    func testOneDiffTabIsReusedAndNotSavedInTheSession() throws {
        let root = try makeRepository()
        try "let a = 2\n".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "hello\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let controller = makeController(opening: [root, root.appendingPathComponent("main.swift")])

        controller.editor.openDiff(GitDiffTarget(repository: root, path: "main.swift", staged: false, kind: .modified))
        controller.editor.openDiff(GitDiffTarget(repository: root, path: "new.txt", staged: false, kind: .untracked))
        XCTAssertEqual(controller.editor.documents.filter { $0.special == .diff }.count, 1)
        XCTAssertEqual(controller.editor.activeDocument?.displayName, "new.txt (Changes)")
        layout(controller)
        wait(timeout: 10, "the untracked file's diff") { diffView(in: controller)?.diff?.added == 1 }

        controller.saveSession()
        let state = try XCTUnwrap(SessionState.load())
        XCTAssertEqual(state.entries.count, 1, "the diff tab is left out")
        XCTAssertNil(state.entries.first?.special)
        XCTAssertNil(state.active, "the active tab was the diff, which is not saved")
    }

    func testStagedDiffComparesTheIndexWithTheLastCommit() throws {
        let root = try makeRepository()
        try "let a = 1\nlet b = 2\nprint(a + b)\n// staged\n".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try git("add", "main.swift", in: root)
        try "changed again, not staged\n".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let controller = makeController(opening: [root])

        controller.editor.openDiff(GitDiffTarget(repository: root, path: "main.swift", staged: true, kind: .modified))
        layout(controller)
        XCTAssertEqual(controller.editor.activeDocument?.displayName, "main.swift (Staged)")
        wait(timeout: 10, "the staged diff") { diffView(in: controller)?.diff != nil }
        let diff = try XCTUnwrap(diffView(in: controller)?.diff)
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 0)
        XCTAssertTrue(diffView(in: controller)?.string.contains("// staged") ?? false)
    }
}
