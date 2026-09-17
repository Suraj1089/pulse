import SwiftUI

/// Premium header matching the minimalist design:
/// Brand badge icon, "Pulse", "Find. Free. Focus.", RAM fraction & slim progress bar.
struct PulseBrandHeader: View {
    @Environment(\.colorScheme) private var scheme
    let usedGB: Double
    let totalGB: Double
    let level: PressureLevel

    var body: some View {
        let theme = Theme(scheme: scheme)
        let fraction = totalGB > 0 ? min(1.0, max(0.04, usedGB / totalGB)) : 0.5

        HStack(alignment: .center, spacing: 10) {
            // Stylish App Brand Badge
            ZStack {
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: scheme == .dark
                                ? [Color(white: 0.24), Color(white: 0.12)]
                                : [Color(white: 0.18), Color(white: 0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                    )

                PulseWaveformShape()
                    .stroke(theme.blueAccent.opacity(0.28), style: StrokeStyle(
                        lineWidth: 2.5,
                        lineCap: .round,
                        lineJoin: .round
                    ))
                    .padding(.horizontal, 5)

                PulseWaveformShape()
                    .trim(from: 0, to: fraction)
                    .stroke(theme.blueAccent, style: StrokeStyle(
                        lineWidth: 2.5,
                        lineCap: .round,
                        lineJoin: .round
                    ))
                    .padding(.horizontal, 5)
            }
            .frame(width: 32, height: 32)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 1) {
                Text("Pulse")
                    .font(Fonts.title)
                    .foregroundStyle(theme.textPrimary)

                Text("Find. Free. Focus.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textDim)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Text(String(format: "%.1f GB / %.0f GB", usedGB, totalGB))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)

                // Slim capsule progress bar
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.trackBackground)
                        .frame(width: 84, height: 5)

                    Capsule()
                        .fill(
                            level == .high
                                ? Color(oklch: 0.62, 0.16, 25)
                                : (level == .medium ? Color(oklch: 0.72, 0.14, 85) : theme.blueAccent)
                        )
                        .frame(width: max(4, 84 * CGFloat(fraction)), height: 5)
                }
            }
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}
