import SwiftUI

/// State A — default, no query. Pressure summary, top memory users (first row
/// pre-selected, revealing its Quit button), and suggested actions (headroom
/// message when LOW, recommendations when MEDIUM/HIGH).
struct OverviewStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @State private var selectedApp = 0
    @State private var hoveredAction: Int?

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Memory pressure").font(Fonts.body).foregroundStyle(theme.textSecondary)
                Spacer()
                HStack(spacing: 7) {
                    Text(String(format: "%.1f GB free", model.freeGB))
                        .font(Fonts.monoSmall)
                        .foregroundStyle(theme.textDim)
                    MemoryPressureBadge(level: model.level)
                }
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 8)
            .padding(.bottom, 10)

            SectionHeader(title: "Top memory users").padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                    AppListItem(
                        app: app,
                        isSelected: selectedApp == index,
                        quitMode: .onSelected,
                        onHover: { hovering in
                            if hovering { selectedApp = index }
                        }
                    )
                }
            }

            SectionHeader(title: "Suggested actions").padding(.top, 14).padding(.bottom, 6)

            if model.level == .low {
                HStack(spacing: 10) {
                    Text("→").font(.system(size: 13)).foregroundStyle(theme.hint)
                    Text("Nothing to do — you have headroom")
                        .font(Fonts.body)
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, Metrics.rowSidePadding)
                .frame(height: Metrics.rowHeight, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(MockData.highActions.enumerated()), id: \.element.id) { index, action in
                        RecommendationItem(action: action, isSelected: hoveredAction == index) { hovering in
                            hoveredAction = hovering ? index : (hoveredAction == index ? nil : hoveredAction)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 10)
    }
}
