import SwiftUI

/// 10.5pt SF Mono, uppercase, .11em tracking — used above every list in the palette.
struct SectionHeader: View {
    @Environment(\.colorScheme) private var scheme
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(Fonts.sectionHeader)
            .tracking(1.1)
            .foregroundStyle(Theme(scheme: scheme).sectionHeader)
            .padding(.horizontal, Metrics.rowSidePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
