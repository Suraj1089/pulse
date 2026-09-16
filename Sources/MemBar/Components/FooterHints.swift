import SwiftUI

/// 32px footer, right-aligned SF Mono key hints ("↑↓ navigate  ↵ select  esc close").
struct FooterHints: View {
    @Environment(\.colorScheme) private var scheme
    let items: [String]

    var body: some View {
        let theme = Theme(scheme: scheme)
        HStack(spacing: 14) {
            Spacer()
            ForEach(items, id: \.self) { item in
                Text(item).font(Fonts.monoTiny).foregroundStyle(theme.hint)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.footerHeight)
        .overlay(alignment: .top) { Rectangle().fill(theme.borderSoft).frame(height: 1) }
    }
}
