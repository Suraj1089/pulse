import SwiftUI

/// Design tokens lifted from the handoff's 1g "Handoff notes" artboard:
/// SF Pro Text for prose, SF Mono for numbers/section headers/key hints;
/// 38px rows (46px with a reason line), 10px side padding, 7px row radius,
/// 8px window padding, 13px window corner radius.
enum Metrics {
    static let windowWidth: CGFloat = 560
    static let windowMinHeight: CGFloat = 400
    static let windowMaxHeight: CGFloat = 480
    static let windowRadius: CGFloat = 13
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 32
    static let windowPadding: CGFloat = 8
    static let rowHeight: CGFloat = 38
    static let rowHeightWithReason: CGFloat = 46
    static let rowRadius: CGFloat = 7
    static let rowSidePadding: CGFloat = 10
}

enum Fonts {
    static let body = Font.system(size: 13.5)
    static let bodyStrong = Font.system(size: 13.5, weight: .semibold)
    static let query = Font.system(size: 15.5)
    static let sectionHeader = Font.system(size: 10.5, design: .monospaced)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoTiny = Font.system(size: 10, design: .monospaced)
}

/// Semantic ink/surface tokens, derived per color-scheme from the values used
/// across the dark (#1b1b1e on #e8e8ea) and light (#fbfbfa on #1a1a1c) artboards.
struct Theme {
    let scheme: ColorScheme

    var background: Color { scheme == .dark ? Color(red: 0x1b / 255, green: 0x1b / 255, blue: 0x1e / 255) : Color(red: 0xfb / 255, green: 0xfb / 255, blue: 0xfa / 255) }
    var border: Color { scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.1) }
    var borderSoft: Color { scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.08) }
    var rowSelected: Color { scheme == .dark ? .white.opacity(0.075) : .black.opacity(0.05) }
    var trackBackground: Color { scheme == .dark ? .white.opacity(0.08) : .black.opacity(0.08) }

    var textPrimary: Color { scheme == .dark ? Color(red: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf4 / 255) : Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1c / 255) }
    var textSecondary: Color { scheme == .dark ? .white.opacity(0.82) : .black.opacity(0.7) }
    var textMuted: Color { scheme == .dark ? .white.opacity(0.6) : .black.opacity(0.6) }
    var textDim: Color { scheme == .dark ? .white.opacity(0.42) : .black.opacity(0.5) }
    var sectionHeader: Color { scheme == .dark ? .white.opacity(0.32) : .black.opacity(0.42) }
    var hint: Color { scheme == .dark ? .white.opacity(0.3) : .black.opacity(0.38) }
    var placeholder: Color { scheme == .dark ? .white.opacity(0.34) : .black.opacity(0.36) }
    var searchIcon: Color { scheme == .dark ? .white.opacity(0.5) : .black.opacity(0.45) }

    var accent: Color { Color(oklch: 0.7, 0.12, 250) }

    var quitBorder: Color { Color(oklch: 0.6, 0.15, 25, opacity: 0.35) }
    var quitText: Color { scheme == .dark ? Color(oklch: 0.78, 0.13, 25) : Color(oklch: 0.48, 0.16, 25) }
}
