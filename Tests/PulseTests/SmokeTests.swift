import AppKit
import XCTest
@testable import Pulse

final class SmokeTests: PulseTestCase {
    func testOpeningAFolderShowsItsFilesAndOpensAFile() throws {
        let root = try makeFolder(files: ["main.swift": "import AppKit\n", "docs/readme.md": "# Hi\n"])
        let controller = makeController(opening: [root])

        XCTAssertEqual(controller.root, root)
        let files = try XCTUnwrap(outline("Files", in: controller))
        XCTAssertEqual(rowTexts(files), ["docs", "main.swift"])

        // NSTableView's mouse tracking ignores synthetic clicks in a window
        // that was never shown, so rows are activated the way a click does.
        controller.sidebarForTesting.fileTree.activate(row: 1)
        XCTAssertEqual(controller.editor.activeDocument?.url, root.appendingPathComponent("main.swift"))
    }
}
