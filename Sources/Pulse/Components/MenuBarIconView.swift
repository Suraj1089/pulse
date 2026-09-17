import SwiftUI

/// "Allocation blocks" — the 1a concept picked for the menu bar icon: four
/// cells, one free at rest. Per the design notes ("the filled ratio can
/// animate with pressure — three filled at HIGH"), the filled count tracks
/// the current pressure level. Solid shapes, no hairlines below 18px.
struct MenuBarIconView: View {
    let level: PressureLevel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(Color.primary.opacity(0.12))

            HStack(alignment: .bottom, spacing: 2) {
                Capsule()
                    .fill(barColor(for: 0))
                    .frame(width: 2.5, height: 6)
                Capsule()
                    .fill(barColor(for: 1))
                    .frame(width: 2.5, height: 9.5)
                Capsule()
                    .fill(barColor(for: 2))
                    .frame(width: 2.5, height: 13)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func barColor(for index: Int) -> Color {
        let activeBars = level == .high ? 3 : (level == .medium ? 2 : 1)
        if index < activeBars {
            switch level {
            case .high: return Color(red: 0.95, green: 0.25, blue: 0.25)
            case .medium: return Color(red: 0.95, green: 0.70, blue: 0.15)
            case .low: return Color(red: 0.12, green: 0.48, blue: 0.98)
            }
        } else {
            return Color.primary.opacity(0.25)
        }
    }
}
