import SwiftUI

/// 30-bar pressure history (mp-rise animation on data change, hover dims the
/// rest and updates the readout — mirrors the `bars`/`onEnter`/`clearBar`
/// logic in the handoff script).
struct PressureHistoryChart: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Pressure · last 30 min")
                    .font(Fonts.sectionHeader).tracking(1.1).foregroundStyle(theme.sectionHeader)
                Spacer()
                Text(model.barReadout(atFallback: model.hoveredBar))
                    .font(Fonts.monoSmall).foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, Metrics.rowSidePadding)

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(model.samples.enumerated()), id: \.offset) { index, value in
                    let level = PressureLevel(percent: value)
                    let dimmed = model.hoveredBar != nil && model.hoveredBar != index
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level.chartColor)
                        .brightness(model.hoveredBar == index ? 0.12 : 0)
                        .opacity(dimmed ? 0.38 : 1)
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(10 + value / 100 * 56))
                        .onHover { hovering in
                            model.hoveredBar = hovering ? index : (model.hoveredBar == index ? nil : model.hoveredBar)
                        }
                        .animation(.easeOut(duration: 0.55), value: value)
                }
            }
            .frame(height: 78, alignment: .bottom)
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 12)
            .onHover { hovering in if !hovering { model.hoveredBar = nil } }

            HStack {
                Text("−30m")
                Spacer()
                Text("−15m")
                Spacer()
                Text("now")
            }
            .font(Fonts.monoTiny)
            .foregroundStyle(theme.hint)
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 6)
        }
    }
}

/// Stacked composition bar + legend (App memory / Wired / Compressed / Cached
/// / Free), hover-linked between the bar segments and the legend chips.
struct CompositionChart: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PaletteViewModel

    private func setHover(_ index: Int, _ hovering: Bool) {
        model.hoveredSegment = hovering ? index : (model.hoveredSegment == index ? nil : model.hoveredSegment)
    }

    var body: some View {
        let theme = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Composition · 16 GB")
                    .font(Fonts.sectionHeader).tracking(1.1).foregroundStyle(theme.sectionHeader)
                Spacer()
                Text(model.segReadout)
                    .font(Fonts.monoSmall).foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 20)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(MockData.compositionSegments.enumerated()), id: \.element.id) { index, seg in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(seg.color)
                            .opacity(model.hoveredSegment == nil || model.hoveredSegment == index ? 1 : 0.35)
                            .scaleEffect(y: model.hoveredSegment == index ? 1.22 : 1, anchor: .center)
                            .frame(width: max(1, geo.size.width * CGFloat(seg.pct / 100)))
                            .onHover { setHover(index, $0) }
                            .animation(.easeOut(duration: 0.18), value: model.hoveredSegment)
                    }
                }
            }
            .frame(height: 22)
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 10)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Array(MockData.compositionSegments.enumerated()), id: \.element.id) { index, seg in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(seg.color)
                            .opacity(model.hoveredSegment == nil || model.hoveredSegment == index ? 1 : 0.35)
                            .frame(width: 7, height: 7)
                        Text(seg.label).font(.system(size: 11.5)).foregroundStyle(theme.textMuted)
                        Text(seg.gbText).font(Fonts.monoSmall).foregroundStyle(theme.textDim)
                    }
                    .onHover { setHover(index, $0) }
                }
            }
            .padding(.horizontal, Metrics.rowSidePadding)
            .padding(.top, 12)
        }
    }
}
