import AppKit

/// A key equivalent: the unshifted key plus modifiers, as NSMenuItem stores it.
struct Shortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    private static let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection(Shortcut.relevant)
    }

    init?(item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else { return nil }
        self.init(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
    }

    /// A shortcut from a key press, or nil if it would hijack plain typing
    /// (see `isSafe`).
    init?(event: NSEvent) {
        // Function and arrow keys come through charactersIgnoringModifiers;
        // characters(byApplyingModifiers:) reports a placeholder for them.
        // For everything else, the latter gives the unshifted key ("]" for ⇧⌘]).
        let ignoring = event.charactersIgnoringModifiers ?? ""
        let isSpecial = ignoring.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } ?? false
        let base = isSpecial ? ignoring : (event.characters(byApplyingModifiers: []) ?? ignoring)
        guard let scalar = base.unicodeScalars.first else { return nil }
        self.init(key: String(scalar), modifiers: event.modifierFlags)
        guard isSafe else { return nil }
    }

    /// Needs ⌘ or ⌃, unless it is a function key (F1–F35), so a binding can
    /// never swallow ordinary typing.
    var isSafe: Bool {
        let isFunctionKey = key.unicodeScalars.first.map { (0xF704...0xF726).contains($0.value) } ?? false
        return isFunctionKey || modifiers.contains(.command) || modifiers.contains(.control)
    }

    /// "⇧⌘P", in the order macOS menus use.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Shortcut.glyph(for: key)
    }

    private static func glyph(for key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch scalar.value {
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        case 0x20: return "Space"
        case 0x08, 0x7F: return "⌫"
        case 0x1B: return "⎋"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF728: return "⌦"
        case 0xF704...0xF726: return "F\(scalar.value - 0xF704 + 1)"
        default: return key.uppercased()
        }
    }

    /// Stored as "modifiers:key" so any key, including ":", round-trips.
    var stored: String { "\(modifiers.rawValue):\(key)" }

    init?(stored: String) {
        guard let colon = stored.firstIndex(of: ":"), let raw = UInt(stored[..<colon]) else { return nil }
        let key = String(stored[stored.index(after: colon)...])
        guard !key.isEmpty else { return nil }
        self.init(key: key, modifiers: NSEvent.ModifierFlags(rawValue: raw))
    }
}

/// One rebindable command: a menu item and the shortcut it shipped with.
final class KeyCommand {
    let id: String
    let title: String          // "View › Show Files"
    let defaultShortcut: Shortcut?
    let item: NSMenuItem

    init(id: String, title: String, defaultShortcut: Shortcut?, item: NSMenuItem) {
        self.id = id
        self.title = title
        self.defaultShortcut = defaultShortcut
        self.item = item
    }

    var shortcut: Shortcut? { Shortcut(item: item) }
    var isCustomized: Bool { shortcut != defaultShortcut }
}

/// Every menu command and its shortcut. The menu items are the source of
/// truth; this records their defaults and applies the user's overrides,
/// which are stored in UserDefaults as [command id: "modifiers:key" or ""].
enum KeyBindings {
    static let defaultsKey = "keyBindings"
    private(set) static var commands: [KeyCommand] = []

    /// Records defaults for every actionable item in `menu` and applies the
    /// saved overrides. Called once when the menu bar is built.
    static func register(_ menu: NSMenu) {
        commands = []
        collect(menu, path: [])
        let overrides = storedOverrides
        for command in commands {
            guard let value = overrides[command.id] else { continue }
            if value.isEmpty {
                apply(nil, to: command.item)
            } else if let shortcut = Shortcut(stored: value), shortcut.isSafe {
                apply(shortcut, to: command.item)
            }
        }
    }

    private static func collect(_ menu: NSMenu, path: [String]) {
        for item in menu.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                if submenu === NSApp.servicesMenu { continue }
                collect(submenu, path: path + [item.title])
            } else if let action = item.action, action != #selector(NSWindow.toggleFullScreen(_:)) {
                // AppKit manages the Full Screen item's shortcut itself (fn-F).
                let id = item.tag == 0 ? NSStringFromSelector(action) : "\(NSStringFromSelector(action))#\(item.tag)"
                let title = (path + [item.title]).joined(separator: " › ")
                commands.append(KeyCommand(id: id, title: title, defaultShortcut: Shortcut(item: item), item: item))
            }
        }
    }

    static func command(id: String) -> KeyCommand? {
        commands.first { $0.id == id }
    }

    /// The command currently using `shortcut`, other than `excluding`.
    static func command(using shortcut: Shortcut, excluding id: String? = nil) -> KeyCommand? {
        commands.first { $0.id != id && $0.shortcut == shortcut }
    }

    /// Binds `shortcut` (nil removes it) and returns the command that lost it, if any.
    @discardableResult
    static func set(_ shortcut: Shortcut?, for id: String) -> KeyCommand? {
        guard let command = command(id: id) else { return nil }
        var displaced: KeyCommand?
        if let shortcut, let other = self.command(using: shortcut, excluding: id) {
            apply(nil, to: other.item)
            displaced = other
        }
        apply(shortcut, to: command.item)
        save()
        return displaced
    }

    /// Restores the default and returns the command that lost it, if any.
    @discardableResult
    static func reset(_ id: String) -> KeyCommand? {
        guard let command = command(id: id) else { return nil }
        return set(command.defaultShortcut, for: id)
    }

    static func resetAll() {
        commands.forEach { apply($0.defaultShortcut, to: $0.item) }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// The current shortcut for a menu action, for labels such as the palette's.
    static func display(for action: Selector) -> String {
        commands.first { $0.item.action == action && $0.item.tag == 0 }?.shortcut?.display ?? ""
    }

    private static func apply(_ shortcut: Shortcut?, to item: NSMenuItem) {
        item.keyEquivalent = shortcut?.key ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }

    private static var storedOverrides: [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    /// Stores only what differs from the defaults.
    private static func save() {
        var overrides: [String: String] = [:]
        for command in commands where command.isCustomized {
            overrides[command.id] = command.shortcut?.stored ?? ""
        }
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(overrides, forKey: defaultsKey)
        }
    }
}
