import AppKit

/// The menu bar, built in code. Custom commands are nil-targeted so they
/// travel the responder chain to `MainWindowController`.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        KeyBindings.register(main)
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Pulse")
        menu.addItem(item("About Pulse", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(item("Check for Updates…", #selector(MainWindowController.checkForUpdates(_:))))
        menu.addItem(item("Install 'pulse' Command", #selector(MainWindowController.installCommandLineTool(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Keyboard Shortcuts", #selector(MainWindowController.openKeyboardShortcuts(_:)), "k", [.command, .option]))
        menu.addItem(item("Keyboard Shortcuts (JSON)", #selector(MainWindowController.openKeyboardShortcutsJSON(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide Pulse", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Pulse", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New File", #selector(MainWindowController.newFile(_:)), "n"))
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n", [.command, .shift]))
        menu.addItem(item("Open…", #selector(MainWindowController.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = RecentMenu.shared
        menu.addItem(submenu(recent))
        menu.addItem(.separator())
        menu.addItem(item("Save", #selector(MainWindowController.saveDocument(_:)), "s"))
        menu.addItem(item("Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        menu.addItem(item("Save All", #selector(MainWindowController.saveAllDocuments(_:)), "s", [.command, .option]))
        menu.addItem(item("Autosave", #selector(MainWindowController.toggleAutosave(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Reveal in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .option]))
        menu.addItem(item("Copy Path", #selector(MainWindowController.copyFilePath(_:)), "c", [.command, .option, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        let finder = #selector(NSTextView.performTextFinderAction(_:))
        find.addItem(item("Find…", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        find.addItem(item("Find and Replace…", finder, "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue))
        find.addItem(item("Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue))
        find.addItem(item("Find Previous", finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue))
        find.addItem(item("Use Selection for Find", finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue))
        find.addItem(.separator())
        find.addItem(item("Find in Project…", #selector(MainWindowController.findInProject(_:)), "f", [.command, .shift]))
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        menu.addItem(findItem)

        menu.addItem(.separator())
        menu.addItem(item("Toggle Comment", #selector(MainWindowController.toggleComment(_:)), "/"))
        menu.addItem(item("Indent", #selector(MainWindowController.indentLines(_:)), "]"))
        menu.addItem(item("Outdent", #selector(MainWindowController.outdentLines(_:)), "["))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Command Palette…", #selector(MainWindowController.showCommandPalette(_:)), "p", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Show Files", #selector(MainWindowController.showFiles(_:)), "e", [.command, .shift]))
        menu.addItem(item("Show Source Control", #selector(MainWindowController.showSourceControl(_:)), "g", [.control, .shift]))
        menu.addItem(item("Toggle Sidebar", #selector(MainWindowController.toggleSidebarVisibility(_:)), "s", [.command, .control]))
        menu.addItem(.separator())
        // VS Code's ⌘\ splits the editor; here it splits the terminal, as before.
        menu.addItem(item("Split Editor Right", #selector(MainWindowController.splitEditorRight(_:)), "\\", [.command, .option]))
        menu.addItem(item("Split Editor Down", #selector(MainWindowController.splitEditorDown(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Terminal", #selector(MainWindowController.toggleTerminal(_:)), "`", [.control]))
        // ⌃⇧` like VS Code. Shifted symbols are matched by the character they
        // type ("~"), so that's the key equivalent; the menu shows it as ⌃~.
        menu.addItem(item("New Terminal", #selector(MainWindowController.newTerminal(_:)), "~", [.control]))
        menu.addItem(item("Split Terminal", #selector(MainWindowController.splitTerminal(_:)), "\\"))
        menu.addItem(item("Kill Terminal", #selector(MainWindowController.killTerminal(_:))))
        menu.addItem(.separator())
        // VS Code's ⌥⌘K is Keyboard Shortcuts here.
        menu.addItem(item("Send Selection to Claude Code", #selector(MainWindowController.sendSelectionToClaude(_:)), "k", [.command, .shift]))
        menu.addItem(item("Share Selection with Claude Code", #selector(MainWindowController.toggleClaudeIntegration(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Word Wrap", #selector(MainWindowController.toggleWordWrap(_:)), "w", [.command, .option]))
        menu.addItem(item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "="))
        menu.addItem(item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(MainWindowController.resetZoom(_:)), "0"))
        menu.addItem(submenu(fontSizeMenu()))
        menu.addItem(submenu(appearanceMenu()))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    /// ⌘+ / ⌘− change whichever area has focus; these name the area.
    private static func fontSizeMenu() -> NSMenu {
        let menu = NSMenu(title: "Font Size")
        let groups: [(String, Selector, Selector, Selector)] = [
            ("Editor", #selector(MainWindowController.editorFontBigger(_:)),
             #selector(MainWindowController.editorFontSmaller(_:)), #selector(MainWindowController.editorFontReset(_:))),
            ("Sidebar", #selector(MainWindowController.sidebarFontBigger(_:)),
             #selector(MainWindowController.sidebarFontSmaller(_:)), #selector(MainWindowController.sidebarFontReset(_:))),
            ("Terminal", #selector(MainWindowController.terminalFontBigger(_:)),
             #selector(MainWindowController.terminalFontSmaller(_:)), #selector(MainWindowController.terminalFontReset(_:))),
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(item("Bigger \(group.0) Font", group.1))
            menu.addItem(item("Smaller \(group.0) Font", group.2))
            menu.addItem(item("Reset \(group.0) Font", group.3))
        }
        return menu
    }

    private static func appearanceMenu() -> NSMenu {
        let menu = NSMenu(title: "Appearance")
        menu.addItem(item("Auto", #selector(MainWindowController.useAutoAppearance(_:))))
        menu.addItem(item("Light", #selector(MainWindowController.useLightAppearance(_:))))
        menu.addItem(item("Dark", #selector(MainWindowController.useDarkAppearance(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Welcome to Pulse", #selector(MainWindowController.showWelcome(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Report a Bug…", #selector(MainWindowController.reportBug(_:))))
        menu.addItem(item("Request a Feature…", #selector(MainWindowController.requestFeature(_:))))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Go to File…", #selector(MainWindowController.showGoToFile(_:)), "p"))
        menu.addItem(item("Go to Line…", #selector(MainWindowController.showGoToLine(_:)), "l"))
        menu.addItem(.separator())
        menu.addItem(item("Next Tab", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift]))
        menu.addItem(item("Previous Tab", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}

/// Fills File › Open Recent from `RecentFolders` each time it opens; the
/// submenu is empty until then, so nothing is kept between uses.
final class RecentMenu: NSObject, NSMenuDelegate {
    static let shared = RecentMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let folders = RecentFolders.all
        for url in folders {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(AppDelegate.openRecentFolder(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if !folders.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Recently Opened", action: folders.isEmpty ? nil : #selector(AppDelegate.clearRecentFolders(_:)), keyEquivalent: "")
        menu.addItem(clear)
    }
}
