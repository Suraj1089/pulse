import AppKit

/// A regular (Dock-visible) app plus every helper/renderer process that
/// shares its bundle path — e.g. Chrome's many `Google Chrome Helper`
/// processes are folded into one "Chrome" entry. App rows use resident
/// memory, while per-tab diagnostics retain process-footprint measurements.
struct RunningAppUsage: Identifiable {
    static let recommendedQuitIdleInterval: TimeInterval = 5 * 60 * 60

    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let residentBytes: UInt64
    let processCount: Int
    let isFrontmost: Bool
    /// When this app was last frontmost (or when we started observing, if
    /// it never has been) — `nil` while it's the active app. We only ever
    /// know idle time *since this process started watching*, so a freshly
    /// launched monitor won't yet know an app has been idle for hours.
    let idleSince: Date?

    var residentGB: Double { Double(residentBytes) / 1_073_741_824 }

    var residentDescription: String {
        guard processCount > 1 else { return "1 process" }
        return "\(processCount) processes"
    }

    var initial: String { String(name.first ?? "?").uppercased() }
}

/// Aggregates `NSWorkspace.runningApplications` with real per-process memory
/// from `ProcessScanner`, and tracks how recently each app was frontmost via
/// `NSWorkspace` activation notifications so we can report genuine (if
/// session-bounded) idle durations.
final class RunningAppsMonitor {
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.finder"
    ]

    private var idleSinceByPID: [pid_t: Date] = [:]
    private var firstSeenByPID: [pid_t: Date] = [:]
    private var iconCache: [pid_t: NSImage] = [:]
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.idleSinceByPID[app.processIdentifier] = nil
        }
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.idleSinceByPID[app.processIdentifier] = Date()
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivationObserver)
        }
        activationObserver = nil
        deactivationObserver = nil
        iconCache.removeAll()
    }

    /// Must be called on the main thread — it reads `NSWorkspace`/
    /// `NSRunningApplication`, neither of which is documented as safe off
    /// it (unlike `processes`, which is pure libproc and fine from
    /// anywhere). Callers should fetch `processes` via `ProcessScanner`
    /// on a background queue and hop back to main before calling this.
    func aggregate(processes: [ProcessSample]) -> [RunningAppUsage] {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let regularApps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
                !Self.excludedBundleIdentifiers.contains(app.bundleIdentifier ?? "")
        }

        // Clean icon cache of terminated apps if it grows too large
        let currentPIDs = Set(regularApps.map(\.processIdentifier))
        let now = Date()
        for pid in currentPIDs where firstSeenByPID[pid] == nil {
            firstSeenByPID[pid] = now
        }
        firstSeenByPID = firstSeenByPID.filter { currentPIDs.contains($0.key) }
        idleSinceByPID = idleSinceByPID.filter { currentPIDs.contains($0.key) }
        if iconCache.count > regularApps.count + 20 {
            iconCache = iconCache.filter { currentPIDs.contains($0.key) }
        }

        // Fast index: PID -> ProcessSample
        var procByPID: [pid_t: ProcessSample] = [:]
        procByPID.reserveCapacity(processes.count)
        for proc in processes {
            procByPID[proc.pid] = proc
        }

        let appPrefixes: [(pid: pid_t, prefix: String)] = regularApps.compactMap { app in
            guard let url = app.bundleURL else { return nil }
            return (app.processIdentifier, url.path + "/")
        }

        // Map app PID to all its processes (main + helpers)
        var appProcesses: [pid_t: [ProcessSample]] = [:]
        for app in regularApps {
            let pid = app.processIdentifier
            if let mainProc = procByPID[pid] {
                appProcesses[pid] = [mainProc]
            } else {
                appProcesses[pid] = []
            }
        }

        for proc in processes {
            guard let path = proc.executablePath else { continue }
            for (appPID, prefix) in appPrefixes {
                if proc.pid != appPID && path.hasPrefix(prefix) {
                    appProcesses[appPID]?.append(proc)
                    break
                }
            }
        }

        let usages: [RunningAppUsage] = regularApps.compactMap { app in
            let pid = app.processIdentifier
            guard let matched = appProcesses[pid], !matched.isEmpty else { return nil }

            let totalResidentBytes = matched.reduce(UInt64(0)) { $0 + $1.residentBytes }
            let isFrontmost = pid == frontmostPID

            let cachedIcon: NSImage?
            if let icon = iconCache[pid] {
                cachedIcon = icon
            } else if let raw = app.icon {
                let downsampled = Self.downsampleIcon(raw)
                iconCache[pid] = downsampled
                cachedIcon = downsampled
            } else {
                cachedIcon = nil
            }

            return RunningAppUsage(
                pid: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                icon: cachedIcon,
                residentBytes: totalResidentBytes,
                processCount: matched.count,
                isFrontmost: isFrontmost,
                idleSince: isFrontmost ? nil : (idleSinceByPID[pid] ?? firstSeenByPID[pid])
            )
        }

        return usages.sorted { $0.residentBytes > $1.residentBytes }
    }

    func pruneCaches() {
        let livePIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        iconCache = iconCache.filter { livePIDs.contains($0.key) }
        firstSeenByPID = firstSeenByPID.filter { livePIDs.contains($0.key) }
        idleSinceByPID = idleSinceByPID.filter { livePIDs.contains($0.key) }
    }

    private static func downsampleIcon(_ original: NSImage, targetSize: NSSize = NSSize(width: 30, height: 30)) -> NSImage {
        let scale: CGFloat = 2.0
        let pixelWidth = Int(targetSize.width * scale)
        let pixelHeight = Int(targetSize.height * scale)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return original
        }

        context.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)

        var imageRect = CGRect(origin: .zero, size: original.size)
        if let cgImage = original.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) {
            context.draw(cgImage, in: rect)
        } else {
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            original.draw(in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let downscaledCG = context.makeImage() else { return original }
        return NSImage(cgImage: downscaledCG, size: targetSize)
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
