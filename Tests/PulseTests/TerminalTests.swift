import AppKit
import SwiftTerm
import XCTest
@testable import Pulse

/// Multiple terminals: tabs (+), side-by-side panes (split), kill, exit.
/// These start real shells, in temp folders, and end them in tearDown.
final class TerminalTests: PulseTestCase {
    private func terminalViews(_ controller: MainWindowController) -> [TerminalView] {
        views(TerminalView.self, in: controller).filter { $0.window != nil }
    }

    /// Runs `command` in the given pane and waits for its output file.
    private func output(of command: String, in view: TerminalView) throws -> String {
        let file = temp.appendingPathComponent("out-\(UUID().uuidString)")
        view.send(txt: "\(command) > '\(file.path)'\r")
        wait(timeout: 10, "shell output") {
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").hasSuffix("\n")
        }
        return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testFirstTerminalOpensInTheOpenFolder() throws {
        let root = try makeFolder(files: ["main.swift": "\n"])
        let controller = makeController(opening: [root])
        controller.editor.showTerminal()
        layout(controller)
        let panel = controller.editor.terminalPanel
        XCTAssertEqual(panel.terminalCount, 1)
        XCTAssertEqual(panel.activeDirectories, [root])
        let view = try XCTUnwrap(terminalViews(controller).first)
        XCTAssertEqual(try output(of: "pwd -P", in: view), root.path, "the shell really runs in the open folder")
    }

    func testPlusAddsATabAndSplitAddsAPaneBothInTheFolder() throws {
        let root = try makeFolder(files: ["main.swift": "\n"])
        let controller = makeController(opening: [root])
        let panel = controller.editor.terminalPanel

        controller.newTerminal(nil)   // none running yet: shows the panel with one
        XCTAssertEqual(panel.tabCount, 1)
        controller.newTerminal(nil)
        layout(controller)
        XCTAssertEqual(panel.tabCount, 2)
        XCTAssertEqual(panel.activePaneCount, 1, "a new tab starts with one pane")

        controller.splitTerminal(nil)
        layout(controller)
        XCTAssertEqual(panel.tabCount, 2)
        XCTAssertEqual(panel.activePaneCount, 2)
        XCTAssertEqual(panel.activeDirectories, [root, root])
        XCTAssertEqual(terminalViews(controller).count, 2, "only the tab on screen has its panes in the window")
        let panes = terminalViews(controller)
        XCTAssertLessThan(panes[0].frame.maxX, panes[1].frame.minX + 1, "split panes sit side by side")
        XCTAssertEqual(panes[0].frame.width, panes[1].frame.width, accuracy: 2, "and share the width equally")
        XCTAssertEqual(panel.terminalCount, 3)
    }

    func testKillClosesTheFocusedPaneAndTheLastOneHidesThePanel() throws {
        let controller = makeController()
        controller.editor.showTerminal()
        controller.splitTerminal(nil)
        layout(controller)
        let panel = controller.editor.terminalPanel
        XCTAssertEqual(panel.terminalCount, 2)

        controller.killTerminal(nil)
        XCTAssertEqual(panel.terminalCount, 1)
        XCTAssertTrue(controller.editor.isTerminalVisible)
        controller.killTerminal(nil)
        XCTAssertEqual(panel.terminalCount, 0)
        XCTAssertFalse(controller.editor.isTerminalVisible, "no terminals left: the panel hides")
    }

    func testExitInAShellRemovesOnlyThatPane() throws {
        let controller = makeController()
        controller.editor.showTerminal()
        controller.splitTerminal(nil)
        layout(controller)
        let panel = controller.editor.terminalPanel
        let first = try XCTUnwrap(terminalViews(controller).first)
        _ = try output(of: "echo ready", in: first)   // the shell is up and reading input
        first.send(txt: "exit\r")
        wait(timeout: 10, "the pane to close") { panel.terminalCount == 1 }
        XCTAssertTrue(controller.editor.isTerminalVisible)
        XCTAssertEqual(terminalViews(controller).count, 1)
    }

    /// The session reads the shell's output itself: a burst arrives in full and in order.
    func testABurstOfOutputReachesTheScreenInFull() throws {
        let controller = makeController()
        controller.editor.showTerminal()
        layout(controller)
        let view = try XCTUnwrap(terminalViews(controller).first)
        _ = try output(of: "echo ready", in: view)
        view.send(txt: "seq 1 50000\r")
        wait(timeout: 30, "the last line on screen") { self.screen(of: view).contains("50000") }
        let lines = screen(of: view)
        let last = try XCTUnwrap(lines.firstIndex(of: "50000"))
        XCTAssertEqual(Array(lines[..<last].suffix(3)), ["49997", "49998", "49999"])
    }

    func testShellsKnowTheirTerminalSize() throws {
        let controller = makeController()
        controller.editor.showTerminal()
        controller.splitTerminal(nil)   // the first pane shrinks after its shell started
        layout(controller)
        for view in terminalViews(controller) {
            let terminal = view.getTerminal()
            XCTAssertEqual(try output(of: "stty size", in: view), "\(terminal.rows) \(terminal.cols)")
        }
    }

    /// The non-empty lines on a terminal's screen.
    private func screen(of view: TerminalView) -> [String] {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.filter { !$0.isEmpty }
    }

    func testFontSizeReachesEveryPane() {
        let controller = makeController()
        controller.editor.showTerminal()
        controller.splitTerminal(nil)
        controller.changeFontSize(of: .terminal, by: 3)
        let sizes = Set(terminalViews(controller).map { $0.font.pointSize })
        XCTAssertEqual(sizes, [Theme.fontSize(for: .terminal)])
    }
}
