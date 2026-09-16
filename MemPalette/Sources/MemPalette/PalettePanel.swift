import AppKit
import SwiftUI

/// Borderless, non-activating floating panel hosting `CommandPaletteView`.
/// Per the 1g handoff notes: "NSPanel, non-activating, .floating level, 13px
/// radius, no titlebar... Loses focus → closes."
final class PalettePanel: NSPanel {
    init(model: PaletteViewModel, onEscape: @escaping () -> Void, onHeightChange: @escaping (CGFloat) -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: Metrics.windowMinHeight),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: CommandPaletteView(model: model, onEscape: onEscape, onHeightChange: onHeightChange))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
