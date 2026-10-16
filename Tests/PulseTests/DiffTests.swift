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
        XCTAssertEqual(diff.hunkLines, [0, 6])
        XCTAssertFalse(diff.isBinary)
        XCTAssertFalse(diff.isTruncated)

        // The text holds each line once, without its marker, and lineStarts point at them.
        let text = diff.text as NSString
        XCTAssertEqual(text.substring(with: NSRange(location: diff.lineStarts[3], length: 11)), "const b = 3")
        XCTAssertEqual(diff.line(containing: diff.lineStarts[4] + 2), 4)
        XCTAssertEqual(diff.line(containing: 0), 0)
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
        XCTAssertEqual(GitDiffLoader.arguments(for: GitDiffTarget(repository: repo, path: "a.swift", staged: false, kind: .modified)),
                       ["diff", "--no-color", "--no-ext-diff", "--", "a.swift"])
        XCTAssertEqual(GitDiffLoader.arguments(for: GitDiffTarget(repository: repo, path: "new.swift", staged: false, kind: .untracked)),
                       ["diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", "new.swift"])
        XCTAssertEqual(GitDiffLoader.arguments(for: GitDiffTarget(repository: repo, path: "b.swift", originalPath: "a.swift", staged: true, kind: .renamed)),
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
        XCTAssertTrue(view.string.contains("print(\"done\")"))
        XCTAssertFalse(view.isEditable)
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
