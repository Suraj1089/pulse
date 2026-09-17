import SwiftUI

/// State B — query "why is my mac slow": a diagnosis built from real
/// signals (live pressure, real heaviest apps, real idle duration where we
/// have one) followed by recommended actions that actually quit those apps.
struct DiagnosisStateView: View {
    @ObservedObject var model: PaletteViewModel
    @State private var selectedAction = 0

    private var idleThreshold: TimeInterval { 15 * 60 }

    private var idleHeavyApp: RunningAppUsage? {
        model.monitor.topApps.first { app in
            guard let idleSince = app.idleSince else { return false }
            return Date().timeIntervalSince(idleSince) >= idleThreshold
        }
    }

    private var diagnosis: [DiagnosisPoint] {
        var points: [DiagnosisPoint] = []
        let level = model.level

        points.append(DiagnosisPoint(
            text: "Memory pressure is \(level.rawValue.lowercased()) — \(String(format: "%.1f", model.freeGB)) GB free of \(String(format: "%.0f", model.totalGB)) GB.",
            emphasized: level != .low,
            dimmed: false
        ))

        for app in model.monitor.topApps.prefix(2) {
            let processWord = app.processCount == 1 ? "process" : "processes"
            points.append(DiagnosisPoint(
                text: "\(app.name) is using \(String(format: "%.1f", app.footprintGB)) GB across \(app.processCount) \(processWord).",
                emphasized: false,
                dimmed: false
            ))
        }

        if let idle = idleHeavyApp, let idleSince = idle.idleSince {
            points.append(DiagnosisPoint(
                text: "\(idle.name) is using \(String(format: "%.1f", idle.footprintGB)) GB and has been \(Formatters.idleDuration(since: idleSince)).",
                emphasized: false,
                dimmed: false
            ))
        }

        return points
    }

    private var recommendedActions: [RecommendedAction] {
        var candidates = model.monitor.topApps.filter { !$0.isFrontmost }
        if let idle = idleHeavyApp {
            candidates.removeAll { $0.pid == idle.pid }
            candidates.insert(idle, at: 0)
        }
        return candidates.prefix(3).map { app in
            RecommendedAction(title: "Quit \(app.name)", freesGB: app.footprintGB) {
                model.quit(pid: app.pid)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Diagnosis").padding(.top, 8).padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(diagnosis) { point in
                    DiagnosisBullet(point: point)
                }
            }
            .padding(.horizontal, Metrics.rowSidePadding)

            SectionHeader(title: "Recommended actions").padding(.top, 18).padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(Array(recommendedActions.enumerated()), id: \.element.id) { index, action in
                    RecommendationItem(action: action, isSelected: selectedAction == index) { hovering in
                        if hovering { selectedAction = index }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 10)
        .onAppear { selectedAction = 0 }
    }
}
