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
        guard let scalar = key.unicodeScalars.first else { return text }
        switch scalar.value {
        case 0x0D, 0x03: return text + "↩"
        case 0x09: return text + "⇥"
        case 0x20: return text + "Space"
        case 0x08, 0x7F: return text + "⌫"
        case 0x1B: return text + "⎋"
        case 0xF700: return text + "↑"
        case 0xF701: return text + "↓"
        case 0xF702: return text + "←"
        case 0xF703: return text + "→"
        case 0xF728: return text + "⌦"
        case 0xF704...0xF726: return text + "F\(scalar.value - 0xF704 + 1)"
        default: return text + key.uppercased()
        }
    }

    // MARK: keybindings.json form: "ctrl+alt+shift+cmd+p", "f5", "cmd+["

    private static let namedKeys: [UInt32: String] = [
        0x0D: "enter", 0x09: "tab", 0x20: "space", 0x7F: "backspace", 0x08: "backspace", 0x1B: "escape",
        0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right", 0xF728: "delete",
        0xF729: "home", 0xF72B: "end", 0xF72C: "pageup", 0xF72D: "pagedown",
    ]

    var config: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        let value = key.unicodeScalars.first?.value ?? 0
        if let name = Shortcut.namedKeys[value] {
            parts.append(name)
        } else if (0xF704...0xF726).contains(value) {
            parts.append("f\(value - 0xF704 + 1)")
        } else {
            parts.append(key)
        }
        return parts.joined(separator: "+")
    }

    init?(config: String) {
        var parts = config.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" is ⌘ and the plus key.
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "meta": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        let keyName = last.trimmingCharacters(in: .whitespaces)
        let key: String
        if let named = Shortcut.namedKeys.first(where: { $0.value == keyName && $0.key != 0x08 }) {
            key = String(UnicodeScalar(named.key)!)
        } else if keyName.hasPrefix("f"), let number = UInt32(keyName.dropFirst()), (1...35).contains(number) {
            key = String(UnicodeScalar(0xF704 + number - 1)!)
        } else if keyName.count == 1 {
            key = keyName
        } else {
            return nil
        }
        self.init(key: key, modifiers: modifiers)
    }
}

/// One rebindable command: a menu item and the shortcut it shipped with.
final class KeyCommand {
    let id: String             // "view.showFiles"
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

extension Notification.Name {
    /// Posted after shortcuts change, from the visual editor or keybindings.json.
    static let keyBindingsDidChange = Notification.Name("PulseKeyBindingsDidChange")
}

/// Every menu command and its shortcut. The menu items are the source of
/// truth at run time; this records their defaults and applies the user's
/// overrides from keybindings.json, which the visual editor also writes.
enum KeyBindings {
    private(set) static var commands: [KeyCommand] = []

    /// Settable so tests never touch the real file.
    static var fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pulse", isDirectory: true).appendingPathComponent("keybindings.json")
    }()

    /// Records defaults for every actionable item in `menu` and applies
    /// keybindings.json. Called once when the menu bar is built.
    static func register(_ menu: NSMenu) {
        commands = []
        collect(menu, path: [])
        // Shortcuts briefly lived in UserDefaults before keybindings.json.
        UserDefaults.standard.removeObject(forKey: "keyBindings")
        _ = reloadFromFile()
    }

    private static func collect(_ menu: NSMenu, path: [String]) {
        for item in menu.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                if submenu === NSApp.servicesMenu { continue }
                collect(submenu, path: path + [item.title])
            } else if item.action != nil, item.action != #selector(NSWindow.toggleFullScreen(_:)) {
                // AppKit manages the Full Screen item's shortcut itself (fn-F).
                let titles = path + [item.title]
                commands.append(KeyCommand(id: identifier(for: titles), title: titles.joined(separator: " › "),
                                           defaultShortcut: Shortcut(item: item), item: item))
            }
        }
    }

    /// "Edit › Find › Find Next" → "edit.find.findNext".
    private static func identifier(for titles: [String]) -> String {
        titles.map { title -> String in
            let words = title.replacingOccurrences(of: "…", with: "")
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            return words.enumerated().map { index, word in
                index == 0 ? word.lowercased() : word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined()
        }.joined(separator: ".")
    }

    static func command(id: String) -> KeyCommand? {
        commands.first { $0.id == id }
    }

    /// The command currently using `shortcut`, other than `excluding`.
    static func command(using shortcut: Shortcut, excluding id: String? = nil) -> KeyCommand? {
        commands.first { $0.id != id && $0.shortcut == shortcut }
    }

    /// Binds `shortcut` (nil removes it), saves keybindings.json, and returns
    /// the command that lost the shortcut, if any.
    @discardableResult
    static func set(_ shortcut: Shortcut?, for id: String) -> KeyCommand? {
        let displaced = bind(shortcut, to: id)
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
        save()
    }

    /// The current shortcut for a menu action, for labels such as the palette's.
    static func display(for action: Selector) -> String {
        commands.first { $0.item.action == action && $0.item.tag == 0 }?.shortcut?.display ?? ""
    }

    @discardableResult
    private static func bind(_ shortcut: Shortcut?, to id: String) -> KeyCommand? {
        guard let command = command(id: id) else { return nil }
        var displaced: KeyCommand?
        if let shortcut, let other = self.command(using: shortcut, excluding: id) {
            apply(nil, to: other.item)
            displaced = other
        }
        apply(shortcut, to: command.item)
        return displaced
    }

    private static func apply(_ shortcut: Shortcut?, to item: NSMenuItem) {
        item.keyEquivalent = shortcut?.key ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }

    // MARK: keybindings.json

    /// Applies keybindings.json on top of the defaults. Returns a problem to
    /// show, or nil. If the file cannot be parsed at all, the current
    /// shortcuts are kept.
    static func reloadFromFile() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else {
            commands.forEach { apply($0.defaultShortcut, to: $0.item) }
            NotificationCenter.default.post(name: .keyBindingsDidChange, object: nil)
            return nil
        }
        let entries: [[String: Any]]
        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
            guard let list = parsed as? [[String: Any]] else { return "expected a list of { \"key\", \"command\" } entries" }
            entries = list
        } catch {
            return "could not be read (\((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "invalid JSON")); kept the previous shortcuts"
        }
        commands.forEach { apply($0.defaultShortcut, to: $0.item) }
        var problems: [String] = []
        for entry in entries {
            guard let id = entry["command"] as? String, let keyText = entry["key"] as? String else {
                problems.append("an entry is missing \"key\" or \"command\"")
                continue
            }
            guard command(id: id) != nil else {
                problems.append("unknown command \"\(id)\"")
                continue
            }
            if keyText.isEmpty {
                bind(nil, to: id)
            } else if let shortcut = Shortcut(config: keyText) {
                if shortcut.isSafe { bind(shortcut, to: id) } else { problems.append("\"\(keyText)\" needs cmd or ctrl") }
            } else {
                problems.append("\"\(keyText)\" is not a key")
            }
        }
        NotificationCenter.default.post(name: .keyBindingsDidChange, object: nil)
        guard let first = problems.first else { return nil }
        return problems.count == 1 ? first : "\(first) (and \(problems.count - 1) more)"
    }

    /// Writes the overrides (only what differs from the defaults), with
    /// every command and its default listed for reference.
    private static func save() {
        let overrides = commands.filter(\.isCustomized)
        var lines = [
            "// Pulse keyboard shortcuts. Entries here override the defaults; saving applies them.",
            "// Edit by hand, or use Pulse › Keyboard Shortcuts for the visual editor (which rewrites this file).",
            "// \"key\": modifiers ctrl, alt, shift, cmd joined with \"+\", e.g. \"cmd+shift+p\", \"ctrl+`\", \"f5\".",
            "// \"key\": \"\" removes a command's shortcut.",
            "[",
        ]
        lines += overrides.enumerated().map { index, command in
            let comma = index == overrides.count - 1 ? "" : ","
            return "  { \"key\": \"\(escape(command.shortcut?.config ?? ""))\", \"command\": \"\(command.id)\" }\(comma)"
        }
        lines += ["]", "", "// Commands and their default keys:"]
        let width = commands.map(\.id.count).max() ?? 0
        lines += commands.map { command in
            let padded = command.id.padding(toLength: width, withPad: " ", startingAt: 0)
            return "//   \(padded)  \(command.defaultShortcut?.config ?? "(none)")"
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .keyBindingsDidChange, object: nil)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Creates keybindings.json (with the reference list) if it does not exist yet.
    static func ensureFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { save() }
    }
}
