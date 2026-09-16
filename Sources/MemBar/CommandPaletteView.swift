import SwiftUI

/// CommandPaletteWindow root: SearchField header, the query-routed content
/// area, and the footer key hints. 560pt wide, 400...480pt tall, then scrolls.
struct CommandPaletteView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @FocusState private var searchFocused: Bool
    var onEscape: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(spacing: 0) {
            SearchFieldView(query: $model.query, showKeyHints: model.showKeyHints, isFocused: $searchFocused)

            ScrollView {
                Group {
                    switch model.state {
                    case .overview: OverviewStateView(model: model)
                    case .diagnosis: DiagnosisStateView()
                    case .memory: MemoryStateView(model: model)
                    case .close: CloseStateView()
                    case .chromeTabs: ChromeTabsStateView()
                    case .noMatch: NoMatchStateView()
                    }
                }
            }
            .frame(maxHeight: Metrics.windowMaxHeight - Metrics.headerHeight - Metrics.footerHeight)

            FooterHints(items: model.state == .chromeTabs
                ? ["↑↓ navigate", "↵ close tab", "esc close"]
                : ["↑↓ navigate", "↵ select", "esc close"])
        }
        .frame(width: Metrics.windowWidth)
        .frame(minHeight: Metrics.windowMinHeight)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.windowRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.windowRadius).strokeBorder(theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PaletteHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(PaletteHeightKey.self, perform: onHeightChange)
        .onAppear {
            model.startTicker()
            searchFocused = true
        }
        .onDisappear { model.stopTicker() }
        .onExitCommand(perform: onEscape)
    }
}
