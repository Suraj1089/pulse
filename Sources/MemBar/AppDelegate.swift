import AppKit
import Combine
import SwiftUI

/// Owns the status item, the palette panel, and the click / hotkey / focus-loss
/// plumbing described in 1a/1g: click opens the palette anchored under the
/// icon (right edge aligned, 6px below the menu bar); ⌘⌥M opens it screen-
/// centered instead; losing focus closes it.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PalettePanel!
    private let model = PaletteViewModel()
    private var cancellable: AnyCancellable?
    private var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: 22)
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        updateIcon()

        panel = PalettePanel(
            model: model,
            onEscape: { [weak self] in self?.closePanel() },
            onHeightChange: { [weak self] height in self?.resizePanel(toContentHeight: height) }
        )
        panel.delegate = self

        cancellable = model.$samples
            .map { PressureLevel(percent: $0.last ?? 50) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in self?.updateIcon() }

        registerHotKeyMonitor()
    }

    private func updateIcon() {
        let renderer = ImageRenderer(content: MenuBarIconView(level: model.level))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        image.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePanel() {
        panel.isVisible ? closePanel() : openPanel(centered: false)
    }

    private func openPanel(centered: Bool) {
        if centered, let screen = NSScreen.main {
            let frame = screen.frame
            let origin = NSPoint(
                x: frame.midX - Metrics.windowWidth / 2,
                y: frame.midY - Metrics.windowMinHeight / 2
            )
            panel.setFrameOrigin(origin)
        } else if let button = statusItem.button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let origin = NSPoint(
                x: buttonFrame.maxX - Metrics.windowWidth,
                y: buttonFrame.minY - 6 - Metrics.windowMinHeight
            )
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel() {
        panel.orderOut(nil)
    }

    /// Grows/shrinks the panel to fit its content (400...480pt), keeping the
    /// top edge — where the search field sits — fixed on screen.
    private func resizePanel(toContentHeight height: CGFloat) {
        let clamped = min(max(height, Metrics.windowMinHeight), Metrics.windowMaxHeight)
        let old = panel.frame
        guard abs(old.height - clamped) > 0.5 else { return }
        let topY = old.maxY
        let newFrame = NSRect(x: old.minX, y: topY - clamped, width: old.width, height: clamped)
        panel.setFrame(newFrame, display: true, animate: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    /// Best-effort: `addGlobalMonitorForEvents` only fires while the app has
    /// Accessibility/Input-Monitoring permission; without it, ⌘⌥M simply won't
    /// register and the status-item click remains the primary way in.
    private func registerHotKeyMonitor() {
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains([.command, .option]),
                  event.charactersIgnoringModifiers?.lowercased() == "m" else { return }
            DispatchQueue.main.async { self.openPanel(centered: true) }
        }
    }
}
