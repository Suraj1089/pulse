import SwiftUI

/// Compact horizontal strip: TOTAL / USED / AVAIL, pinned just below the
/// search field. AVAIL = free pages + cached (file-backed reclaimable pages),
/// which is what macOS can actually hand to a new allocation on demand —
/// far more informative than raw "free pages" alone.
struct MemoryStatsBar: View {
    @Environment(\.colorScheme) private var scheme
    let totalGB: Double
    let usedGB: Double
    let availableGB: Double
    let level: PressureLevel

    var body: some View {
        let theme = Theme(scheme: scheme)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                statCell(label: "TOTAL", value: formatted(totalGB), color: theme.textMuted, theme: theme)
                divider(theme: theme)
                statCell(label: "USED",  value: formatted(usedGB),  color: level.chartColor, theme: theme)
                divider(theme: theme)
                statCell(label: "AVAIL", value: formatted(availableGB), color: theme.textMuted, theme: theme)
            }
            .padding(.vertical, 7)

            Rectangle().fill(theme.borderSoft).frame(height: 1)
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func statCell(label: String, value: String, color: Color, theme: Theme) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(theme.sectionHeader)

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                Text("GB")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func divider(theme: Theme) -> some View {
        Rectangle()
            .fill(theme.borderSoft)
            .frame(width: 1, height: 26)
    }

    private func formatted(_ gb: Double) -> String {
        String(format: "%.2f", gb)
    }
}
