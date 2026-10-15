import AppKit

/// Colors and fonts. Every color is dynamic so light/dark switches need no
/// re-highlighting: temporary attributes resolve the color at draw time.
enum Theme {
    static let defaultFontSize: CGFloat = 13
    static let minFontSize: CGFloat = 9
    static let maxFontSize: CGFloat = 28

    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "editorFontSize")
            return stored > 0 ? CGFloat(stored) : defaultFontSize
        }
        set {
            let clamped = min(max(newValue, minFontSize), maxFontSize)
            UserDefaults.standard.set(Double(clamped), forKey: "editorFontSize")
        }
    }

    static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
