import AppKit
import XCTest
@testable import Pulse

/// The path bar under the tabs: the open file's path from the opened folder.
final class BreadcrumbTests: PulseTestCase {
    func testSegmentsStartAtTheOpenedFolder() {
        let root = URL(fileURLWithPath: "/work/app", isDirectory: true)
        XCTAssertEqual(BreadcrumbBar.segments(for: URL(fileURLWithPath: "/work/app/src/pages/Button/styles.module.scss"), root: root),
                       ["src", "pages", "Button", "styles.module.scss"])
        XCTAssertEqual(BreadcrumbBar.segments(for: URL(fileURLWithPath: "/work/app/README.md"), root: root), ["README.md"])
        XCTAssertEqual(BreadcrumbBar.segments(for: URL(fileURLWithPath: "/work/application/x.swift"), root: root),
                       ["work", "application", "x.swift"], "a sibling folder with a longer name is outside")
    }

    func testFilesOutsideTheFolderStartAtHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = home.appendingPathComponent("notes/todo.md")
        XCTAssertEqual(BreadcrumbBar.segments(for: file, root: URL(fileURLWithPath: "/work/app")), ["~", "notes", "todo.md"])
        XCTAssertEqual(BreadcrumbBar.segments(for: URL(fileURLWithPath: "/etc/hosts"), root: nil), ["etc", "hosts"])
    }

    func testTheBarFollowsTheActiveFile() throws {
        let root = try makeFolder(files: ["src/pages/Button/styles.module.scss": ".a {}\n", "README.md": "# Hi\n"])
        let controller = makeController(opening: [root, root.appendingPathComponent("src/pages/Button/styles.module.scss")])
        let editor = controller.editor
        layout(controller)
        XCTAssertFalse(editor.breadcrumbs.isHidden)
        XCTAssertEqual(editor.breadcrumbs.frame.height, BreadcrumbBar.height)
        XCTAssertEqual(editor.breadcrumbs.text, "src  ›  pages  ›  Button  ›  styles.module.scss")

        editor.open(root.appendingPathComponent("README.md"))
        XCTAssertEqual(editor.breadcrumbs.text, "README.md")
        editor.activate(0)
        XCTAssertEqual(editor.breadcrumbs.text, "src  ›  pages  ›  Button  ›  styles.module.scss", "switching tabs updates it")
    }

    func testHiddenForUntitledAndSpecialTabs() throws {
        let root = try makeFolder(files: ["a.swift": "\n"])
        let controller = makeController(opening: [root, root.appendingPathComponent("a.swift")])
        let editor = controller.editor
        editor.newDocument()
        layout(controller)
        XCTAssertTrue(editor.breadcrumbs.isHidden, "untitled: no path")
        XCTAssertEqual(editor.breadcrumbs.frame.height, 0, "and no gap above the text")
        controller.openKeyboardShortcuts(nil)
        XCTAssertTrue(editor.breadcrumbs.isHidden, "special tab: no path")
        editor.activate(0)
        XCTAssertFalse(editor.breadcrumbs.isHidden)
    }

    func testChangingTheFolderUpdatesThePath() throws {
        let root = try makeFolder(files: ["src/a.swift": "\n"])
        let controller = makeController(opening: [root, root.appendingPathComponent("src/a.swift")])
        XCTAssertEqual(controller.editor.breadcrumbs.text, "src  ›  a.swift")
        controller.setRoot(root.appendingPathComponent("src"))
        XCTAssertEqual(controller.editor.breadcrumbs.text, "a.swift")
    }
}
