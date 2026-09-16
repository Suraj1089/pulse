import SwiftUI

/// 2a — query "chrome": real open tabs (title + host, live from Chrome via
/// AppleScript) with a real bulk close-background-tabs action. Chrome
/// doesn't expose per-tab memory or idle time through scripting, so unlike
/// every other list in this app, there's no real per-tab number to show —
/// see `ChromeTabsBridge` for why.
struct ChromeTabsStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @State private var selectedTab = 0

    private static let dotHues: [Double] = [250, 290, 85, 150, 60, 200]

    private var chromeApp: RunningAppUsage? {
        model.monitor.topApps.first { $0.bundleIdentifier == ChromeTabsBridge.bundleIdentifier }
    }

    private var tabs: [ChromeTab] { model.monitor.chromeTabs }
    private var backgroundTabCount: Int { tabs.filter { !$0.isActive }.count }

    var body: some View {
        let theme = Theme(scheme: scheme)
        Group {
            if !model.monitor.chromeIsRunning {
                emptyState(theme, "Chrome isn't running.")
            } else if tabs.isEmpty {
                emptyState(theme, "No tabs found yet — if macOS just asked to let MemBar control Chrome, grant it and reopen this.")
            } else {
                content(theme)
            }
        }
        .onAppear { selectedTab = 0 }
    }

    @ViewBuilder
    private func emptyState(_ theme: Theme, _ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(Fonts.body)
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func content(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("C")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color(oklch: 0.62, 0.12, 250), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Chrome").font(Fonts.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text(chromeSummary).font(Fonts.monoSmall).foregroundStyle(theme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    model.monitor.quitChrome()
                } label: {
                    Text("Quit app")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 10)
            .padding(.bottom, 12)

            SectionHeader(title: "Open tabs").padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    tabRow(tab, hue: Self.dotHues[index % Self.dotHues.count], isSelected: selectedTab == index) { hovering in
                        if hovering { selectedTab = index }
                    }
                }
            }

            if backgroundTabCount > 0 {
                Button {
                    model.monitor.closeBackgroundChromeTabs()
                } label: {
                    HStack(spacing: 10) {
                        Text("→").font(.system(size: 13)).foregroundStyle(theme.textMuted)
                        Text("Close \(backgroundTabCount) background tab\(backgroundTabCount == 1 ? "" : "s")")
                            .font(Fonts.body).foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("↵").font(Fonts.monoSmall).foregroundStyle(theme.hint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
                    }
                    .padding(.horizontal, Metrics.rowSidePadding)
                    .frame(height: 38)
                    .background(theme.rowSelected.opacity(0.6), in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 14)
    }

    private var chromeSummary: String {
        guard let chromeApp else { return "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")" }
        return String(
            format: "%.1f GB · %d process%@ · %d tab%@",
            chromeApp.footprintGB,
            chromeApp.processCount, chromeApp.processCount == 1 ? "" : "es",
            tabs.count, tabs.count == 1 ? "" : "s"
        )
    }

    @ViewBuilder
    private func tabRow(_ tab: ChromeTab, hue: Double, isSelected: Bool, onHover: @escaping (Bool) -> Void) -> some View {
        let theme = Theme(scheme: scheme)
        HStack(spacing: 10) {
            Circle()
                .fill(tab.isActive ? Color(oklch: 0.62, 0.12, hue) : theme.textDim.opacity(0.5))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(Fonts.body).foregroundStyle(theme.textPrimary).lineLimit(1).truncationMode(.tail)
                Text(tab.isActive ? "\(tab.host) · active" : tab.host).font(Fonts.monoSmall).foregroundStyle(theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.monitor.closeChromeTab(tab)
            } label: {
                Text("Close")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.quitText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.quitBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Metrics.rowSidePadding)
        .frame(height: 44)
        .background(isSelected ? theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .animation(.linear(duration: 0.14), value: isSelected)
    }
}
