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

        click(row: 1, in: files)
        XCTAssertEqual(controller.editor.activeDocument?.url, root.appendingPathComponent("main.swift"))
    }
}
