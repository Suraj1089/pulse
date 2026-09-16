import Combine
import SwiftUI

enum PaletteState: Equatable {
    case overview
    case diagnosis
    case memory
    case close
    case chromeTabs
    case noMatch
}

/// Drives the palette's search-routed content and the live pressure ticker.
/// The ticker mirrors the handoff script's `componentDidMount` interval: every
/// 1.6s, nudge the last sample by a small random delta, clamped to 40...97,
/// and pause while a bar is hovered (`bar === null` guard in the source).
final class PaletteViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var samples: [Double] = MockData.pressureSamples
    @Published var hoveredBar: Int?
    @Published var hoveredSegment: Int?

    let showKeyHints = true
    let liveTicker = true

    private var timer: Timer?

    var currentPercent: Double { samples.last ?? 50 }
    var level: PressureLevel { PressureLevel(percent: currentPercent) }

    var apps: [AppUsage] { level == .low ? MockData.lowApps : MockData.highApps }
    var freeGB: Double { level == .low ? MockData.lowFreeGB : MockData.highFreeGB }

    var state: PaletteState {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return .overview }
        if q.contains("slow") { return .diagnosis }
        if q.contains("chrome") { return .chromeTabs }
        if q.contains("memory") || q.contains("ram") { return .memory }
        if q.contains("close") { return .close }
        return .noMatch
    }

    func startTicker() {
        stopTicker()
        timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in
            guard let self, self.liveTicker, self.hoveredBar == nil else { return }
            let last = self.samples.last ?? 60
            let delta = (Double.random(in: 0...1) - 0.45) * 9
            let next = min(97, max(40, (last + delta).rounded()))
            self.samples.removeFirst()
            self.samples.append(next)
        }
    }

    func stopTicker() {
        timer?.invalidate()
        timer = nil
    }

    func barReadout(atFallback index: Int?) -> String {
        let i = index ?? samples.count - 1
        let v = Int(samples[i])
        let t = i == samples.count - 1 ? "now" : "−\(samples.count - 1 - i)m"
        return "\(t) · \(v)% · \(PressureLevel(percent: Double(v)).rawValue)"
    }

    var segReadout: String {
        guard let seg = hoveredSegment else { return "12.4 GB used" }
        let s = MockData.compositionSegments[seg]
        return "\(s.label) · \(s.gbText)"
    }
}
