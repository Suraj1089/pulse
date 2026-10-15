import AppKit
import XCTest
@testable import Pulse

final class PreferencesTests: PulseTestCase {
    // MARK: Font sizes

    func testEditorSidebarAndTerminalSizesAreIndependent() throws {
        let root = try makeFolder(files: ["main.swift": "let a = 1\n"])
        let controller = makeController(opening: [root, root.appendingPathComponent("main.swift")])

        controller.changeFontSize(of: .sidebar, by: 3)
        layout(controller)
        XCTAssertEqual(Theme.fontSize(for: .sidebar), 16)
        XCTAssertEqual(Theme.fontSize(for: .editor), 13, "the editor keeps its size")
        let files = try XCTUnwrap(outline("Files", in: controller))
        XCTAssertEqual(files.rowHeight, 25)
        let cell = files.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTableCellView
        XCTAssertEqual(cell?.textField?.font?.pointSize, 16)

        let storage = try XCTUnwrap(controller.editor.activeDocument?.storage)
        controller.changeFontSize(of: .editor, by: 2)
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 15)
        XCTAssertEqual(Theme.fontSize(for: .sidebar), 16, "the sidebar keeps its size")
    }

    func testTerminalFollowsTheEditorUntilSetOnItsOwn() {
        let controller = makeController()
        XCTAssertEqual(Theme.fontSize(for: .terminal), 12)
        controller.changeFontSize(of: .editor, by: 3)
        XCTAssertEqual(Theme.fontSize(for: .terminal), 15)

        controller.changeFontSize(of: .terminal, by: 1)
        controller.changeFontSize(of: .editor, by: -3)
        XCTAssertEqual(Theme.fontSize(for: .terminal), 16, "set on its own, the terminal no longer follows")

        controller.changeFontSize(of: .terminal, by: nil)
        XCTAssertEqual(Theme.fontSize(for: .terminal), 12, "reset goes back to following the editor")
    }

    func testFontSizesStayInRange() {
        let controller = makeController()
        for _ in 0..<30 { controller.changeFontSize(of: .sidebar, by: 1) }
        XCTAssertEqual(Theme.fontSize(for: .sidebar), FontArea.sidebar.range.upperBound)
        for _ in 0..<30 { controller.changeFontSize(of: .editor, by: -1) }
        XCTAssertEqual(Theme.fontSize(for: .editor), FontArea.editor.range.lowerBound)
    }

    // MARK: Welcome

    func testWelcomeShowsOnFirstLaunchOnly() {
        let controller = makeController()
        controller.showWelcomeIfNeeded()
        XCTAssertEqual(controller.editor.activeDocument?.special, .welcome)
        layout(controller)
        XCTAssertFalse(views(NSSegmentedControl.self, in: controller).filter { $0.label(forSegment: 0) == "Auto" }.isEmpty,
                       "the Welcome view is on screen")

        controller.closeTab(nil)
        XCTAssertTrue(controller.editor.documents.isEmpty)

        let later = makeController()
        later.showWelcomeIfNeeded()
        XCTAssertTrue(later.editor.documents.isEmpty, "not again on the next launch")
    }

    func testWelcomeStaysAwayWhenSomethingIsOpen() throws {
        let root = try makeFolder(files: ["main.swift": "\n"])
        let controller = makeController(opening: [root])
        controller.showWelcomeIfNeeded()
        XCTAssertTrue(controller.editor.documents.isEmpty)
    }

    func testShowOnLaunchAndHelpMenuOpenWelcome() throws {
        WelcomeController.showsOnLaunch = true
        let root = try makeFolder(files: ["main.swift": "\n"])
        let controller = makeController(opening: [root.appendingPathComponent("main.swift")])
        controller.showWelcomeIfNeeded()
        XCTAssertEqual(controller.editor.activeDocument?.special, .welcome)

        controller.editor.activate(0)
        controller.showWelcome(nil)
        XCTAssertEqual(controller.editor.documents.filter { $0.special == .welcome }.count, 1, "reuses the open tab")
        XCTAssertEqual(controller.editor.activeDocument?.special, .welcome)
    }

    func testSwitchingBetweenSpecialTabsShowsOneViewAtATime() {
        let controller = makeController()
        controller.showWelcome(nil)
        controller.openKeyboardShortcuts(nil)
        layout(controller)
        XCTAssertTrue(views(NSSegmentedControl.self, in: controller).filter { $0.segmentCount == 3 && $0.label(forSegment: 0) == "Auto" }.isEmpty,
                      "the Welcome view left with its tab")
        controller.closeTab(nil)
        layout(controller)
        XCTAssertEqual(controller.editor.activeDocument?.special, .welcome)
        XCTAssertFalse(views(NSSegmentedControl.self, in: controller).filter { $0.label(forSegment: 0) == "Auto" }.isEmpty)
    }

    // MARK: Appearance

    func testAppearanceChoiceAppliesToTheApp() {
        AppAppearance.current = .dark
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        AppAppearance.current = .light
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        AppAppearance.current = .auto
        XCTAssertNil(NSApp.appearance)
    }
}
