import SwiftUI

/// State C — query "memory"/"ram". Combines the two "memory" artboards from
/// the handoff: 1e's overview numbers (total/used/recommendations) with 2b's
/// interactive charts (pressure history + composition) added in the second
/// design pass, plus the shared top-memory-users list.
struct MemoryStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @State private var selectedApp: Int?

    private var usedGB: Double { 12.4 }
    private var totalGB: Double { 16 }

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Memory overview").padding(.top, 8).padding(.bottom, 4)

            VStack(spacing: 0) {
                overviewRow("Memory pressure") { MemoryPressureBadge(level: model.level) }
                overviewRow("Total") { Text(String(format: "%.0f GB", totalGB)).font(Fonts.mono).foregroundStyle(theme.textPrimary) }
                overviewRow("Used") { Text(String(format: "%.1f GB", usedGB)).font(Fonts.mono).foregroundStyle(theme.textPrimary) }
            }

            ZStack(alignment: .leading) {
                Capsule().fill(theme.trackBackground).frame(height: 5)
                GeometryReader { geo in
                    Capsule()
                        .fill(model.level.chartColor)
                        .frame(width: geo.size.width * CGFloat(usedGB / totalGB), height: 5)
                }
                .frame(height: 5)
            }
            .frame(height: 5)
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 8)

            PressureHistoryChart(model: model).padding(.top, 20)
            CompositionChart(model: model)

            SectionHeader(title: "Top memory users").padding(.top, 20).padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(MockData.chartTopApps.enumerated()), id: \.element.id) { index, app in
                    AppListItem(app: app, isSelected: selectedApp == index, quitMode: .never, showProgress: true, onHover: { hovering in
                        selectedApp = hovering ? index : (selectedApp == index ? nil : selectedApp)
                    })
                }
            }

            SectionHeader(title: "Recommendations").padding(.top, 18).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MockData.memoryRecommendations.enumerated()), id: \.offset) { index, text in
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
