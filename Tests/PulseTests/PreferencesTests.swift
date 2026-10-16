import AppKit
import SwiftTerm
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

    // MARK: Review fixes

    func testWelcomeOnLaunchStaysBehindFilesPulseWasOpenedWith() throws {
        WelcomeController.showsOnLaunch = true
        let root = try makeFolder(files: ["main.swift": "\n"])
        let controller = makeController(opening: [root.appendingPathComponent("main.swift")])
        controller.showWelcomeIfNeeded(launchedWithFiles: true)
        XCTAssertEqual(controller.editor.activeDocument?.url?.lastPathComponent, "main.swift", "the file asked for stays in front")
        XCTAssertFalse(controller.editor.documents.contains { $0.special == .welcome })
    }

    func testSwitchingSpecialTabsKeepsEachTabsState() throws {
        let controller = makeController()
        controller.openKeyboardShortcuts(nil)
        layout(controller)
        let search = try XCTUnwrap(views(NSSearchField.self, in: controller).first { $0.placeholderString == "Search commands or keys" })
        search.stringValue = "tab"
        controller.showWelcome(nil)
        layout(controller)
        XCTAssertNil(search.window, "only the active special view is on screen")
        controller.openKeyboardShortcuts(nil)
        layout(controller)
        let again = try XCTUnwrap(views(NSSearchField.self, in: controller).first { $0.placeholderString == "Search commands or keys" })
        XCTAssertTrue(again === search, "the same view comes back")
        XCTAssertEqual(again.stringValue, "tab")
    }

    func testWelcomeFollowsSettingsChangedElsewhere() throws {
        let controller = makeController()
        controller.showWelcome(nil)
        layout(controller)
        let appearance = try XCTUnwrap(views(NSSegmentedControl.self, in: controller).first { $0.label(forSegment: 0) == "Auto" })
        let autosave = try XCTUnwrap(views(NSSwitch.self, in: controller).first)
        AppAppearance.current = .dark
        XCTAssertEqual(appearance.selectedSegment, AppAppearance.allCases.firstIndex(of: .dark))
        EditorViewController.autosaveEnabled = false
        XCTAssertEqual(autosave.state, .off)
        AppAppearance.current = .auto
    }

    func testWelcomeShortcutsFollowRebinding() throws {
        KeyBindings.register(MainMenu.build())
        let controller = makeController()
        controller.showWelcome(nil)
        layout(controller)
        XCTAssertTrue(labels(in: frameView(controller)).contains("⌘P"))
        KeyBindings.set(Shortcut(config: "cmd+1"), for: "go.goToFile")
        XCTAssertTrue(labels(in: frameView(controller)).contains("⌘1"), "the Go to file row shows the new shortcut")
        KeyBindings.resetAll()
    }

    func testIsInstalledFindsTheLinkWhereverItWasInstalled() throws {
        let folder = temp.appendingPathComponent("cargo-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("pulse").path,
                                                   withDestinationPath: CommandLineTool.script.path)
        UserDefaults.standard.set(folder.path, forKey: "cliInstallFolder")
        XCTAssertTrue(CommandLineTool.isInstalled)
    }

    func testNeverLinksOverADifferentPulseProgram() throws {
        let free = temp.appendingPathComponent("free", isDirectory: true)
        let other = temp.appendingPathComponent("other", isDirectory: true)
        let oldPulse = temp.appendingPathComponent("old", isDirectory: true)
        for folder in [free, other, oldPulse] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "#!/bin/sh\necho other\n".write(to: other.appendingPathComponent("pulse"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: oldPulse.appendingPathComponent("pulse").path,
                                                   withDestinationPath: "/Applications/Old/Pulse.app/Contents/Resources/pulse")
        XCTAssertTrue(CommandLineTool.canLink(in: free.path))
        XCTAssertFalse(CommandLineTool.canLink(in: other.path), "a different program called pulse")
        XCTAssertTrue(CommandLineTool.canLink(in: oldPulse.path), "a link left by another copy of Pulse")
    }

    func testTerminalColorsFollowAppearance() throws {
        let controller = makeController()
        controller.editor.showTerminal()
        layout(controller)
        let terminal = try XCTUnwrap(views(LocalProcessTerminalView.self, in: controller).first)
        func background() -> CGColor? { terminal.layer?.backgroundColor }
        AppAppearance.current = .dark
        layout(controller)
        let dark = background()
        AppAppearance.current = .light
        layout(controller)
        XCTAssertNotEqual(dark, background(), "the terminal background changes with the appearance")
        AppAppearance.current = .auto
    }
}
