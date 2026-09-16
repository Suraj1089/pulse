import SwiftUI

/// Pill‑shaped badge, LOW/MEDIUM/HIGH; pulses gently while HIGH (`mp-pulse` keyframe).
struct MemoryPressureBadge: View {
    @Environment(\.colorScheme) private var scheme
    let level: PressureLevel
    @State private var pulseDown = false

    var body: some View {
        Text(level.rawValue)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(level.badgeText(scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(level.badgeBackground(scheme), in: Capsule())
            .opacity(level == .high && pulseDown ? 0.55 : 1)
            .onAppear {
                guard level == .high else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulseDown = true
                }
            }
    }
}
