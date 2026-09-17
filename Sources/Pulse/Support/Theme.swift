import SwiftUI

/// Design tokens lifted from the handoff's 1g "Handoff notes" artboard:
/// SF Pro Text for prose, SF Mono for numbers/section headers/key hints;
/// 38px rows (46px with a reason line), 10px side padding, 7px row radius,
/// 8px window padding, 13px window corner radius.
enum Metrics {
    static let windowWidth: CGFloat = 400
    static let windowMinHeight: CGFloat = 480
    static let windowMaxHeight: CGFloat = 580
    static let windowRadius: CGFloat = 22
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 40
    static let windowPadding: CGFloat = 16
    static let rowHeight: CGFloat = 48
    static let rowHeightWithReason: CGFloat = 50
    static let rowRadius: CGFloat = 10
    static let rowSidePadding: CGFloat = 8
}

enum Fonts {
    static let body = Font.system(size: 13.5)
    static let bodyStrong = Font.system(size: 13.5, weight: .semibold)
    static let title = Font.system(size: 15, weight: .bold)
    static let query = Font.system(size: 13)
    static let sectionHeader = Font.system(size: 11.5, weight: .semibold)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoTiny = Font.system(size: 10, design: .monospaced)
}

/// Semantic ink/surface tokens matching modern macOS vibrancy and the premium minimalist style.
struct Theme {
    let scheme: ColorScheme

    var background: Color { scheme == .dark ? Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x1b / 255) : Color(red: 0xf6 / 255, green: 0xf6 / 255, blue: 0xf8 / 255) }
    var border: Color { scheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08) }
    var borderSoft: Color { scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.06) }
    var rowSelected: Color { scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.04) }
    var trackBackground: Color { scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.08) }
    var cardBackground: Color { scheme == .dark ? .white.opacity(0.06) : .white.opacity(0.65) }
    var pillBackground: Color { scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.05) }
    var pillBorder: Color { scheme == .dark ? .white.opacity(0.14) : .black.opacity(0.07) }

    var textPrimary: Color { scheme == .dark ? Color(red: 0xf6 / 255, green: 0xf6 / 255, blue: 0xf8 / 255) : Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255) }
    var textSecondary: Color { scheme == .dark ? .white.opacity(0.70) : .black.opacity(0.60) }
    var textMuted: Color { scheme == .dark ? .white.opacity(0.52) : .black.opacity(0.48) }
    var textDim: Color { scheme == .dark ? .white.opacity(0.38) : .black.opacity(0.38) }
    var sectionHeader: Color { scheme == .dark ? .white.opacity(0.50) : .black.opacity(0.50) }
    var hint: Color { scheme == .dark ? .white.opacity(0.32) : .black.opacity(0.34) }
    var placeholder: Color { scheme == .dark ? .white.opacity(0.32) : .black.opacity(0.35) }
    var searchIcon: Color { scheme == .dark ? .white.opacity(0.45) : .black.opacity(0.40) }

    var accent: Color { Color(red: 0.12, green: 0.48, blue: 0.98) }
    var blueAccent: Color { Color(red: 0.12, green: 0.48, blue: 0.98) }

    var quitBorder: Color { scheme == .dark ? .white.opacity(0.15) : .black.opacity(0.08) }
    var quitText: Color { scheme == .dark ? .white.opacity(0.9) : .black.opacity(0.8) }
}
