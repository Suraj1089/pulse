import SwiftUI

/// Minimalist footer with Settings and Quit All actions.
struct ModernFooterView: View {
    @Environment(\.colorScheme) private var scheme
    var onSettings: () -> Void = {}
    var onQuitAll: () -> Void = {}

    var body: some View {
        let theme = Theme(scheme: scheme)

        HStack {
            Button(action: onSettings) {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11.5))
                    Text("Settings")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onQuitAll) {
                HStack(spacing: 6) {
                    Text("Quit All")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.textSecondary)

                    HStack(spacing: 2) {
                        Text("⌥")
                        Text("⌘")
                        Text("Q")
                    }
                    .font(Fonts.monoTiny)
                    .foregroundStyle(theme.hint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.pillBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.pillBorder, lineWidth: 0.8))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .frame(height: Metrics.footerHeight)
    }
}
