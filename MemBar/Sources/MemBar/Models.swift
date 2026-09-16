import SwiftUI

enum PressureLevel: String, Equatable {
    case low = "LOW", medium = "MEDIUM", high = "HIGH"

    /// Thresholds mirror the design's `PRESSURE_COLOR` helper (>85 high, >65 medium, else low).
    init(percent: Double) {
        if percent > 85 { self = .high }
        else if percent > 65 { self = .medium }
        else { self = .low }
    }

    /// Chart bar / composition-segment color, matching `PRESSURE_COLOR` in the handoff script.
    var chartColor: Color {
        switch self {
        case .high: return Color(oklch: 0.62, 0.16, 25)
        case .medium: return Color(oklch: 0.72, 0.14, 85)
        case .low: return Color(oklch: 0.64, 0.13, 150)
        }
    }

    private var hue: Double {
        switch self {
        case .low: return 150
        case .medium: return 85
        case .high: return 25
        }
    }

    /// Badge colors: dark mode uses a translucent pill (1c), light mode uses a solid
    /// pill with white text (1e) — both variants appear in the handoff for HIGH.
    func badgeText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(oklch: 0.84, 0.13, hue) : .white
    }

    func badgeBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(oklch: 0.55, 0.15, hue, opacity: 0.26) : Color(oklch: 0.55, 0.16, hue)
    }
}

struct AppUsage: Identifiable {
    let id = UUID()
    let name: String
    let initial: String
    let hue: Double
    let memGB: Double
    var reason: String? = nil
    var pct: Double = 100

    var color: Color { Color(oklch: 0.62, 0.12, hue) }
    var memText: String { String(format: "%.1f GB", memGB) }
}

struct TabUsage: Identifiable {
    let id = UUID()
    let title: String
    let meta: String
    let memGB: Double
    let hue: Double?
    let pct: Double

    var color: Color { hue.map { Color(oklch: 0.62, 0.12, $0) } ?? Color.white.opacity(0.22) }
    var memText: String { String(format: "%.1f GB", memGB) }
}

struct MemorySegment: Identifiable {
    let id = UUID()
    let label: String
    let gb: Double
    let pct: Double
    let color: Color

    var gbText: String { String(format: "%.1f GB", gb) }
}

struct RecommendedAction: Identifiable {
    let id = UUID()
    let title: String
    let freesGB: Double?

    var freesText: String? { freesGB.map { "frees ~" + String(format: "%.1f", $0) + " GB" } }
}

struct DiagnosisPoint: Identifiable {
    let id = UUID()
    let text: String
    let emphasized: Bool
    let dimmed: Bool
}

/// Snapshot of app usage + headline free memory at a given pressure level,
/// matching artboards 1b (LOW) and 1c (HIGH) exactly.
enum MockData {
    static let lowApps = [
        AppUsage(name: "Chrome", initial: "C", hue: 250, memGB: 3.4),
        AppUsage(name: "Docker", initial: "D", hue: 200, memGB: 1.8),
        AppUsage(name: "Visual Studio Code", initial: "V", hue: 290, memGB: 1.1),
    ]
    static let lowFreeGB = 4.1

    static let highApps = [
        AppUsage(name: "Chrome", initial: "C", hue: 250, memGB: 6.2),
        AppUsage(name: "Docker", initial: "D", hue: 200, memGB: 3.1),
        AppUsage(name: "Visual Studio Code", initial: "V", hue: 290, memGB: 1.4),
        AppUsage(name: "Slack", initial: "S", hue: 140, memGB: 0.9),
    ]
    static let highFreeGB = 0.4

    static let highActions = [
        RecommendedAction(title: "Quit Docker", freesGB: 3.1),
        RecommendedAction(title: "Quit Chrome", freesGB: 6.2),
    ]

    static let diagnosis = [
        DiagnosisPoint(text: "Memory pressure is high — 0.4 GB free of 16 GB.", emphasized: true, dimmed: false),
        DiagnosisPoint(text: "Chrome is using 6.2 GB across 38 processes.", emphasized: false, dimmed: false),
        DiagnosisPoint(text: "Docker is using 3.1 GB and has been idle for 3 hours.", emphasized: false, dimmed: false),
        DiagnosisPoint(text: "11 browser tabs have been inactive for several hours.", emphasized: false, dimmed: true),
    ]
    static let diagnosisActions = [
        RecommendedAction(title: "Quit Docker", freesGB: 3.1),
        RecommendedAction(title: "Close 4 inactive Chrome tabs", freesGB: 2.3),
        RecommendedAction(title: "Quit Chrome", freesGB: 6.2),
    ]

    static let memoryRecommendations = [
        "Chrome is using 38% of total memory.",
        "Consider quitting Docker — idle for 2h.",
    ]

    static let closeApps = [
        AppUsage(name: "Docker", initial: "D", hue: 200, memGB: 3.1, reason: "idle 3h"),
        AppUsage(name: "Figma", initial: "F", hue: 60, memGB: 0.7, reason: "inactive since 09:40"),
        AppUsage(name: "Slack", initial: "S", hue: 140, memGB: 0.9, reason: "using 2.4× its usual memory"),
    ]

    static let chromeTabs = [
        TabUsage(title: "Figma — MemPalette / palette states", meta: "active · pinned", memGB: 1.4, hue: 250, pct: 22.6),
        TabUsage(title: "YouTube — Build a menu bar app in SwiftUI", meta: "playing audio", memGB: 0.9, hue: 290, pct: 14.5),
        TabUsage(title: "Google Sheets — Q3 infra spend", meta: "idle 2h 40m", memGB: 0.7, hue: 85, pct: 11.3),
        TabUsage(title: "Notion — Engineering wiki", meta: "idle 4h", memGB: 0.5, hue: 150, pct: 8.1),
        TabUsage(title: "19 other tabs", meta: "9 idle over 2h", memGB: 2.7, hue: nil, pct: 43.5),
    ]

    static let compositionSegments = [
        MemorySegment(label: "App memory", gb: 7.8, pct: 48.8, color: Color(oklch: 0.62, 0.12, 250)),
        MemorySegment(label: "Wired", gb: 2.6, pct: 16.3, color: Color(oklch: 0.62, 0.12, 290)),
        MemorySegment(label: "Compressed", gb: 1.4, pct: 8.8, color: Color(oklch: 0.72, 0.14, 85)),
        MemorySegment(label: "Cached", gb: 0.6, pct: 3.8, color: Color(oklch: 0.64, 0.13, 150)),
        MemorySegment(label: "Free", gb: 3.6, pct: 22.3, color: .white.opacity(0.16)),
    ]

    static let chartTopApps = [
        AppUsage(name: "Chrome", initial: "C", hue: 250, memGB: 6.2, pct: 100),
        AppUsage(name: "Docker", initial: "D", hue: 200, memGB: 3.1, pct: 50),
        AppUsage(name: "Visual Studio Code", initial: "V", hue: 290, memGB: 1.4, pct: 23),
        AppUsage(name: "Slack", initial: "S", hue: 140, memGB: 0.9, pct: 15),
        AppUsage(name: "Figma", initial: "F", hue: 60, memGB: 0.7, pct: 11),
    ]

    static let pressureSamples: [Double] = [
        52, 55, 51, 58, 61, 57, 63, 66, 62, 68, 71, 69, 74, 72, 77, 81, 78, 84, 88, 85,
        83, 89, 92, 90, 87, 91, 94, 92, 89, 93,
    ]
}
