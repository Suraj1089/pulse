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
        menu.addItem(item("Open…", #selector(MainWindowController.openDocument(_:)), "o"))
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
        menu.addItem(item("Show Terminal", #selector(MainWindowController.toggleTerminal(_:)), "`", [.control]))
        menu.addItem(item("Kill Terminal", #selector(MainWindowController.killTerminal(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Word Wrap", #selector(MainWindowController.toggleWordWrap(_:)), "w", [.command, .option]))
        menu.addItem(item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "="))
        menu.addItem(item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(MainWindowController.resetZoom(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
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
