import AppKit
import SwiftUI

enum PressureLevel: String, Equatable {
    case low = "LOW", medium = "MEDIUM", high = "HIGH"

    /// Thresholds mirror the design's `PRESSURE_COLOR` helper (>85 high, >65 medium, else low).
    /// Used for the per-sample chart bar color; the headline badge instead uses the composite
    /// pressure signal (kernel + availability) from `SystemMonitor.pressureLevel`.
    init(percent: Double) {
        if percent > 85 { self = .high }
        else if percent > 65 { self = .medium }
        else { self = .low }
    }

    /// Availability-based pressure from `availableFraction` (AVAIL / total).
    ///   > 25 % available → LOW
    ///   10–25 %          → MEDIUM   (e.g. < ~4 GB on a 16 GB machine)
    ///   < 10 %           → HIGH
    init(availableFraction: Double) {
        if availableFraction < 0.10 { self = .high }
        else if availableFraction < 0.25 { self = .medium }
        else { self = .low }
    }

    /// Numeric severity so we can take the max of two signals.
    var severity: Int {
        switch self { case .low: return 0; case .medium: return 1; case .high: return 2 }
    }

    /// Returns whichever level is worse (higher severity).
    func combined(with other: PressureLevel) -> PressureLevel {
        severity >= other.severity ? self : other
    }

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

    func badgeText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(oklch: 0.84, 0.13, hue) : .white
    }

    func badgeBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(oklch: 0.55, 0.15, hue, opacity: 0.26) : Color(oklch: 0.55, 0.16, hue)
    }
}

/// A running app row: real icon, real name, real memory footprint. `hue`
/// only backs the monogram-tile fallback for the rare app with no icon.
struct AppUsage: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let memGB: Double
    var reason: String?
    var pct: Double

    private let hue: Double

    init(app: RunningAppUsage, reason: String? = nil, pct: Double = 100) {
        self.id = app.pid
        self.name = app.name
        self.icon = app.icon
        self.memGB = app.footprintGB
        self.reason = reason
        self.pct = pct
        self.hue = Self.hue(for: app.bundleIdentifier ?? app.name)
    }

    var initial: String { String(name.first ?? "?").uppercased() }
    var color: Color { Color(oklch: 0.62, 0.12, hue) }
    var memText: String {
        if memGB >= 1.0 {
            return String(format: "%.1f GB", memGB)
        } else {
            let mb = memGB * 1024
            return String(format: "%.0f MB", mb)
        }
    }

    private static func hue(for key: String) -> Double {
        let hues: [Double] = [250, 200, 290, 140, 60, 85, 150, 340]
        let index = abs(key.hashValue) % hues.count
        return hues[index]
    }
}

struct MemorySegment: Identifiable {
    let id = UUID()
    let label: String
    let gb: Double
    let pct: Double
    let color: Color

    var gbText: String { String(format: "%.1f GB", gb) }
}

/// A suggested/recommended action row. `perform` is wired by whichever state
/// view builds the list — e.g. `{ model.quit(pid: app.pid) }`.
struct RecommendedAction: Identifiable {
    let id = UUID()
    let title: String
    let freesGB: Double?
    var perform: () -> Void = {}

    var freesText: String? { freesGB.map { "frees ~" + String(format: "%.1f", $0) + " GB" } }
}

struct DiagnosisPoint: Identifiable {
    let id = UUID()
    let text: String
    let emphasized: Bool
    let dimmed: Bool
}

extension MemorySnapshot {
    /// The five-segment breakdown used by the "Composition" chart.
    func compositionSegments(scheme: ColorScheme) -> [MemorySegment] {
        let total = max(totalBytes, 1)
        func pct(_ bytes: UInt64) -> Double { Double(bytes) / Double(total) * 100 }
        let freeColor: Color = scheme == .dark ? .white.opacity(0.16) : .black.opacity(0.16)
        return [
            MemorySegment(label: "App memory", gb: Double(appBytes) / 1e9, pct: pct(appBytes), color: Color(oklch: 0.62, 0.12, 250)),
            MemorySegment(label: "Wired", gb: Double(wiredBytes) / 1e9, pct: pct(wiredBytes), color: Color(oklch: 0.62, 0.12, 290)),
            MemorySegment(label: "Compressed", gb: Double(compressedBytes) / 1e9, pct: pct(compressedBytes), color: Color(oklch: 0.72, 0.14, 85)),
            MemorySegment(label: "Cached", gb: Double(cachedBytes) / 1e9, pct: pct(cachedBytes), color: Color(oklch: 0.64, 0.13, 150)),
            MemorySegment(label: "Free", gb: Double(freeBytes) / 1e9, pct: pct(freeBytes), color: freeColor),
        ]
    }
}

/// A registered slash command available in the command palette search field.
struct SlashCommand: Identifiable, Equatable {
    var id: String { trigger }
    let name: String
    let trigger: String
    let description: String
    let iconName: String
    let example: String
    let template: String

    static let all: [SlashCommand] = [
        SlashCommand(
            name: "/quit <app>",
            trigger: "/quit",
            description: "Quit an app with live auto-suggestions",
            iconName: "xmark.circle.fill",
            example: "/quit Chrome",
            template: "/quit "
        ),
        SlashCommand(
            name: "/forcequit <app>",
            trigger: "/forcequit",
            description: "Force kill unresponsive or frozen app (SIGKILL)",
            iconName: "bolt.trianglebadge.exclamationmark.fill",
            example: "/forcequit Xcode",
            template: "/forcequit "
        ),
        SlashCommand(
            name: "/help",
            trigger: "/help",
            description: "Show all available commands and syntax",
            iconName: "questionmark.circle.fill",
            example: "/help",
            template: "/help"
        ),
        SlashCommand(
            name: "/memory",
            trigger: "/memory",
            description: "Detailed RAM breakdown & composition chart",
            iconName: "memorychip.fill",
            example: "/memory",
            template: "/memory"
        ),
        SlashCommand(
            name: "/tabs",
            trigger: "/tabs",
            description: "Review & close heavy Google Chrome tabs",
            iconName: "globe",
            example: "/tabs",
            template: "/tabs"
        ),
        SlashCommand(
            name: "/close",
            trigger: "/close",
            description: "Review idle background apps safe to close",
            iconName: "clock.arrow.circlepath",
            example: "/close",
            template: "/close"
        ),
        SlashCommand(
            name: "/slow",
            trigger: "/slow",
            description: "Diagnose system memory pressure & actions",
            iconName: "exclamationmark.triangle.fill",
            example: "/slow",
            template: "/slow"
        ),
        SlashCommand(
            name: "/version",
            trigger: "/version",
            description: "Show current Pulse version and check for updates",
            iconName: "info.circle.fill",
            example: "/version",
            template: "/version"
        ),
        SlashCommand(
            name: "/update",
            trigger: "/update",
            description: "Download and install the latest version of Pulse",
            iconName: "arrow.down.circle.fill",
            example: "/update",
            template: "/update"
        )
    ]
}
