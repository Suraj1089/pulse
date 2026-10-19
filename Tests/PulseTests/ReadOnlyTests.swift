import AppKit
import XCTest
@testable import Pulse

/// Read-only files (Document.isReadOnly): the default file mode, the status
/// bar's switch, and what a locked file refuses.
final class ReadOnlyTests: PulseTestCase {
    private static let text = "let a = 1\nlet b = 2\n"

    private func open() throws -> (MainWindowController, CodeTextView) {
        let root = try makeFolder(files: ["a.swift": ReadOnlyTests.text, "b.swift": "let c = 3\n"])
        let controller = makeController(opening: [root, root.appendingPathComponent("a.swift")])
        return (controller, try XCTUnwrap(controller.editor.textView))
    }

    private func modeButton(_ controller: MainWindowController) throws -> NSButton {
        try XCTUnwrap(views(NSButton.self, in: controller).first { $0.action == #selector(MainWindowController.toggleReadOnly(_:)) })
    }

    private func menuItem(_ action: Selector, in controller: MainWindowController) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        _ = controller.validateMenuItem(item)
        return item
    }

    func testFilesOpenReadOnlyByDefaultAndTheStatusBarUnlocksThem() throws {
        UserDefaults.standard.removeObject(forKey: "openFilesReadOnly")
        let (controller, textView) = try open()
        let document = try XCTUnwrap(controller.editor.activeDocument)
        XCTAssertTrue(document.isReadOnly)
        XCTAssertFalse(textView.isEditable)
        textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.string, ReadOnlyTests.text, "typing changes nothing")
        XCTAssertFalse(document.isDirty)

        let button = try modeButton(controller)
        XCTAssertNil(button.target, "goes up the responder chain to its window, like File › Read Only")
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.title, "Read Only")
        XCTAssertEqual(menuItem(#selector(MainWindowController.toggleReadOnly(_:)), in: controller).state, .on)

        controller.toggleReadOnly(button)
        XCTAssertFalse(document.isReadOnly)
        XCTAssertTrue(textView.isEditable)
        XCTAssertEqual(button.title, "Editing")
        XCTAssertEqual(menuItem(#selector(MainWindowController.toggleReadOnly(_:)), in: controller).state, .off)
        textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.string, "x" + ReadOnlyTests.text)
        XCTAssertTrue(document.isDirty)
    }

    func testTheWelcomeSettingPicksTheModeOfFilesOpenedAfterIt() throws {
        let (controller, textView) = try open()
        controller.showWelcome(nil)
        layout(controller)
        let setting = try XCTUnwrap(views(NSSegmentedControl.self, in: controller).first { $0.label(forSegment: 0) == "Read only" })
        XCTAssertEqual(setting.selectedSegment, 1, "Edit, as the tests set it")

        setting.selectedSegment = 0
        _ = setting.sendAction(setting.action, to: setting.target)
        XCTAssertTrue(EditorViewController.opensFilesReadOnly)
        let root = try XCTUnwrap(controller.root)
        controller.editor.open(root.appendingPathComponent("b.swift"))
        XCTAssertFalse(textView.isEditable, "opened after: read only")
        controller.editor.open(root.appendingPathComponent("a.swift"))
        XCTAssertTrue(textView.isEditable, "opened before: keeps its mode")
    }

    func testNewFilesAndUnsavedTextStayEditable() throws {
        UserDefaults.standard.removeObject(forKey: "openFilesReadOnly")
        let (controller, textView) = try open()
        controller.newFile(nil)
        XCTAssertNil(controller.editor.activeDocument?.url)
        XCTAssertTrue(textView.isEditable, "a new file is for typing")
        XCTAssertEqual(try modeButton(controller).title, "Editing")

        let restored = makeController()
        let path = try XCTUnwrap(controller.editor.documents.first?.url?.path)
        restored.restore(SessionState(root: nil, entries: [SessionState.Entry(path: path, unsavedText: "draft\n", selection: 0)],
                                      active: 0, terminalOpen: false))
        XCTAssertFalse(restored.editor.activeDocument?.isReadOnly ?? true, "unsaved text comes back editable")
    }

    func testALockedFileRefusesEditsUndoAndCommandsInEveryPane() throws {
        let (controller, textView) = try open()
        textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.undoManager?.canUndo, true)
        controller.splitEditorRight(nil)
        layout(controller)
        let panes = controller.editor.panes
        XCTAssertEqual(panes.count, 2)

        controller.toggleReadOnly(nil)
        XCTAssertFalse(panes[0].textView.isEditable, "the file is locked in both panes")
        XCTAssertFalse(panes[1].textView.isEditable)
        XCTAssertNil(controller.editor.textView.undoManager, "no Undo while locked")
        XCTAssertFalse(controller.validateMenuItem(menuItem(#selector(MainWindowController.toggleComment(_:)), in: controller)))
        XCTAssertFalse(controller.validateMenuItem(menuItem(#selector(MainWindowController.indentLines(_:)), in: controller)))
        controller.toggleComment(nil)
        XCTAssertEqual(controller.editor.textView.string, "x" + ReadOnlyTests.text, "commands change nothing")

        let window = try XCTUnwrap(controller.window)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "y",
                                                 charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16))
        controller.editor.textView.keyDown(with: key)
        XCTAssertTrue(labels(in: frameView(controller)).contains { $0.hasPrefix("This file is read-only") }, "the status bar says why")

        controller.toggleReadOnly(nil)
        XCTAssertTrue(panes[0].textView.isEditable)
        XCTAssertTrue(panes[1].textView.isEditable)
        XCTAssertEqual(controller.editor.textView.undoManager?.canUndo, true, "its history comes back")
    }
}
