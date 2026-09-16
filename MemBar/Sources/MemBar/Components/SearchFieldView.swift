import SwiftUI

/// 54px header: magnifying glass, editable query (or faded placeholder), and
/// a "⌘K" hint that hides once there's a query. A hairline accent ring lights
/// up the header while a query is present, matching the `box-shadow: inset`
/// glow on the query artboards (1d/2a/2b).
struct SearchFieldView: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var query: String
    var showKeyHints: Bool
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        let theme = Theme(scheme: scheme)
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.searchIcon)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search or type a command…")
                        .font(Fonts.query)
                        .foregroundStyle(theme.placeholder)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(Fonts.query)
                    .foregroundStyle(theme.textPrimary)
                    .tint(theme.accent)
                    .focused(isFocused)
            }

            if query.isEmpty && showKeyHints {
                Text("⌘K")
                    .font(Fonts.monoSmall)
                    .foregroundStyle(theme.hint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.borderSoft).frame(height: 1)
        }
        .overlay {
            if !query.isEmpty {
                Rectangle().strokeBorder(theme.accent.opacity(0.28), lineWidth: 1)
            }
        }
        .animation(.linear(duration: 0.12), value: query.isEmpty)
    }
}
