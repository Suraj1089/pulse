import SwiftUI

/// State A — default, no query. Real pressure summary, real top memory
/// users (first row pre-selected, revealing its Quit button), and
/// suggested actions generated from the real, non-frontmost heaviest apps.
struct OverviewStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @State private var selectedApp = 0
    @State private var hoveredAction: Int?

    private var apps: [AppUsage] { Array(model.apps.prefix(4)) }

    private var suggestedActions: [RecommendedAction] {
        model.monitor.topApps
            .filter { !$0.isFrontmost }
            .prefix(2)
            .map { app in
                RecommendedAction(title: "Quit \(app.name)", freesGB: app.footprintGB) {
                    model.quit(pid: app.pid)
                }
            }
    }

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
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    AppListItem(
                        app: app,
                        isSelected: selectedApp == index,
                        quitMode: .onSelected,
                        onHover: { hovering in
                            if hovering { selectedApp = index }
                        },
                        onQuit: { model.quit(pid: app.id) }
                    )
                }
            }

            SectionHeader(title: "Suggested actions").padding(.top, 14).padding(.bottom, 6)

            if model.level == .low || suggestedActions.isEmpty {
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
                    ForEach(Array(suggestedActions.enumerated()), id: \.element.id) { index, action in
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
        .onAppear { selectedApp = 0 }
    }
}
