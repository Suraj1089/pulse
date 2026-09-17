import SwiftUI

/// The Pulse waveform mark, rendered as a template image for the menu bar.
struct MenuBarIconView: View {
    let level: PressureLevel
    let usedFraction: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(Color.primary.opacity(0.12))

            PulseWaveformShape()
                .stroke(Color.primary.opacity(0.28), style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                ))
                .padding(.horizontal, 2.5)

            PulseWaveformShape()
                .trim(from: 0, to: max(0, min(1, usedFraction)))
                .stroke(Color.primary, style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                ))
                .padding(.horizontal, 2.5)
        }
        .frame(width: 18, height: 18)
    }

    private var lineWidth: CGFloat {
        switch level {
        case .low: return 1.8
        case .medium: return 2.1
        case .high: return 2.4
        }
    }
}

struct PulseWaveformShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let amplitude = rect.height * 0.34

        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.28, y: midY),
            control1: CGPoint(x: rect.width * 0.08, y: midY),
            control2: CGPoint(x: rect.width * 0.16, y: midY)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.5, y: midY),
            control1: CGPoint(x: rect.width * 0.34, y: midY),
            control2: CGPoint(x: rect.width * 0.38, y: midY - amplitude)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.72, y: midY),
            control1: CGPoint(x: rect.width * 0.62, y: midY + amplitude),
            control2: CGPoint(x: rect.width * 0.66, y: midY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: midY),
            control1: CGPoint(x: rect.width * 0.82, y: midY),
            control2: CGPoint(x: rect.width * 0.9, y: midY)
        )
        return path
    }
}
