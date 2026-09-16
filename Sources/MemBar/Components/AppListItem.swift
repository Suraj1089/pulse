import SwiftUI

/// Row with app icon, name, memory usage and an optional Quit button — used
/// across State A, State D and the memory-chart top-users list, which each
/// show the Quit button under different rules (never / only when selected /
/// always), per the handoff markup.
struct AppListItem: View {
    @Environment(\.colorScheme) private var scheme
    let app: AppUsage
    var isSelected: Bool = false
    var quitMode: QuitMode = .never
    var showProgress: Bool = false
    var onHover: (Bool) -> Void = { _ in }
    var onQuit: () -> Void = {}

    enum QuitMode { case never, onSelected, always }

    var body: some View {
        let theme = Theme(scheme: scheme)
        let hasReason = app.reason != nil
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Text(app.initial)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(app.color, in: RoundedRectangle(cornerRadius: 5))
            }

            if let reason = app.reason {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(Fonts.body).foregroundStyle(theme.textPrimary).lineLimit(1)
                    Text(reason).font(Fonts.monoSmall).foregroundStyle(theme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(app.name)
                    .font(Fonts.body)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showProgress {
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.trackBackground).frame(width: 120, height: 5)
                    Capsule().fill(app.color).frame(width: max(2, 120 * CGFloat(app.pct / 100)), height: 5)
                }
                .animation(.easeOut(duration: 0.5), value: app.pct)
            }

            Text(app.memText)
                .font(Fonts.mono)
                .foregroundStyle(theme.textDim)
                .frame(width: showProgress ? 52 : nil, alignment: .trailing)

            let showQuit = quitMode == .always || (quitMode == .onSelected && isSelected)
            if showQuit {
                QuitButton(filled: hasReason, action: onQuit)
            }
        }
        .padding(.horizontal, Metrics.rowSidePadding)
        .frame(height: hasReason ? Metrics.rowHeightWithReason : Metrics.rowHeight)
        .background(isSelected ? theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .animation(.linear(duration: 0.14), value: isSelected)
    }
}
