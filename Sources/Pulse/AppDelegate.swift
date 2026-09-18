import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
@preconcurrency import UserNotifications

/// Owns the status item, the palette panel, and the click / hotkey / focus-loss
/// plumbing described in 1a/1g: click opens the palette anchored under the
/// icon (right edge aligned, 6px below the menu bar); ⌘⌥P opens it screen-
/// centered from anywhere; losing focus closes it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PalettePanel?
    private let model = PaletteViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var registeredHotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
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

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceAppsDidChange),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceAppsDidChange),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        registerGlobalOpenHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let registeredHotKey { UnregisterEventHotKey(registeredHotKey) }
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
    /// it. We repair a missing preference from older builds, but never overwrite
    /// a slot that macOS has already persisted after a user ⌘-drag.
    private func seedStatusItemPositionOnFirstLaunch() {
        let defaults = UserDefaults.standard
        let didSeedKey = "PulseDidSeedStatusItemPosition"
        let name = Self.statusItemAutosaveName
        let positionKey = "NSStatusItem Preferred Position \(name)"
        guard !defaults.bool(forKey: didSeedKey) || defaults.object(forKey: positionKey) == nil else { return }

        defaults.set(8.0, forKey: positionKey)
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

    /// A newly launched menu-bar app can make macOS reflow extras. Rebuild only
    /// if Pulse has actually been evicted; a visible user-positioned item stays
    /// untouched.
    @objc private func workspaceAppsDidChange(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.restoreStatusItemIfNeeded()
        }
    }

    private func restoreStatusItemIfNeeded() {
        guard statusItem.button?.window == nil else { return }
        seedStatusItemPositionOnFirstLaunch()
        setupStatusItem()
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
            content.body = "Memory is \(Int(usedFraction * 100))% full. Consider quitting \(app.name) to reduce memory pressure."
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

    // MARK: - Global hotkey

    /// A registered Carbon hotkey is delivered by macOS even while another app
    /// is frontmost. Unlike an NSEvent global monitor, it does not require the
    /// user to grant Pulse Accessibility or Input Monitoring permission.
    private func registerGlobalOpenHotKey() {
        let hotKeyID = EventHotKeyID(signature: 0x50756C73, id: 1) // "Puls"
        let eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.openPanel(centered: true) }
                return noErr
            },
            1,
            [eventType],
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )

        guard handlerStatus == noErr else { return }

        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_P),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        if registerStatus != noErr, let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }
    }
}
