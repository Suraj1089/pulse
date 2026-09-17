import SwiftUI

/// Detailed per-tab and process breakdown for Google Chrome.
/// Attributes memory honest to tabs via burst-pairing with OOPIF subframe support.
struct ChromeTabsStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @State private var selectedTabID: Int?
    @State private var expandedTabID: Int?

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

    private var largestTabBytes: UInt64 {
        attributions.values.map { $0.totalBytes }.max() ?? 1
    }

    private var measuredCount: Int {
        tabs.filter { (attributions[$0.id]?.totalBytes ?? 0) > 0 }.count
    }

    private var backgroundTabCount: Int {
        tabs.filter { !$0.isActive }.count
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

            // Section Header: Top 5 memory-heavy tabs
            HStack {
                SectionHeader(title: "Top 5 memory-heavy tabs")
                Spacer()
                Text("Close tabs to reclaim RAM")
                    .font(Fonts.monoTiny)
                    .foregroundStyle(theme.hint)
            }
            .padding(.bottom, 4)

            // Tab rows: Top 5 most memory consuming tabs
            VStack(spacing: 1) {
                ForEach(Array(sortedTabs.prefix(5))) { tab in
                    let attr = attributions[tab.id]
                    let isSelected = selectedTabID == tab.id
                    let isExpanded = expandedTabID == tab.id

                    VStack(spacing: 0) {
                        tabRow(
                            tab: tab,
                            attr: attr,
                            isSelected: isSelected,
                            isExpanded: isExpanded,
                            theme: theme
                        )

                        if isExpanded, let attr, attr.processCount > 1 {
                            tabDetailBreakdown(attr, theme: theme)
                        }
                    }
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

            // Aggregate subframes callout
            aggregateSubframesCallout(theme)
                .padding(.top, 10)

            // Close background tabs action
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

            // Non-closeable browser overhead footer
            if let dist = distribution, dist.overheadBytes > 0 {
                HStack {
                    Text("Browser overhead (GPU, network, audio, browser)")
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.hint)
                    Spacer()
                    Text(String(format: "%.1f GB · not closeable", dist.overheadGB))
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
    private func tabRow(
        tab: ChromeTab,
        attr: TabAttribution?,
        isSelected: Bool,
        isExpanded: Bool,
        theme: Theme
    ) -> some View {
        let hostColor = Color(oklch: 0.62, 0.12, Double(abs(tab.host.hashValue) % 360))
        let totalBytes = attr?.totalBytes ?? 0
        let fraction = largestTabBytes > 0 ? Double(totalBytes) / Double(largestTabBytes) : 0

        HStack(spacing: 8) {
            // Expand arrow for tabs with multiple subframes
            if let attr, attr.processCount > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        expandedTabID = (expandedTabID == tab.id) ? nil : tab.id
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            // Host dot
            Circle()
                .fill(tab.isActive ? hostColor : hostColor.opacity(0.45))
                .frame(width: 6, height: 6)

            // Title & metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.cleanedTitle)
                    .font(Fonts.body)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 4) {
                    Text(tab.isActive ? "\(tab.host) · active" : tab.host)
                        .font(Fonts.monoSmall)
                        .foregroundStyle(theme.textDim)

                    if let attr {
                        if attr.embedCount > 0 {
                            Text("· \(attr.processCount) procs (\(attr.embedCount) subframes)")
                                .font(Fonts.monoTiny)
                                .foregroundStyle(theme.hint)
                        } else {
                            Text("· 1 proc")
                                .font(Fonts.monoTiny)
                                .foregroundStyle(theme.hint)
                        }
                        if attr.isShared {
                            Text("· shared")
                                .font(Fonts.monoTiny)
                                .foregroundStyle(theme.hint)
                        }
                    } else {
                        Text("· not measured yet")
                            .font(Fonts.monoTiny)
                            .foregroundStyle(theme.hint)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // Activate tab in Chrome on click
                model.monitor.activateChromeTab(tab)
            }

            // Relative memory bar
            if totalBytes > 0 {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.trackBackground)
                        .frame(width: 56, height: 4)
                    Capsule()
                        .fill(hostColor)
                        .frame(width: max(3, 56 * CGFloat(fraction)), height: 4)
                }
            }

            // Memory readout
            Text(formattedMemory(bytes: totalBytes))
                .font(Fonts.mono)
                .foregroundStyle(totalBytes > 0 ? theme.textPrimary : theme.hint)
                .frame(width: 58, alignment: .trailing)

            // Close button on hover
            if isSelected {
                Button {
                    model.monitor.closeChromeTab(tab)
                } label: {
                    Text("Close")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.quitText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.quitBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 44)
            }
        }
        .padding(.horizontal, Metrics.rowSidePadding)
        .frame(height: Metrics.rowHeightWithReason)
        .background(
            isSelected ? theme.rowSelected : .clear,
            in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering && selectedTabID != tab.id { selectedTabID = tab.id }
        }
    }

    // MARK: - Detail Subframe Breakdown

    @ViewBuilder
    private func tabDetailBreakdown(_ attr: TabAttribution, theme: Theme) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(attr.renderers.enumerated()), id: \.element.pid) { idx, r in
                HStack {
                    Spacer().frame(width: 26)
                    Text(idx == 0 ? "Main frame" : "Subframe / OOPIF")
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.textDim)
                    Text("PID \(r.pid)")
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.hint)
                    Spacer()
                    Text(String(format: "%.1f MB", r.footprintMB))
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.textSecondary)
                    Spacer().frame(width: 48)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 4)
        .background(theme.trackBackground.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, Metrics.rowSidePadding)
    }

    @ViewBuilder
    private func aggregateSubframesCallout(_ theme: Theme) -> some View {
        let totalSubframeBytes = attributions.values.reduce(UInt64(0)) { $0 + $1.embedBytes }
        let totalSubframeProcs = attributions.values.reduce(0) { $0 + $1.embedCount }

        if totalSubframeProcs > 0 {
            HStack {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.hint)
                Text("Embeds & subframes across tabs")
                    .font(Fonts.monoSmall)
                    .foregroundStyle(theme.textDim)
                Spacer()
                Text(String(format: "≈%.1f MB · %d process%@", Double(totalSubframeBytes) / 1e6, totalSubframeProcs, totalSubframeProcs == 1 ? "" : "es"))
                    .font(Fonts.monoSmall)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.vertical, 6)
            .background(theme.trackBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
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
            format: "%.1f GB · %d process%@ · %d tab%@",
            chromeApp.footprintGB,
            chromeApp.processCount, chromeApp.processCount == 1 ? "" : "es",
            tabs.count, tabs.count == 1 ? "" : "s"
        )
    }
}
