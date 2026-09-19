import SwiftUI

/// State C — query "memory"/"ram". Combines the two "memory" artboards from
/// the handoff (1e's overview numbers, 2b's charts) into one real-data view:
/// live pressure/total/used, the real pressure-history and composition
/// charts, real top apps with relative-usage bars, and recommendations
/// generated from whichever app is actually heaviest or idle right now.
struct MemoryStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @State private var selectedApp: Int?

    private var topApps: [AppUsage] {
        let apps = Array(model.monitor.topApps.prefix(5))
        let maxBytes = apps.map(\.residentBytes).max() ?? 1
        return apps.map { app in
            let pct = maxBytes == 0 ? 0 : Double(app.residentBytes) / Double(maxBytes) * 100
            return AppUsage(app: app, reason: app.residentDescription, pct: pct)
        }
    }

    private var recommendations: [String] {
        var lines: [String] = []
        if let heaviest = model.monitor.topApps.first {
            lines.append("\(heaviest.name) has the largest resident-memory use.")
        }
        if let idle = model.monitor.topApps.first(where: { app in
            guard let idleSince = app.idleSince else { return false }
            return Date().timeIntervalSince(idleSince) >= RunningAppUsage.recommendedQuitIdleInterval
        }), let idleSince = idle.idleSince {
            lines.append("Consider quitting \(idle.name) — \(Formatters.idleDuration(since: idleSince)).")
        }
        if lines.isEmpty {
            lines.append("Nothing unusual — memory use looks normal.")
        }
        return lines
    }

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Memory overview").padding(.top, 8).padding(.bottom, 4)

            VStack(spacing: 0) {
                overviewRow("Memory pressure") { MemoryPressureBadge(level: model.level) }
                overviewRow("Total") { Text(String(format: "%.0f GB", model.totalGB)).font(Fonts.mono).foregroundStyle(theme.textPrimary) }
                overviewRow("Used") { Text(String(format: "%.1f GB", model.usedGB)).font(Fonts.mono).foregroundStyle(theme.textPrimary) }
            }

            ZStack(alignment: .leading) {
                Capsule().fill(theme.trackBackground).frame(height: 5)
                GeometryReader { geo in
                    Capsule()
                        .fill(model.level.chartColor)
                        .frame(width: geo.size.width * CGFloat(model.totalGB > 0 ? model.usedGB / model.totalGB : 0), height: 5)
                }
                .frame(height: 5)
            }
            .frame(height: 5)
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 8)

            PressureHistoryChart(model: model).padding(.top, 20)
            CompositionChart(model: model)

            SectionHeader(title: "Top resident-memory apps").padding(.top, 20).padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(topApps.enumerated()), id: \.element.id) { index, app in
                    AppListItem(app: app, isSelected: selectedApp == index, quitMode: .never, showProgress: true, onHover: { hovering in
                        selectedApp = hovering ? index : (selectedApp == index ? nil : selectedApp)
                    })
                }
            }

            SectionHeader(title: "Recommendations").padding(.top, 18).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(recommendations.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(index == 0 ? model.level.chartColor : theme.textDim.opacity(0.85))
                            .frame(width: 5, height: 5)
                            .padding(.top, 5.5)
                        Text(text).font(Fonts.body).foregroundStyle(theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, Metrics.rowSidePadding)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func overviewRow<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        let theme = Theme(scheme: scheme)
        HStack {
            Text(label).font(Fonts.body).foregroundStyle(theme.textSecondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, Metrics.rowSidePadding)
        .frame(height: 30)
    }
}
