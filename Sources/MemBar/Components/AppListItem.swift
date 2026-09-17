import SwiftUI

/// Premium minimalist app row matching the target UI:
/// 30x30 squircle app icon, 2-line title & subtitle (e.g. "12 tabs"),
/// formatted memory footprint, and a clean pill Quit button.
struct AppListItem: View {
    @Environment(\.colorScheme) private var scheme
    let app: AppUsage
    var isSelected: Bool = false
    var quitMode: QuitMode = .always
    var quitLabel: String = "Quit"
    var isDestructive: Bool = false
    var showProgress: Bool = false
    var hasExpandSlot: Bool = false
    var isExpandable: Bool = false
    var isExpanded: Bool = false
    var onToggleExpand: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onQuit: () -> Void = {}

    enum QuitMode { case never, onSelected, always }

    var body: some View {
        let theme = Theme(scheme: scheme)
        let subtitleText = app.reason ?? "Active"

        HStack(spacing: 10) {
            // App Icon
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Text(app.initial)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(app.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            // Name & Subtitle
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if isExpandable {
                        Button(action: onToggleExpand) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(theme.textDim)
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(subtitleText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Memory readout
            Text(app.memText)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .frame(minWidth: 54, alignment: .trailing)

            // Minimalist Quit / Force Quit Pill Button
            let showQuit = quitMode == .always || (quitMode == .onSelected && isSelected)
            if showQuit {
                Button(action: onQuit) {
                    Text(quitLabel)
                        .font(.system(size: isDestructive ? 10.5 : 11, weight: .medium))
                        .foregroundStyle(isDestructive ? Color(red: 1.0, green: 0.35, blue: 0.35) : theme.textPrimary)
                        .padding(.horizontal, isDestructive ? 7 : 0)
                        .frame(minWidth: 46)
                        .frame(height: 24)
                        .background(
                            isDestructive ? Color.red.opacity(0.14) : theme.pillBackground,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isDestructive ? Color.red.opacity(0.35) : theme.pillBorder, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: isDestructive ? 68 : 46)
            }
        }
        .padding(.horizontal, Metrics.rowSidePadding)
        .frame(height: Metrics.rowHeight)
        .background(isSelected ? theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
}
