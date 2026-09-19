import AppKit
import Darwin

struct LeftoverBackgroundGroup: Identifiable {
    struct ProcessIdentity {
        let pid: pid_t
        let executablePath: String
    }

    var id: String { bundlePath }
    let appName: String
    let bundlePath: String
    let processes: [ProcessIdentity]
    let totalFootprintBytes: UInt64

    var processCount: Int { processes.count }

    var footprintDescription: String {
        let gb = Double(totalFootprintBytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB footprint", gb) : String(format: "%.0f MB footprint", gb * 1024)
    }
}

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

/// AppKit-derived data captured on the main thread, before memory attribution
/// is calculated on Pulse's utility queue.
struct RunningAppsWorkspaceSnapshot {
    struct App {
        let pid: pid_t
        let name: String
        let bundleIdentifier: String?
        let bundlePath: String?
        let icon: NSImage?
        let isFrontmost: Bool
        let idleSince: Date?
    }

    let apps: [App]
    let runningBundlePaths: Set<String>
}

/// Aggregates `NSWorkspace.runningApplications` with real per-process memory
/// from `ProcessScanner`, and tracks how recently each app was frontmost via
/// `NSWorkspace` activation notifications so we can report genuine (if
/// session-bounded) idle durations.
final class RunningAppsMonitor {
    private static let leftoverMinimumAge: TimeInterval = 5 * 60 * 60
    private static let leftoverMinimumFootprint: UInt64 = 500_000_000
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

    /// Must be called on the main thread. It makes the narrow AppKit snapshot
    /// needed to do the CPU-heavy process attribution without blocking input.
    func workspaceSnapshot() -> RunningAppsWorkspaceSnapshot {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications
        let regularApps = runningApps.filter { app in
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

        let apps = regularApps.map { app -> RunningAppsWorkspaceSnapshot.App in
            let pid = app.processIdentifier
            let icon: NSImage?
            if let cached = iconCache[pid] {
                icon = cached
            } else if let raw = app.icon {
                let downsampled = Self.downsampleIcon(raw)
                iconCache[pid] = downsampled
                icon = downsampled
            } else {
                icon = nil
            }

            return .init(
                pid: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: app.bundleURL?.path,
                icon: icon,
                isFrontmost: pid == frontmostPID,
                idleSince: pid == frontmostPID ? nil : (idleSinceByPID[pid] ?? firstSeenByPID[pid])
            )
        }

        return RunningAppsWorkspaceSnapshot(
            apps: apps,
            runningBundlePaths: Set(runningApps.compactMap { $0.bundleURL?.path })
        )
    }

    /// Uses only value snapshots, so it is safe to run on the utility queue.
    func aggregate(
        processes: [ProcessSample],
        workspace: RunningAppsWorkspaceSnapshot
    ) -> [RunningAppUsage] {
        // Fast index: PID -> ProcessSample
        var procByPID: [pid_t: ProcessSample] = [:]
        procByPID.reserveCapacity(processes.count)
        for proc in processes {
            procByPID[proc.pid] = proc
        }

        let appPrefixes: [(pid: pid_t, prefix: String)] = workspace.apps.compactMap { app in
            guard let bundlePath = app.bundlePath else { return nil }
            return (app.pid, bundlePath + "/")
        }

        // Map app PID to all its processes (main + helpers)
        var appProcesses: [pid_t: [ProcessSample]] = [:]
        for app in workspace.apps {
            let pid = app.pid
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

        let usages: [RunningAppUsage] = workspace.apps.compactMap { app in
            let pid = app.pid
            guard let matched = appProcesses[pid], !matched.isEmpty else { return nil }

            let totalResidentBytes = matched.reduce(UInt64(0)) { $0 + $1.residentBytes }

            return RunningAppUsage(
                pid: pid,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon,
                residentBytes: totalResidentBytes,
                processCount: matched.count,
                isFrontmost: app.isFrontmost,
                idleSince: app.idleSince
            )
        }

        return usages.sorted { $0.residentBytes > $1.residentBytes }
    }

    /// Finds resource-heavy helpers left behind after their owning app exits.
    /// Requiring an app-bundle path, PPID 1, a long lifetime, a large physical
    /// footprint, and no live owner avoids treating normal launch agents or
    /// menu-bar apps as leftovers.
    /// This deliberately uses only process samples and an already-captured
    /// workspace snapshot, so the potentially slow `proc_pidinfo` calls stay
    /// off the main thread.
    func leftoverBackgroundGroups(
        processes: [ProcessSample],
        runningBundlePaths: Set<String>
    ) -> [LeftoverBackgroundGroup] {
        let now = Date()

        let candidates = processes.compactMap { process -> (String, LeftoverBackgroundGroup.ProcessIdentity, UInt64)? in
            guard process.physFootprintBytes >= Self.leftoverMinimumFootprint,
                  let executablePath = process.executablePath,
                  let bundlePath = Self.owningAppBundlePath(for: executablePath),
                  !runningBundlePaths.contains(bundlePath),
                  let identity = ProcessScanner.identity(of: process.pid),
                  identity.parentPID == 1,
                  now.timeIntervalSince(identity.startDate) >= Self.leftoverMinimumAge
            else { return nil }

            return (
                bundlePath,
                .init(pid: process.pid, executablePath: executablePath),
                process.physFootprintBytes
            )
        }

        return Dictionary(grouping: candidates, by: \.0)
            .map { bundlePath, entries in
                LeftoverBackgroundGroup(
                    appName: URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent,
                    bundlePath: bundlePath,
                    processes: entries.map(\.1),
                    totalFootprintBytes: entries.reduce(UInt64(0)) { $0 + $1.2 }
                )
            }
            .sorted { $0.totalFootprintBytes > $1.totalFootprintBytes }
    }

    func terminateLeftovers(_ group: LeftoverBackgroundGroup) {
        for process in group.processes {
            // Re-check the executable path so a recycled PID can never target
            // an unrelated process after the recommendation was rendered.
            guard ProcessScanner.path(of: process.pid) == process.executablePath else { continue }
            _ = Darwin.kill(process.pid, SIGTERM)
        }
    }

    private static func owningAppBundlePath(for executablePath: String) -> String? {
        guard let marker = executablePath.range(of: ".app/") else { return nil }
        let slashIndex = executablePath.index(before: marker.upperBound)
        return String(executablePath[..<slashIndex])
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
