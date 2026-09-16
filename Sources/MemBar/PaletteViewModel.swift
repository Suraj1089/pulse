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

/// Thin coordinator between the search query and `SystemMonitor`'s live
/// data. Owns only transient UI state (the query string, chart hover);
/// everything else is read straight through to the monitor.
final class PaletteViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            if state == .chromeTabs {
                monitor.startWatchingChrome()
            } else {
                monitor.stopWatchingChrome()
            }
        }
    }
    @Published var hoveredBar: Int?
    @Published var hoveredSegment: Int?

    let showKeyHints = true
    let monitor = SystemMonitor()

    private var cancellable: AnyCancellable?

    init() {
        // Re-publish the monitor's changes as our own so views only need to
        // observe this one object.
        cancellable = monitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func start() { monitor.start() }
    func stop() { monitor.stop() }

    var level: PressureLevel { monitor.pressureLevel }
    var samples: [Double] { monitor.pressureSamples }
    var freeGB: Double { monitor.memory?.freeGB ?? 0 }
    var usedGB: Double { monitor.memory?.usedGB ?? 0 }
    var totalGB: Double { monitor.memory?.totalGB ?? 0 }

    /// Real top apps, heaviest first — already sorted by `RunningAppsMonitor`.
    var apps: [AppUsage] { monitor.topApps.map { AppUsage(app: $0) } }

    var state: PaletteState {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return .overview }
        if q.contains("slow") { return .diagnosis }
        if q.contains("chrome") { return .chromeTabs }
        if q.contains("memory") || q.contains("ram") { return .memory }
        if q.contains("close") { return .close }
        return .noMatch
    }

    func barReadout(atFallback index: Int?) -> String {
        guard !samples.isEmpty else { return "—" }
        let i = index ?? samples.count - 1
        let v = Int(samples[i])
        let t = i == samples.count - 1 ? "now" : "−\(samples.count - 1 - i)m"
        return "\(t) · \(v)% · \(PressureLevel(percent: Double(v)).rawValue)"
    }

    func quit(pid: pid_t) {
        monitor.quit(pid: pid)
    }
}
