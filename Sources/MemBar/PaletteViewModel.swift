import Combine
import SwiftUI

enum PaletteState: Equatable {
    case overview
    case diagnosis
    case memory
    case close
    case chromeTabs
    case help
    case quitCommand(appQuery: String, isForce: Bool = false)
    case commandSuggestions(filter: String)
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

    @Published private(set) var apps: [AppUsage] = []

    init() {
        // Re-publish the monitor's changes and keep cached apps in sync
        cancellable = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateApps()
                self?.objectWillChange.send()
            }
        }
        updateApps()
    }

    func start() {
        monitor.start()
        updateApps()
    }

    func stop() {
        monitor.stop()
    }

    func setPaletteVisible(_ visible: Bool) {
        monitor.setPaletteVisible(visible)
    }

    var level: PressureLevel { monitor.pressureLevel }
    var samples: [Double] { monitor.pressureSamples }
    var freeGB: Double { monitor.memory?.freeGB ?? 0 }
    var availableGB: Double { monitor.memory?.availableGB ?? 0 }
    var usedGB: Double { monitor.memory?.usedGB ?? 0 }
    var totalGB: Double { monitor.memory?.totalGB ?? 0 }

    /// Recomputes apps only when monitor publishes new state.
    private func updateApps() {
        let tabCount = monitor.chromeTabs.count
        self.apps = monitor.topApps.map { app in
            var reason: String? = nil
            if app.bundleIdentifier == ChromeTabsBridge.bundleIdentifier {
                if tabCount > 0 {
                    reason = "\(tabCount) tab\(tabCount == 1 ? "" : "s")"
                } else {
                    reason = "\(app.processCount) process\(app.processCount == 1 ? "" : "es")"
                }
            } else if app.processCount > 1 {
                reason = "\(app.processCount) processes"
            } else {
                reason = "Active"
            }
            return AppUsage(app: app, reason: reason)
        }
    }

    var state: PaletteState {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return .overview }

        let lower = q.lowercased()

        // 1. Slash commands
        if lower.hasPrefix("/") {
            let originalWithoutSlash = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            let withoutSlash = originalWithoutSlash.lowercased()

            if withoutSlash == "help" || withoutSlash == "?" {
                return .help
            }

            if withoutSlash.hasPrefix("forcequit") || withoutSlash.hasPrefix("force") || withoutSlash.hasPrefix("kill") || withoutSlash.hasPrefix("fq") {
                let prefixLen: Int
                if withoutSlash.hasPrefix("forcequit") { prefixLen = 9 }
                else if withoutSlash.hasPrefix("force") { prefixLen = 5 }
                else if withoutSlash.hasPrefix("kill") { prefixLen = 4 }
                else { prefixLen = 2 }
                let arg = String(originalWithoutSlash.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
                return .quitCommand(appQuery: arg, isForce: true)
            }

            if withoutSlash.hasPrefix("quit") {
                let arg = String(originalWithoutSlash.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                return .quitCommand(appQuery: arg, isForce: false)
            }

            if withoutSlash == "memory" || withoutSlash == "ram" {
                return .memory
            }

            if withoutSlash == "tabs" || withoutSlash == "chrome" {
                return .chromeTabs
            }

            if withoutSlash == "close" || withoutSlash == "apps" {
                return .close
            }

            if withoutSlash == "slow" || withoutSlash == "diag" || withoutSlash == "diagnosis" {
                return .diagnosis
            }

            // Incomplete slash command (e.g. "/", "/q", "/f", "/he")
            let matches = SlashCommand.all.filter {
                withoutSlash.isEmpty ||
                $0.trigger.lowercased().contains(withoutSlash) ||
                $0.name.lowercased().contains(withoutSlash)
            }
            if !matches.isEmpty {
                return .commandSuggestions(filter: withoutSlash)
            }
        }

        // 2. Natural language fallback
        if lower.hasPrefix("force quit ") || lower.hasPrefix("forcequit ") || lower.hasPrefix("kill ") {
            let prefixLen = lower.hasPrefix("force quit ") ? 11 : (lower.hasPrefix("forcequit ") ? 10 : 5)
            let arg = String(q.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            return .quitCommand(appQuery: arg, isForce: true)
        }
        if lower == "force quit" || lower == "forcequit" {
            return .quitCommand(appQuery: "", isForce: true)
        }
        if lower.hasPrefix("quit ") {
            let arg = String(q.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return .quitCommand(appQuery: arg, isForce: false)
        }
        if lower == "quit" {
            return .quitCommand(appQuery: "", isForce: false)
        }
        if lower == "help" || lower == "?" { return .help }
        if lower.contains("slow") || lower.contains("diag") { return .diagnosis }
        if lower.contains("chrome") || lower.contains("tab") { return .chromeTabs }
        if lower.contains("memory") || lower.contains("ram") { return .memory }
        if lower.contains("close") { return .close }

        return .noMatch
    }

    /// Auto-suggested matching apps for `/quit <query>`
    func matchingApps(for filter: String) -> [AppUsage] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return apps
        }
        return apps.filter { app in
            app.name.lowercased().contains(trimmed) ||
            app.initial.lowercased() == trimmed
        }
    }

    /// Auto-suggested slash commands for `/<query>`
    func matchingCommands(for filter: String) -> [SlashCommand] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return SlashCommand.all
        }
        return SlashCommand.all.filter { cmd in
            cmd.trigger.lowercased().contains(trimmed) ||
            cmd.name.lowercased().contains(trimmed) ||
            cmd.description.lowercased().contains(trimmed)
        }
    }

    func barReadout(atFallback index: Int?) -> String {
        guard !samples.isEmpty else { return "—" }
        let i = index ?? samples.count - 1
        let v = Int(samples[i])
        let t = i == samples.count - 1 ? "now" : "−\(samples.count - 1 - i)m"
        return "\(t) · \(v)% · \(PressureLevel(percent: Double(v)).rawValue)"
    }

    func quit(pid: pid_t, force: Bool = false) {
        monitor.quit(pid: pid, force: force)
    }
}
