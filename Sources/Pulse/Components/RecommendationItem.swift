import SwiftUI

/// Row with an arrow, a recommendation title, an optional pressure-reduction hint,
/// and a "↵" badge on the currently selected row.
struct RecommendationItem: View {
    @Environment(\.colorScheme) private var scheme
    let action: RecommendedAction
    var isSelected: Bool = false
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        let theme = Theme(scheme: scheme)
        HStack(spacing: 10) {
            Text("→")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? theme.textMuted : theme.hint)

            Text(action.title)
                .font(Fonts.body)
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textPrimary.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let detail = action.detail {
                Text(detail)
                    .font(Fonts.monoSmall)
                    .foregroundStyle(theme.textDim)
            }

            if isSelected {
                Text("↵")
                    .font(Fonts.monoSmall)
                    .foregroundStyle(theme.hint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
            }
        }
        .padding(.horizontal, Metrics.rowSidePadding)
        .frame(height: Metrics.rowHeight)
        .background(isSelected ? theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: action.perform)
        .animation(.linear(duration: 0.14), value: isSelected)
    }
}
