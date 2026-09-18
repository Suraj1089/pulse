import SwiftUI

/// A compact, read-only list of Chrome tabs. Stable Chrome does not expose a
/// trustworthy per-tab physical-memory API to another macOS app, so Pulse
/// deliberately avoids inventing per-tab totals.
struct ChromeTabsStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel

    private var chromeApp: RunningAppUsage? {
        model.monitor.topApps.first { $0.bundleIdentifier == ChromeTabsBridge.bundleIdentifier }
    }

    private var tabs: [ChromeTab] {
        model.monitor.chromeTabs
    }

    private func isBlankOrNewTab(_ t: ChromeTab) -> Bool {
        let title = t.cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let url = t.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title == "new tab" || title.isEmpty || url.hasPrefix("chrome://newtab") || url == "about:blank"
    }

    /// Active tabs first, with New Tab last, then normal tab-strip order.
    private var sortedTabs: [ChromeTab] {
        tabs.sorted { a, b in
            let aIsNew = isBlankOrNewTab(a)
            let bIsNew = isBlankOrNewTab(b)
            if aIsNew != bIsNew { return bIsNew }

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

            memoryAvailabilityNote(theme)
                .padding(.horizontal, Metrics.rowSidePadding)
                .padding(.bottom, 10)

            SectionHeader(title: "Open tabs")
            .padding(.bottom, 4)

            VStack(spacing: 1) {
                ForEach(Array(sortedTabs.prefix(5))) { tab in
                    tabRow(tab: tab, theme: theme)
                }
            }

            if tabs.count > 5 {
                HStack {
                    Text("+ \(tabs.count - 5) more tabs")
                        .font(Fonts.monoTiny)
                        .foregroundStyle(theme.hint)
                    Spacer()
                }
                .padding(.horizontal, Metrics.rowSidePadding)
                .padding(.top, 4)
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
    private func memoryAvailabilityNote(_ theme: Theme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textDim)
            Text("Exact tab memory: Chrome Task Manager")
                .font(Fonts.monoTiny)
                .foregroundStyle(theme.textDim)
            Spacer(minLength: 0)
            Text("⇧ esc")
                .font(Fonts.monoTiny)
                .foregroundStyle(theme.accent)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(theme.trackBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Tab Row

    @ViewBuilder
    private func tabRow(tab: ChromeTab, theme: Theme) -> some View {
        HStack(spacing: 8) {
            Text(tab.cleanedTitle)
                .font(Fonts.body)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Unavailable")
                .font(Fonts.monoTiny)
                .foregroundStyle(theme.hint)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.rowSidePadding)
        .frame(height: 42)
        .background(theme.rowSelected.opacity(0.35), in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
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
