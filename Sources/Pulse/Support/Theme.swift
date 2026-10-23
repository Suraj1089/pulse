import AppKit

/// Colors and fonts. Every color is dynamic so light/dark switches need no
/// re-highlighting: temporary attributes resolve the color at draw time.
enum Theme {
    /// The editor's size; the sidebar and terminal have their own (FontArea).
    static var fontSize: CGFloat {
        get { fontSize(for: .editor) }
        set { setFontSize(newValue, for: .editor) }
    }

    static func fontSize(for area: FontArea) -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: area.defaultsKey)
        guard stored > 0 else { return area.defaultSize }
        return min(max(CGFloat(stored), area.range.lowerBound), area.range.upperBound)
    }

    /// nil resets the area to its default.
    static func setFontSize(_ size: CGFloat?, for area: FontArea) {
        if let size {
            let clamped = min(max(size, area.range.lowerBound), area.range.upperBound)
            UserDefaults.standard.set(Double(clamped), forKey: area.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: area.defaultsKey)
        }
    }

    static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static var terminalFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize(for: .terminal), weight: .regular)
    }

    /// Sidebar rows (file tree, search results, changes); `offset` keeps the
    /// smaller secondary text in proportion.
    static func sidebarFont(offset: CGFloat = 0, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: fontSize(for: .sidebar) + offset, weight: weight)
    }

    static func sidebarMonospacedFont(offset: CGFloat = 0) -> NSFont {
        .monospacedSystemFont(ofSize: fontSize(for: .sidebar) + offset, weight: .regular)
    }

    /// 22 pt for the default 13 pt text.
    static func sidebarRowHeight(offset: CGFloat = 0) -> CGFloat {
        (fontSize(for: .sidebar) + offset + 9).rounded()
    }

    static var gutterFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(fontSize - 2, 9), weight: .regular)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light)
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static let editorBackground = dynamic(light: 0xFFFFFF, dark: 0x1E1E20)
    static let chromeBackground = dynamic(light: 0xF5F5F7, dark: 0x252528)
    static let currentLine = dynamic(light: 0xF1F4FA, dark: 0x26292E)
    static let text = dynamic(light: 0x1D1D1F, dark: 0xE6E6E8)

    static let keyword = dynamic(light: 0x9C2F96, dark: 0xEE72B3)
    static let string = dynamic(light: 0xB3261E, dark: 0xF0907F)
    static let comment = dynamic(light: 0x5D6977, dark: 0x8E98A2)
    static let type = dynamic(light: 0x1B5C8A, dark: 0x74CDEE)
    static let number = dynamic(light: 0x3B2CC0, dark: 0xD9C674)
    static let attribute = dynamic(light: 0x7A4A1E, dark: 0xEFA25E)

    static let gitModified = dynamic(light: 0x895503, dark: 0xE2C08D)
    static let gitAdded = dynamic(light: 0x587C0C, dark: 0x81B88B)
    static let gitDeleted = dynamic(light: 0xAD0707, dark: 0xC74E39)

    // Diff rows: tints of the git colors, light enough to keep syntax colors readable.
    static let diffAdded = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? hex(0x81B88B).withAlphaComponent(0.16) : hex(0x2DA44E).withAlphaComponent(0.14) }
    static let diffRemoved = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? hex(0xF85149).withAlphaComponent(0.16) : hex(0xCF222E).withAlphaComponent(0.11) }
    static let diffHunk = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? hex(0x388BFD).withAlphaComponent(0.12) : hex(0x0969DA).withAlphaComponent(0.08) }
    // The edited part of a changed line, over its row's tint.
    static let diffAddedEdit = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? hex(0x81B88B).withAlphaComponent(0.28) : hex(0x2DA44E).withAlphaComponent(0.26) }
    static let diffRemovedEdit = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? hex(0xF85149).withAlphaComponent(0.30) : hex(0xCF222E).withAlphaComponent(0.20) }

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .type: return type
        case .number: return number
        case .attribute: return attribute
        }
    }
}

/// Parts of the window with their own font size (View › Font Size).
enum FontArea: String, CaseIterable {
    case editor, sidebar, terminal

    var title: String { rawValue.capitalized }

    fileprivate var defaultsKey: String { rawValue + "FontSize" }

    var range: ClosedRange<CGFloat> { self == .sidebar ? 10...20 : 9...28 }

    var defaultSize: CGFloat {
        switch self {
        case .editor, .sidebar: return 13
        // Until set on its own, the terminal stays a point under the editor.
        case .terminal: return max(Theme.fontSize(for: .editor) - 1, 10)
        }
    }
}

/// Light, dark, or following macOS (Auto). Applied to the whole app; every
/// color is dynamic, so open views update without a relaunch.
enum AppAppearance: String, CaseIterable {
    case auto, light, dark

    var title: String { rawValue.capitalized }

    static var current: AppAppearance {
        get { UserDefaults.standard.string(forKey: "appearance").flatMap(AppAppearance.init) ?? .auto }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appearance")
            newValue.apply()
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }

    func apply() {
        switch self {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
