import AppKit
import Combine
import SwiftUI
@preconcurrency import UserNotifications

/// Owns the status item, the palette panel, and the click / hotkey / focus-loss
/// plumbing described in 1a/1g: click opens the palette anchored under the
/// icon (right edge aligned, 6px below the menu bar); ⌘⌥M opens it screen-
/// centered instead; losing focus closes it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PalettePanel?
    private let model = PaletteViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var hotKeyMonitor: Any?
    private var hasPostedHighMemoryAlert = false
    private var lastMemoryAlertDate: Date?

    private var supportsUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if supportsUserNotifications {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        model.start()

        seedStatusItemPositionOnFirstLaunch()
        setupStatusItem()

        model.monitor.$memory
            .combineLatest(model.monitor.$pressureLevel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                self?.evaluateMemoryAlert()
            }
            .store(in: &cancellables)

        model.monitor.$tabAttributions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluateMemoryAlert() }
            .store(in: &cancellables)

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

    private static let statusItemAutosaveName = "PulseStatusItem"

    /// macOS remembers where a status item sits under
    /// `NSStatusItem Preferred Position <autosaveName>` — a point offset measured
    /// from the right edge of the menu bar, so a *small* value sits close to
    /// Control Center. Without a seed the very first launch drops Pulse into the
    /// leftmost slot, which is exactly where a crowded bar (or the notch) swallows
    /// it. We write the slot once, before the item exists, and never again, so a
    /// ⌘-drag by the user is still what wins from then on.
    private func seedStatusItemPositionOnFirstLaunch() {
        let defaults = UserDefaults.standard
        let didSeedKey = "PulseDidSeedStatusItemPosition"
        guard !defaults.bool(forKey: didSeedKey) else { return }

        let name = Self.statusItemAutosaveName
        defaults.set(8.0, forKey: "NSStatusItem Preferred Position \(name)")
        defaults.set(true, forKey: "NSStatusItem Visible \(name)")
        defaults.set(true, forKey: didSeedKey)
    }

    private func setupStatusItem() {
        // Remove any existing item first so we don't leak it when called
        // during a screen-change rebuild.
        if statusItem != nil {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.statusItemAutosaveName
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
    private var lastRenderedUsedFraction: Double?

    private func updateIcon() {
        let usedFraction = model.monitor.memory?.usedFraction ?? 0
        guard model.level != lastRenderedLevel || usedFraction != lastRenderedUsedFraction else { return }
        lastRenderedLevel = model.level
        lastRenderedUsedFraction = usedFraction

        let renderer = ImageRenderer(content: MenuBarIconView(
            level: model.level,
            usedFraction: usedFraction
        ))
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

    private func evaluateMemoryAlert() {
        guard supportsUserNotifications else { return }
        guard let snapshot = model.monitor.memory else { return }
        let usedFraction = snapshot.usedFraction

        if usedFraction < 0.80 {
            hasPostedHighMemoryAlert = false
            return
        }

        guard usedFraction >= 0.85,
              !hasPostedHighMemoryAlert,
              lastMemoryAlertDate.map({ Date().timeIntervalSince($0) >= 30 * 60 }) ?? true else { return }

        hasPostedHighMemoryAlert = true
        lastMemoryAlertDate = Date()

        let content = UNMutableNotificationContent()
        content.title = "Pulse: memory is almost full"
        if let recommendation = model.monitor.chromeMemoryRecommendation {
            let minutes = max(15, Int(Date().timeIntervalSince(recommendation.idleSince) / 60))
            content.body = "\(recommendation.tab.cleanedTitle) has been idle for \(minutes)m and uses about \(Int(recommendation.attribution.totalMB)) MB. Close it to free memory."
        } else if let app = model.monitor.topApps.first {
            let footprint = String(format: "%.1f", app.footprintGB)
            content.body = "Memory is \(Int(usedFraction * 100))% full. Consider quitting \(app.name), using about \(footprint) GB."
        } else {
            content.body = "Memory is \(Int(usedFraction * 100))% full. Consider quitting unused apps to free memory."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "pulse-high-memory",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.openPanel(centered: false)
            completionHandler()
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
        let isButtonVisible = statusItem.button?.window != nil && (statusItem.button?.window?.frame.minX ?? 0) > 0

        if centered || !isButtonVisible, let screen = NSScreen.main {
            let frame = screen.visibleFrame
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
