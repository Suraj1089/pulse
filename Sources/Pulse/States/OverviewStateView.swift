import SwiftUI

/// State A — default, no query. Real pressure summary, real top memory
/// users (first row pre-selected, revealing its Quit button), and
/// suggested actions generated from the real, non-frontmost heaviest apps.
struct OverviewStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @State private var selectedApp = 0
    @State private var hoveredAction: Int?
    @State private var expandedAppID: pid_t? = nil
    @State private var isOptionPressed: Bool = false
    @State private var flagsMonitor: Any? = nil
    /// PIDs whose rows are currently animating out — filtered from display
    /// immediately so the animation fires before the model's 3 s refresh.
    @State private var quittingPIDs: Set<pid_t> = []

    private var apps: [AppUsage] {
        Array(model.apps.prefix(6)).filter { !quittingPIDs.contains($0.id) }
    }

    private var suggestedActions: [RecommendedAction] {
        model.monitor.topApps
            .filter { !$0.isFrontmost }
            .prefix(2)
            .map { app in
                RecommendedAction(title: "Quit \(app.name)", detail: "May reduce pressure") {
                    animatedQuit(pid: app.pid)
                }
            }
    }

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Top Resident-Memory Apps")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)

                Spacer()

                Text("RESIDENT")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textDim)

                Spacer().frame(width: 52) // Aligns with the Quit pill button
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 4)
            .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    let isChrome = app.name.lowercased().contains("chrome")
                    let isExpanded = expandedAppID == app.id

                    VStack(spacing: 0) {
                        AppListItem(
                            app: app,
                            isSelected: selectedApp == index,
                            quitMode: .always,
                            quitLabel: isOptionPressed ? "Force Quit" : "Quit",
                            isDestructive: isOptionPressed,
                            hasExpandSlot: false,
                            isExpandable: isChrome,
                            isExpanded: isExpanded,
                            onToggleExpand: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedAppID = (expandedAppID == app.id) ? nil : app.id
                                    if expandedAppID != nil {
                                        model.monitor.startWatchingChrome()
                                    } else {
                                        model.monitor.stopWatchingChrome()
                                    }
                                }
                            },
                            onHover: { hovering in
                                if hovering && selectedApp != index {
                                    selectedApp = index
                                }
                            },
                            onQuit: { animatedQuit(pid: app.id, force: isOptionPressed) }
                        )

                        if isExpanded && isChrome {
                            inlineChromeTabsOverview(theme)
                        }
                    }
                    .transition(.quitSweep)
                }
            }
            // Clip so the sweeping row doesn't paint outside the list bounds.
            .clipped()

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
        .onAppear {
            selectedApp = 0
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let option = event.modifierFlags.contains(.option)
                if self.isOptionPressed != option {
                    self.isOptionPressed = option
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
                flagsMonitor = nil
            }
            if expandedAppID != nil {
                model.monitor.stopWatchingChrome()
            }
        }
        // Once the model confirms the process is gone, clean up local state.
        .onChange(of: model.apps.map { $0.id }) { _, liveIDs in
            quittingPIDs = quittingPIDs.filter { liveIDs.contains($0) }
        }
    }

    // MARK: - Actions

    private func animatedQuit(pid: pid_t, force: Bool = false) {
        _ = withAnimation(.quitSpring) {
            quittingPIDs.insert(pid)
        }
        // Delay so the swipe animation plays out smoothly before the process
        // terminates and system resources shift.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            model.quit(pid: pid, force: force)
        }
    }

    @ViewBuilder
    private func inlineChromeTabsOverview(_ theme: Theme) -> some View {
        let tabs = model.monitor.chromeTabs
        let attributions = model.monitor.tabAttributions

        let isBlankOrNewTab = { (t: ChromeTab) -> Bool in
            let title = t.cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let url = t.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return title == "new tab" || title.isEmpty || url.hasPrefix("chrome://newtab") || url == "about:blank"
        }

        // Prefer real content tabs; only fall back to blank tabs if the user has fewer than 5 real tabs
        let realTabs = tabs.filter { !isBlankOrNewTab($0) }
        let pool = realTabs.count >= 5 ? realTabs : (realTabs + tabs.filter(isBlankOrNewTab))

        let sorted = pool.sorted { a, b in
            let aBytes = attributions[a.id]?.totalBytes ?? 0
            let bBytes = attributions[b.id]?.totalBytes ?? 0
            if aBytes > 0 && bBytes > 0 { return aBytes > bBytes }
            if (aBytes > 0) != (bBytes > 0) { return aBytes > 0 }

            let aIsNew = isBlankOrNewTab(a)
            let bIsNew = isBlankOrNewTab(b)
            if aIsNew != bIsNew { return bIsNew }

            // Active tabs are frontmost in user focus
            if a.isActive != b.isActive { return a.isActive }

            if a.windowIndex != b.windowIndex {
                return a.windowIndex < b.windowIndex
            }
            return a.tabIndex < b.tabIndex
        }
        let top5 = Array(sorted.prefix(5))

        VStack(alignment: .leading, spacing: 3) {
            if tabs.isEmpty {
                Text("Reading open tabs…")
                    .font(Fonts.monoSmall)
                    .foregroundStyle(theme.hint)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 4)
            } else {
                HStack {
                    Text("Top 5 Chrome tabs")
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.textDim)
                    Spacer()
                }
                .padding(.horizontal, Metrics.rowSidePadding)
                .padding(.top, 2)

                ForEach(top5) { tab in
                    let bytes = attributions[tab.id]?.totalBytes ?? 0

                    HStack(spacing: 8) {
                        Text(tab.cleanedTitle)
                            .font(Fonts.body)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(theme.textPrimary)

                        Spacer()

                        Text(bytes > 0 ? String(format: "%.0f MB", Double(bytes) / 1e6) : "—")
                            .font(Fonts.monoSmall)
                            .foregroundStyle(bytes > 0 ? theme.textSecondary : theme.hint)

                    }
                    .padding(.horizontal, Metrics.rowSidePadding)
                    .padding(.vertical, 2)
                }

                if tabs.count > 5 {
                    Button {
                        model.query = "/tabs"
                    } label: {
                        HStack {
                            Text("View all \(tabs.count) tabs →")
                                .font(Fonts.monoSmall)
                                .foregroundStyle(theme.accent)
                            Spacer()
                        }
                        .padding(.horizontal, Metrics.rowSidePadding)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
        .background(theme.trackBackground.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, Metrics.rowSidePadding)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
