import SwiftUI

/// "Allocation blocks" — the 1a concept picked for the menu bar icon: four
/// cells, one free at rest. Per the design notes ("the filled ratio can
/// animate with pressure — three filled at HIGH"), the filled count tracks
/// the current pressure level. Solid shapes, no hairlines below 18px.
struct MenuBarIconView: View {
    let level: PressureLevel

    private var filledCount: Int {
        switch level {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    var body: some View {
        let cell: CGFloat = 7
        let gap: CGFloat = 1.5
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                block(0 < filledCount, size: cell)
                block(1 < filledCount, size: cell)
            }
            HStack(spacing: gap) {
                block(2 < filledCount, size: cell)
                block(3 < filledCount, size: cell)
            }
        }
        .frame(width: 16, height: 16)
        .animation(.easeOut(duration: 0.3), value: filledCount)
    }

    @ViewBuilder
    private func block(_ filled: Bool, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.6)
            .fill(filled ? Color.primary : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 1.6).strokeBorder(Color.primary, lineWidth: filled ? 0 : 1.3))
            .frame(width: size, height: size)
    }
}
