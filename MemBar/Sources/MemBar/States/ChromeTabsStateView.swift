import SwiftUI

/// 2a — query "chrome": per-tab memory distribution, since a whole browser
/// can't be quit in one click. Segmented usage bar, heaviest-tabs list (first
/// pre-selected), and a suggested cleanup row.
struct ChromeTabsStateView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var selectedTab = 0

    private var totalGB: Double { MockData.chromeTabs.reduce(0) { $0 + $1.memGB } }

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("C")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color(oklch: 0.62, 0.12, 250), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Chrome").font(Fonts.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text(String(format: "%.1f GB · 38 processes · 23 tabs", totalGB))
                        .font(Fonts.monoSmall).foregroundStyle(theme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Quit app")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 10)
            .padding(.bottom, 12)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(MockData.chromeTabs) { tab in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tab.color)
                            .frame(width: max(2, geo.size.width * CGFloat(tab.pct * 0.98 / 100)), height: 6)
                    }
                }
            }
            .frame(height: 6)
            .padding(.horizontal, Metrics.rowSidePadding)

            SectionHeader(title: "Heaviest tabs").padding(.top, 16).padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(Array(MockData.chromeTabs.enumerated()), id: \.element.id) { index, tab in
                    tabRow(tab, isSelected: selectedTab == index) { hovering in
                        if hovering { selectedTab = index }
                    }
                }
            }

            HStack(spacing: 10) {
                Text("→").font(.system(size: 13)).foregroundStyle(theme.textMuted)
                Text("Close 9 tabs idle over 2h").font(Fonts.body).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("frees ~2.3 GB").font(Fonts.monoSmall).foregroundStyle(theme.textDim)
                Text("↵").font(Fonts.monoSmall).foregroundStyle(theme.hint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .frame(height: 38)
            .background(theme.rowSelected.opacity(0.6), in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 14)
        .onAppear { selectedTab = 0 }
    }

    @ViewBuilder
    private func tabRow(_ tab: TabUsage, isSelected: Bool, onHover: @escaping (Bool) -> Void) -> some View {
        let theme = Theme(scheme: scheme)
        HStack(spacing: 10) {
            Circle().fill(tab.color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(Fonts.body).foregroundStyle(theme.textPrimary).lineLimit(1).truncationMode(.tail)
                Text(tab.meta).font(Fonts.monoSmall).foregroundStyle(theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(tab.memText).font(Fonts.mono).foregroundStyle(theme.textDim)

            Text("Close")
                .font(.system(size: 11))
                .foregroundStyle(theme.quitText)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.quitBorder, lineWidth: 1))
        }
        .padding(.horizontal, Metrics.rowSidePadding)
        .frame(height: 44)
        .background(isSelected ? theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .animation(.linear(duration: 0.14), value: isSelected)
    }
}
