import AppKit
import Combine
import Foundation

/// Fetches the latest version from `https://pulse0.app/VERSION` and
/// (optionally) performs an in-place update by downloading the latest ZIP.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    // MARK: - Published state

    @Published private(set) var currentVersion: String = ""
    @Published private(set) var latestVersion: String = ""
    @Published private(set) var checkState: CheckState = .idle
    @Published private(set) var updateState: UpdateState = .idle

    // MARK: - Types

    enum CheckState: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(latest: String)
        case error(String)
    }

    enum UpdateState: Equatable {
        case idle
        case downloading(progress: Double)   // 0.0 – 1.0
        case installing
        case done
        case error(String)
    }

    // MARK: - Constants

    private let versionURL = URL(string: "https://pulse0.app/VERSION")!
    private let downloadURL = URL(string: "https://github.com/Suraj1089/pulse/releases/latest/download/Pulse.zip")!

    // MARK: - Init

    private init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Check

    func checkForUpdates() {
        guard checkState != .checking else { return }
        checkState = .checking

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: versionURL)
                let remote = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                latestVersion = remote
                if isNewer(remote, than: currentVersion) {
                    checkState = .updateAvailable(latest: remote)
                } else {
                    checkState = .upToDate
                }
            } catch {
                checkState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Update

    func performUpdate() {
        guard updateState == .idle else { return }
        updateState = .downloading(progress: 0)

        Task {
            do {
                // 1. Download ZIP with progress
                let tmpZIP = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PulseUpdate.zip")
                try await downloadWithProgress(from: downloadURL, to: tmpZIP)

                // 2. Unzip to temp dir
                updateState = .installing
                let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("PulseUpdateExtract_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-o", tmpZIP.path, "-d", tmpDir.path]
                try unzip.run()
                unzip.waitUntilExit()

                // 3. Find Pulse.app
                let extractedApp = tmpDir.appendingPathComponent("Pulse.app")
                guard FileManager.default.fileExists(atPath: extractedApp.path) else {
                    throw UpdateError.appNotFound
                }

                // 4. Replace /Applications/Pulse.app
                let destination = URL(fileURLWithPath: "/Applications/Pulse.app")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: extractedApp, to: destination)

                // 5. Clear quarantine flag
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
                try? xattr.run()
                xattr.waitUntilExit()

                // 6. Relaunch new version
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(
                    at: destination,
                    configuration: config
                ) { _, _ in }

                // Small delay so the new process is up before we quit
                try await Task.sleep(nanoseconds: 800_000_000)
                updateState = .done
                NSApp.terminate(nil)

            } catch {
                updateState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func downloadWithProgress(from url: URL, to destination: URL) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        let total = (response as? HTTPURLResponse)?.expectedContentLength ?? 1

        var buffer = Data()
        var received: Int64 = 0

        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if received % 32_768 == 0 {
                let progress = Double(received) / Double(max(total, 1))
                self.updateState = .downloading(progress: min(progress, 0.99))
            }
        }

        try buffer.write(to: destination)
    }

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0 ..< max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    enum UpdateError: LocalizedError {
        case appNotFound
        var errorDescription: String? { "Pulse.app not found in downloaded archive." }
    }
}
