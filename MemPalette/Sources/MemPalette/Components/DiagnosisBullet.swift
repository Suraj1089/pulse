import SwiftUI

struct DiagnosisBullet: View {
    @Environment(\.colorScheme) private var scheme
    let point: DiagnosisPoint

    var body: some View {
        let theme = Theme(scheme: scheme)
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(point.emphasized ? Color(oklch: 0.7, 0.15, 25) : theme.textDim.opacity(0.85))
                .frame(width: 5, height: 5)
                .padding(.top, 5.5)

            Text(point.text)
                .font(Fonts.body)
                .foregroundStyle(point.dimmed ? theme.textMuted.opacity(0.75) : theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
