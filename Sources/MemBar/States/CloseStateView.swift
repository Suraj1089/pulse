import SwiftUI

/// State D — query "close" / "what can I close": real background apps
/// (not the one currently frontmost), each with a real idle duration where
/// we have one and an always-visible Quit button that actually quits it.
struct CloseStateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel
    @State private var selectedApp = 0

    private var candidates: [AppUsage] {
        model.monitor.topApps
            .filter { !$0.isFrontmost }
            .prefix(4)
            .map { app -> AppUsage in
                var reason: String?
                if let idleSince = app.idleSince, Date().timeIntervalSince(idleSince) >= 5 * 60 {
                    reason = Formatters.idleDuration(since: idleSince)
                }
                return AppUsage(app: app, reason: reason)
            }
    }

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Apps you may want to close").padding(.top, 8).padding(.bottom, 6)

            if candidates.isEmpty {
                Text("Nothing else running right now.")
                    .font(Fonts.body)
                    .foregroundStyle(theme.textDim)
                    .padding(.horizontal, Metrics.rowSidePadding)
                    .frame(height: Metrics.rowHeight, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, app in
                        AppListItem(
                            app: app,
                            isSelected: selectedApp == index,
                            quitMode: .always,
                            onHover: { hovering in
                                if hovering { selectedApp = index }
                            },
                            onQuit: { model.quit(pid: app.id) }
                        )
                    }
                }
            }

            if ChromeTabsBridge.isRunning {
                SectionHeader(title: "Browser tabs").padding(.top, 18).padding(.bottom, 6)
                HStack(spacing: 10) {
                    Text("C")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 19, height: 19)
                        .background(Color(oklch: 0.62, 0.12, 250), in: RoundedRectangle(cornerRadius: 5))
                    Text("Review open Chrome tabs")
                        .font(Fonts.body)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.query = "chrome"
                    } label: {
                        Text("Review & close")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textMuted)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Metrics.rowSidePadding)
                .frame(height: Metrics.rowHeightWithReason - 6)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 10)
        .onAppear { selectedApp = 0 }
    }
}
