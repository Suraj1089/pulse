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

    func testTheOpenFileIsHighlightedInTheTree() throws {
        let root = try makeFolder(files: ["main.swift": "let a = 1\n", "docs/readme.md": "# Hi\n"])
        let main = root.appendingPathComponent("main.swift"), readme = root.appendingPathComponent("docs/readme.md")
        let controller = makeController(opening: [root, main, readme])
        let files = try XCTUnwrap(outline("Files", in: controller))
        func selected() -> String? { (files.item(atRow: files.selectedRow) as? FileNode)?.name }

        wait("readme.md selected") { selected() == "readme.md" }
        XCTAssertTrue(files.isItemExpanded(files.item(atRow: 0)), "its folder opens to show it")
        controller.editor.open(main)
        wait("main.swift selected") { selected() == "main.swift" }

        // Focus is in the editor, yet the row is tinted with the accent color,
        // not AppKit's faint gray for an unfocused table.
        let rowView = try XCTUnwrap(files.rowView(atRow: files.selectedRow, makeIfNecessary: true) as? FileTreeRowView)
        XCTAssertFalse(rowView.isEmphasized)
        let image = try XCTUnwrap(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
        rowView.cacheDisplay(in: rowView.bounds, to: image)
        let pixel = try XCTUnwrap(image.colorAt(x: image.pixelsWide - 3, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.alphaComponent, 0.1, "the selection is drawn")
        func rgb(_ color: NSColor) -> [CGFloat] { [color.redComponent, color.greenComponent, color.blueComponent] }
        let accentColor = try XCTUnwrap(NSColor.controlAccentColor.usingColorSpace(.sRGB))
        let accent = rgb(accentColor), tint = rgb(pixel)
        if accent.max()! - accent.min()! > 0.2 {  // a colored accent (not Graphite)
            XCTAssertGreaterThan(tint.max()! - tint.min()!, 0.02, "not gray")
            XCTAssertEqual(tint.firstIndex(of: tint.max()!), accent.firstIndex(of: accent.max()!), "tinted like the accent color")
        }

        controller.showWelcome(nil)
        wait("no selection for a tab without a file") { files.selectedRow == -1 }
    }
}
