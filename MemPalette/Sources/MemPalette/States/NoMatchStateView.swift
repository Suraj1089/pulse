import SwiftUI

/// Not part of the handoff (every artboard hardcodes a matching query) but
/// needed once the search field is live: shown for a query that doesn't
/// match "slow", "memory"/"ram", "close" or "chrome".
struct NoMatchStateView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack {
            Spacer()
            Text("No matching commands")
                .font(Fonts.body)
                .foregroundStyle(theme.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
