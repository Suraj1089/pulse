import SwiftUI

/// State D — query "close" / "what can I close": apps worth closing (each
/// with a reason line and an always-visible Quit button), plus a stubbed
/// browser-tabs section (1f).
struct CloseStateView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var selectedApp = 0

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Apps you may want to close").padding(.top, 8).padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(Array(MockData.closeApps.enumerated()), id: \.element.id) { index, app in
                    AppListItem(app: app, isSelected: selectedApp == index, quitMode: .always, onHover: { hovering in
                        if hovering { selectedApp = index }
                    })
                }
            }

            SectionHeader(title: "Browser tabs").padding(.top, 18).padding(.bottom, 6)

            HStack(spacing: 10) {
                Text("C")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(Color(oklch: 0.62, 0.12, 250), in: RoundedRectangle(cornerRadius: 5))
                Text("4 inactive Chrome tabs")
                    .font(Fonts.body)
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("~2.3 GB").font(Fonts.mono).foregroundStyle(theme.textDim)
                Text("Review & close")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .frame(height: Metrics.rowHeightWithReason - 6)

            Text("v2 — stubbed, no tab data in v1")
                .font(Fonts.monoTiny)
                .foregroundStyle(theme.hint.opacity(0.85))
                .padding(.horizontal, Metrics.rowSidePadding)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 10)
        .onAppear { selectedApp = 0 }
    }
}
