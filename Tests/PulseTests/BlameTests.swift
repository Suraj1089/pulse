import AppKit
import XCTest
@testable import Pulse

/// View › Blame: `git blame --incremental` read a chunk at a time, kept in
/// step with edits, drawn after the lines; nothing until asked, nothing
/// kept once it is turned off.
final class BlameTests: PulseTestCase {
    // MARK: Parsing

    private static let output = """
    1111111111111111111111111111111111111111 1 1 2
    author Ada Lovelace
    author-mail <ada@example.com>
    author-time 1700000000
    author-tz +0000
    committer Ada Lovelace
    committer-mail <ada@example.com>
    committer-time 1700000000
    committer-tz +0000
    summary First version
    boundary
    filename notes.txt
    2222222222222222222222222222222222222222 3 3 1
    author Grace Hopper
    author-mail <grace@example.com>
    author-time 1700086400
    author-tz +0000
    committer Grace Hopper
    committer-mail <grace@example.com>
    committer-time 1700086400
    committer-tz +0000
    summary Add a third line
    previous 1111111111111111111111111111111111111111 notes.txt
    filename notes.txt
    0000000000000000000000000000000000000000 5 5 1
    author Not Committed Yet
    author-mail <not.committed.yet>
    author-time 1700172800
    author-tz +0000
    committer Not Committed Yet
    committer-mail <not.committed.yet>
    committer-time 1700172800
    committer-tz +0000
    summary Version of notes.txt from notes.txt
    previous 2222222222222222222222222222222222222222 notes.txt
    filename notes.txt
    1111111111111111111111111111111111111111 2 4 1
    filename notes.txt

    """

    func testReadsIncrementalOutputInPieces() {
        let data = Data(BlameTests.output.utf8)
        var parser = GitBlame.Parser()
        // Chunks that split lines anywhere, as a pipe does.
        var index = 0
        while index < data.count {
            parser.consume(data.subdata(in: index..<min(index + 7, data.count)))
            index += 7
        }
        let blame = parser.finish()
        XCTAssertEqual(blame.lines, [0, 0, 1, 0, GitBlame.uncommitted])
        XCTAssertEqual(blame.commits.map { $0.author }, ["Ada Lovelace", "Grace Hopper"])
        XCTAssertEqual(blame.commits.map { $0.summary }, ["First version", "Add a third line"])
        XCTAssertEqual(blame.commits.first?.time, 1_700_000_000)

        let now: TimeInterval = 1_700_000_000 + 3 * 86_400
        XCTAssertEqual(blame.label(at: 0, now: now), "Ada Lovelace, 3 days ago · First version")
        XCTAssertEqual(blame.label(at: 2, now: now), "Grace Hopper, 2 days ago · Add a third line")
        XCTAssertEqual(blame.label(at: 4, now: now), "You · Not committed yet")
        XCTAssertNil(blame.label(at: 5, now: now), "past the end")
    }

    func testAges() {
        let now: TimeInterval = 1_000_000_000
        XCTAssertEqual(GitBlame.age(now - 30, now: now), "just now")
        XCTAssertEqual(GitBlame.age(now - 60, now: now), "1 minute ago")
        XCTAssertEqual(GitBlame.age(now - 5 * 3_600, now: now), "5 hours ago")
        XCTAssertEqual(GitBlame.age(now - 86_400, now: now), "1 day ago")
        XCTAssertEqual(GitBlame.age(now - 7 * 86_400, now: now), "1 week ago")
        XCTAssertEqual(GitBlame.age(now - 45 * 86_400, now: now), "1 month ago")
        XCTAssertEqual(GitBlame.age(now - 800 * 86_400, now: now), "2 years ago")
    }

    // MARK: Edits

    func testEditsMoveBlameWithTheLines() {
        let document = Document(url: nil, text: "one\ntwo\nthree\n")
        let a = GitBlame.Commit(author: "A", time: 0, summary: "a")
        let blame = FileBlame(result: GitBlame(commits: [a, a, a], lines: [0, 1, 2, GitBlame.unknown]))
        document.blame = blame
        let changed = GitBlame.uncommitted, unknown = GitBlame.unknown
        func edit(_ location: Int, _ length: Int, _ string: String, file: StaticString = #filePath, line: UInt = #line) {
            let range = NSRange(location: location, length: length)
            document.blameWillChange([range], [string])
            document.storage.replaceCharacters(in: range, with: string)
            document.invalidateLines()
            XCTAssertEqual(blame.result?.lines.count, document.lineCount, "one entry a line", file: file, line: line)
        }

        edit(4, 0, "new\n")
        XCTAssertEqual(blame.result?.lines, [0, changed, 1, 2, unknown], "a line typed above “two” leaves it as it was")
        edit(11, 0, "\n")
        XCTAssertEqual(blame.result?.lines, [0, changed, 1, changed, 2, unknown], "Return at the end of “two”: a new line after it")
        edit(13, 0, "x")
        XCTAssertEqual(blame.result?.lines, [0, changed, 1, changed, changed, unknown], "typing changes “three”")
        edit(4, 4, "")
        XCTAssertEqual(blame.result?.lines, [0, 1, changed, changed, unknown], "deleting the line “new” leaves “two” as it was")
        edit(3, 1, "")
        XCTAssertEqual(blame.result?.lines, [changed, changed, changed, unknown], "joining two lines changes the line")
        XCTAssertEqual(document.storage.string, "onetwo\n\nxthree\n")
    }

    // MARK: In the editor, against a real repository

    private func makeRepository() throws -> URL {
        let root = try makeFolder(files: ["notes.txt": "alpha\nbeta\n"])
        try git("init", "-q", in: root)
        try git("add", "-A", in: root)
        try git("commit", "-q", "-m", "First notes", in: root)
        try "alpha\nbeta\ngamma\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try git("commit", "-q", "-am", "Add gamma", in: root)
        return root
    }

    private func blameButton(_ controller: MainWindowController) throws -> NSButton {
        try XCTUnwrap(views(NSButton.self, in: controller).first { $0.action == #selector(MainWindowController.toggleBlame(_:)) })
    }

    private func blameMenuItem(_ controller: MainWindowController) -> (enabled: Bool, state: NSControl.StateValue) {
        let item = NSMenuItem(title: "", action: #selector(MainWindowController.toggleBlame(_:)), keyEquivalent: "")
        let enabled = controller.validateMenuItem(item)
        return (enabled, item.state)
    }

    func testBlameIsOffUntilAskedThenShowsWhoChangedEachLine() throws {
        let root = try makeRepository()
        let controller = makeController(opening: [root, root.appendingPathComponent("notes.txt")])
        let document = try XCTUnwrap(controller.editor.activeDocument)
        let textView = try XCTUnwrap(controller.editor.textView)
        XCTAssertNil(document.blame, "off by default: nothing kept, git not run")
        let button = try blameButton(controller)
        XCTAssertNil(button.target, "goes up the responder chain to its window, like View › Blame")
        XCTAssertFalse(button.isHidden, "the file is in a repository")
        XCTAssertEqual(button.title, "Blame")
        XCTAssertTrue(blameMenuItem(controller).enabled)
        XCTAssertEqual(blameMenuItem(controller).state, .off)

        controller.toggleBlame(button)
        XCTAssertEqual(blameMenuItem(controller).state, .on)
        // Typed before git answers: the new line is the user's, and the
        // lines below it still get their commits. (Not saved meanwhile, so
        // git reads the file as it was.)
        EditorViewController.autosaveEnabled = false
        textView.insertText("top\n", replacementRange: NSRange(location: 0, length: 0))
        wait(timeout: 10, "blame") { document.blame?.result != nil }

        let blame = try XCTUnwrap(document.blame?.result)
        let now = Date().timeIntervalSince1970
        XCTAssertEqual(blame.label(at: 0, now: now), "You · Not committed yet")
        XCTAssertEqual(blame.label(at: 1, now: now), "Pulse Tests, just now · First notes")
        XCTAssertEqual(blame.label(at: 2, now: now), "Pulse Tests, just now · First notes")
        XCTAssertEqual(blame.label(at: 3, now: now), "Pulse Tests, just now · Add gamma")
        XCTAssertNil(blame.label(at: 4, now: now), "the empty line after the last line break")

        // Shown after the first line of each commit's run, and after the caret's line.
        layout(controller)
        XCTAssertEqual(textView.selectedRange().location, 4, "the caret is on line 1, after the typed line")
        XCTAssertEqual(textView.blameAnnotations(in: textView.visibleRect).map { $0.line }, [0, 1, 3])
        textView.setSelectedRange(NSRange(location: document.start(ofLine: 2), length: 0))
        let annotations = textView.blameAnnotations(in: textView.visibleRect)
        XCTAssertEqual(annotations.map { $0.line }, [0, 1, 2, 3])
        XCTAssertEqual(annotations.map { $0.uncommitted }, [true, false, false, false])
        let gamma = try XCTUnwrap(annotations.last)
        let onScreen = textView.firstRect(forCharacterRange: NSRange(location: document.start(ofLine: 3) + 5, length: 0), actualRange: nil)
        let lineEnd = textView.convert(textView.window!.convertFromScreen(onScreen), from: nil)
        XCTAssertGreaterThan(gamma.point.x, lineEnd.minX, "after the line's text")

        // Off again: everything it kept goes with it.
        weak var released = document.blame
        controller.toggleBlame(nil)
        XCTAssertNil(document.blame)
        XCTAssertNil(released, "turning blame off frees it")
        XCTAssertTrue(textView.blameAnnotations(in: textView.visibleRect).isEmpty)
        XCTAssertEqual(blameMenuItem(controller).state, .off)
    }

    func testAFileNotCommittedYetSaysSoAndBlameTurnsOff() throws {
        let root = try makeRepository()
        try "draft\n".write(to: root.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        let controller = makeController(opening: [root, root.appendingPathComponent("draft.txt")])
        let document = try XCTUnwrap(controller.editor.activeDocument)

        controller.toggleBlame(nil)
        XCTAssertNotNil(document.blame)
        wait(timeout: 10, "git to answer") { document.blame == nil }
        XCTAssertTrue(labels(in: controller.editor.statusBar).contains("“draft.txt” isn’t committed yet, so its lines have no history."))
        XCTAssertEqual(blameMenuItem(controller).state, .off)
    }

    func testFilesOutsideARepositoryHaveNoBlame() throws {
        let root = try makeFolder(files: ["plain.txt": "text\n"])
        let controller = makeController(opening: [root, root.appendingPathComponent("plain.txt")])
        XCTAssertTrue(try blameButton(controller).isHidden)
        XCTAssertFalse(blameMenuItem(controller).enabled)

        controller.toggleBlame(nil)
        XCTAssertNil(controller.editor.activeDocument?.blame)
    }
}
