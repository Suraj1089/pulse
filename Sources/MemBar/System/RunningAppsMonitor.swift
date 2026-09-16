import AppKit

/// A regular (Dock-visible) app plus every helper/renderer process that
/// shares its bundle path — e.g. Chrome's many `Google Chrome Helper`
/// processes are folded into one "Chrome" entry, matching how Activity
/// Monitor groups multi-process apps.
struct RunningAppUsage: Identifiable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let footprintBytes: UInt64
    let processCount: Int
    let isFrontmost: Bool
    /// When this app was last frontmost (or when we started observing, if
    /// it never has been) — `nil` while it's the active app. We only ever
    /// know idle time *since this process started watching*, so a freshly
    /// launched monitor won't yet know an app has been idle for hours.
    let idleSince: Date?

    var footprintGB: Double { Double(footprintBytes) / 1_000_000_000 }

    var initial: String { String(name.first ?? "?").uppercased() }
}

/// Aggregates `NSWorkspace.runningApplications` with real per-process memory
/// from `ProcessScanner`, and tracks how recently each app was frontmost via
/// `NSWorkspace` activation notifications so we can report genuine (if
/// session-bounded) idle durations.
final class RunningAppsMonitor {
    private var lastActivation: [pid_t: Date] = [:]
    private var monitorStartDate = Date()
    private var activationObserver: NSObjectProtocol?

    func start() {
        monitorStartDate = Date()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.lastActivation[app.processIdentifier] = Date()
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    /// Must be called on the main thread — it reads `NSWorkspace`/
    /// `NSRunningApplication`, neither of which is documented as safe off
    /// it (unlike `processes`, which is pure libproc and fine from
    /// anywhere). Callers should fetch `processes` via `ProcessScanner`
    /// on a background queue and hop back to main before calling this.
    func aggregate(processes: [ProcessSample]) -> [RunningAppUsage] {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        let usages: [RunningAppUsage] = regularApps.compactMap { app in
            let pid = app.processIdentifier
            let bundlePrefix = app.bundleURL.map { $0.path + "/" }
            let matched = processes.filter { proc in
                proc.pid == pid || (bundlePrefix != nil && proc.executablePath?.hasPrefix(bundlePrefix!) == true)
            }
            guard !matched.isEmpty else { return nil }

            let totalBytes = matched.reduce(UInt64(0)) { $0 + $1.physFootprintBytes }
            let isFrontmost = pid == frontmostPID
            return RunningAppUsage(
                pid: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon,
                footprintBytes: totalBytes,
                processCount: matched.count,
                isFrontmost: isFrontmost,
                idleSince: isFrontmost ? nil : (lastActivation[pid] ?? monitorStartDate)
            )
        }

        return usages.sorted { $0.footprintBytes > $1.footprintBytes }
    }

    func terminate(pid: pid_t, force: Bool) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else { return }
        if force {
            app.forceTerminate()
        } else {
            app.terminate()
        }
    }
}
