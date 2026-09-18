import SwiftUI

/// A compact, read-only per-tab memory list for Google Chrome.
struct ChromeTabsStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel

    private var chromeApp: RunningAppUsage? {
        model.monitor.topApps.first { $0.bundleIdentifier == ChromeTabsBridge.bundleIdentifier }
    }

    private var distribution: ChromeDistribution? {
        model.monitor.chromeDistribution
    }

    private var attributions: [Int: TabAttribution] {
        model.monitor.tabAttributions
    }

    private var tabs: [ChromeTab] {
        model.monitor.chromeTabs
    }

    private func isBlankOrNewTab(_ t: ChromeTab) -> Bool {
        let title = t.cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let url = t.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title == "new tab" || title.isEmpty || url.hasPrefix("chrome://newtab") || url == "about:blank"
    }

    /// Sorted: measured tabs first (highest footprint first), then unmeasured,
    /// with "New Tab" sorting last regardless, and active tabs first.
    private var sortedTabs: [ChromeTab] {
        tabs.sorted { a, b in
            let aIsNew = isBlankOrNewTab(a)
            let bIsNew = isBlankOrNewTab(b)
            if aIsNew != bIsNew { return bIsNew }

            let aBytes = attributions[a.id]?.totalBytes ?? 0
            let bBytes = attributions[b.id]?.totalBytes ?? 0

            if aBytes > 0 && bBytes > 0 {
                return aBytes > bBytes
            }
            if (aBytes > 0) != (bBytes > 0) {
                return aBytes > 0
            }

            // Active tabs are frontmost in user focus
            if a.isActive != b.isActive { return a.isActive }

            // Tab strip order fallback
            if a.windowIndex != b.windowIndex {
                return a.windowIndex < b.windowIndex
            }
            return a.tabIndex < b.tabIndex
        }
    }

    var body: some View {
        let theme = Theme(scheme: scheme)
        Group {
            if !model.monitor.chromeIsRunning {
                emptyState(theme, "Google Chrome is not running.")
            } else if tabs.isEmpty {
                emptyState(theme, "Reading open tabs from Chrome…\nIf macOS asks for Automation permission, grant it to view tabs.")
            } else {
                content(theme)
            }
        }
        .onAppear {
            model.monitor.startWatchingChrome()
        }
        .onDisappear {
            model.monitor.stopWatchingChrome()
        }
    }

    @ViewBuilder
    private func emptyState(_ theme: Theme, _ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 28))
                .foregroundStyle(theme.textDim)
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
            // Header card
            headerCard(theme)
                .padding(.horizontal, Metrics.rowSidePadding)
                .padding(.top, 8)
                .padding(.bottom, 10)

            // Process Distribution Breakdown (Phase 1.2)
            if let dist = distribution {
                distributionBands(dist, theme: theme)
                    .padding(.horizontal, Metrics.rowSidePadding)
                    .padding(.bottom, 10)
            }

            if let recommendation = model.monitor.chromeMemoryRecommendation {
                reviewRecommendation(recommendation, theme: theme)
                    .padding(.horizontal, Metrics.rowSidePadding)
                    .padding(.bottom, 10)
            }

            SectionHeader(title: "Memory-heavy tabs")
            .padding(.bottom, 4)

            // Keep this list deliberately scannable: title and memory only.
            VStack(spacing: 1) {
                ForEach(Array(sortedTabs.prefix(5))) { tab in
                    tabRow(tab: tab, memoryBytes: attributions[tab.id]?.totalBytes ?? 0, theme: theme)
                }
            }

            if tabs.count > 5 {
                HStack {
                    Text("+ \(tabs.count - 5) other low-memory tabs")
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.hint)
                    Spacer()
                }
                .padding(.horizontal, Metrics.rowSidePadding)
                .padding(.top, 4)
            }

            // Non-closeable browser overhead footer
            if let dist = distribution, dist.overheadBytes > 0 {
                HStack {
                    Text("Browser overhead (GPU, network, audio, browser)")
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.hint)
                    Spacer()
                    Text(String(format: "%.1f GB resident · not tied to a tab", dist.overheadGB))
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.hint)
                }
                .padding(.horizontal, Metrics.rowSidePadding)
                .padding(.top, 10)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 14)
    }

    // MARK: - Header & Distribution

    @ViewBuilder
    private func headerCard(_ theme: Theme) -> some View {
        HStack(spacing: 10) {
            Text("C")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color(oklch: 0.62, 0.12, 250), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

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
    }

    @ViewBuilder
    private func distributionBands(_ dist: ChromeDistribution, theme: Theme) -> some View {
        HStack(spacing: 8) {
            bandPill(label: ">180MB", count: dist.highCount, color: Color(oklch: 0.62, 0.16, 25), theme: theme)
            bandPill(label: "60-180MB", count: dist.mediumCount, color: Color(oklch: 0.72, 0.14, 85), theme: theme)
            bandPill(label: "<60MB", count: dist.lowCount, color: Color(oklch: 0.64, 0.13, 150), theme: theme)
            if dist.extensionCount > 0 {
                bandPill(label: "\(dist.extensionCount) ext", count: nil, color: theme.textDim, theme: theme)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func reviewRecommendation(
        _ recommendation: (tab: ChromeTab, attribution: TabAttribution, idleSince: Date),
        theme: Theme
    ) -> some View {
        let minutes = max(15, Int(Date().timeIntervalSince(recommendation.idleSince) / 60))
        Button {
            model.monitor.activateChromeTab(recommendation.tab)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review this idle tab")
                        .font(Fonts.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("\(recommendation.tab.cleanedTitle) · \(minutes)m idle · \(Int(recommendation.attribution.totalMB)) MB")
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Open")
                    .font(Fonts.monoSmall)
                    .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.vertical, 8)
            .background(theme.rowSelected.opacity(0.55), in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bandPill(label: String, count: Int?, color: Color, theme: Theme) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            if let count {
                Text("\(count) \(label)").font(Fonts.monoTiny).foregroundStyle(theme.textDim)
            } else {
                Text(label).font(Fonts.monoTiny).foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(theme.trackBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - Tab Row

    @ViewBuilder
    private func tabRow(tab: ChromeTab, memoryBytes: UInt64, theme: Theme) -> some View {
        HStack(spacing: 8) {
            Text(tab.cleanedTitle)
                .font(Fonts.body)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formattedMemory(bytes: memoryBytes))
                .font(Fonts.mono)
                .foregroundStyle(memoryBytes > 0 ? theme.textPrimary : theme.hint)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.rowSidePadding)
        .frame(height: 42)
        .background(theme.rowSelected.opacity(0.35), in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
    }

    private func formattedMemory(bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        }
        return String(format: "%.0f MB", mb)
    }

    private var chromeSummary: String {
        guard let chromeApp else { return "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")" }
        return String(
            format: "%.1f GB resident · %d process%@ · %d tab%@",
            chromeApp.residentGB,
            chromeApp.processCount, chromeApp.processCount == 1 ? "" : "es",
            tabs.count, tabs.count == 1 ? "" : "s"
        )
    }
}
