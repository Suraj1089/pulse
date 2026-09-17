import AppKit
import Combine
import SwiftUI

/// Owns the status item, the palette panel, and the click / hotkey / focus-loss
/// plumbing described in 1a/1g: click opens the palette anchored under the
/// icon (right edge aligned, 6px below the menu bar); ⌘⌥M opens it screen-
/// centered instead; losing focus closes it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PalettePanel?
    private let model = PaletteViewModel()
    private var cancellable: AnyCancellable?
    private var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        cancellable = model.monitor.$pressureLevel
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }

        // Recreate the status item whenever the screen configuration changes
        // (monitor connect/disconnect). Without this the item can vanish when
        // an external display is unplugged, because macOS doesn't always
        // migrate items back to the built-in bar automatically.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        registerHotKeyMonitor()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return true
    }

    // MARK: - Status item

    private func setupStatusItem() {
        // Remove any existing item first so we don't leak it when called
        // during a screen-change rebuild.
        if statusItem != nil {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        updateIcon()
    }

    @objc private func screensDidChange(_ notification: Notification) {
        // Give macOS ~0.5 s to finish rearranging the bar before rebuilding,
        // otherwise the new item can land on the wrong bar in the brief window
        // between old and new screen layout settling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setupStatusItem()
        }
    }

    private var lastRenderedLevel: PressureLevel?

    private func updateIcon() {
        guard model.level != lastRenderedLevel else { return }
        lastRenderedLevel = model.level

        let renderer = ImageRenderer(content: MenuBarIconView(level: model.level))
        renderer.scale = 2

        if let rendered = renderer.nsImage {
            rendered.isTemplate = true
            statusItem.button?.image = rendered
        } else {
            let fallback = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Memory") ?? NSImage()
            fallback.isTemplate = true
            statusItem.button?.image = fallback
        }
    }

    // MARK: - Panel

    private func ensurePanel() -> PalettePanel {
        if let panel { return panel }
        let p = PalettePanel(
            model: model,
            onEscape: { [weak self] in self?.closePanel() }
        )
        p.delegate = self
        self.panel = p
        return p
    }

    @objc private func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            openPanel(centered: false)
        }
    }

    private func openPanel(centered: Bool) {
        let p = ensurePanel()
        let panelHeight: CGFloat = 490
        if centered, let screen = NSScreen.main {
            let frame = screen.frame
            let origin = NSPoint(
                x: frame.midX - Metrics.windowWidth / 2,
                y: frame.midY - panelHeight / 2
            )
            p.setFrameOrigin(origin)
        } else if let button = statusItem.button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var targetX = buttonFrame.midX - Metrics.windowWidth / 2
            if let screen = buttonWindow.screen {
                let maxX = screen.visibleFrame.maxX - Metrics.windowWidth - 8
                let minX = screen.visibleFrame.minX + 8
                targetX = min(max(targetX, minX), maxX)
            }
            let origin = NSPoint(
                x: targetX,
                y: buttonFrame.minY - 8 - panelHeight
            )
            p.setFrameOrigin(origin)
        }
        p.makeKeyAndOrderFront(nil)
        model.setPaletteVisible(true)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model.setPaletteVisible(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    // MARK: - Hotkey

    /// Best-effort: `addGlobalMonitorForEvents` only fires while the app has
    /// Accessibility/Input-Monitoring permission; without it, ⌘⌥M simply won't
    /// register and the status-item click remains the primary way in.
    private func registerHotKeyMonitor() {
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains([.command, .option]) else { return }
            let char = event.charactersIgnoringModifiers?.lowercased()
            guard char == "p" || char == "m" else { return }
            DispatchQueue.main.async { self.openPanel(centered: true) }
        }
    }
}
