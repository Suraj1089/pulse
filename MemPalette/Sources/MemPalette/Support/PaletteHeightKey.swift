import SwiftUI

/// Reports the palette's natural rendered height (header + content + footer,
/// already capped by the body ScrollView's maxHeight) so the hosting NSPanel
/// can resize to fit — the "height grows with content to a 480px cap" rule
/// from the 1g handoff notes.
struct PaletteHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = Metrics.windowMinHeight
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
