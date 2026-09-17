import AppKit
import Combine
import Foundation

/// Fetches the latest version and performs an in-place update by downloading
/// the latest ZIP and swapping the running bundle.
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
    /// Redirects to `/releases/tag/vX.Y.Z`; the tag is read off the final URL.
    /// This is the plain web endpoint, not `api.github.com`, so it isn't rate limited.
    private let releasesLatestURL = URL(string: "https://github.com/Suraj1089/pulse/releases/latest")!
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
                let remote = try await fetchLatestVersion()
                latestVersion = remote
                checkState = isNewer(remote, than: currentVersion)
                    ? .updateAvailable(latest: remote)
                    : .upToDate
            } catch {
                checkState = .error(error.localizedDescription)
            }
        }
    }

    /// Tries `pulse0.app/VERSION` first and falls back to the GitHub release tag.
    /// The fallback matters because the site endpoint is a hand-maintained file:
    /// when it is missing or stale, the release itself is still the truth.
    private func fetchLatestVersion() async throws -> String {
        do {
            return try await fetchVersionFile()
        } catch {
            do {
                return try await fetchLatestReleaseTag()
            } catch {
                // Report the primary failure — the fallback is an implementation
                // detail and its error would only be confusing here.
                throw error
            }
        }
    }

    private func fetchVersionFile() async throws -> String {
        var request = URLRequest(url: versionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, for: versionURL)

        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A 200 that serves an HTML error page or SPA fallback is not a version;
        // without this the string parses to nothing and we'd silently claim
        // "up to date" forever.
        guard Self.isVersionString(body) else {
            throw UpdateError.malformedVersion(body)
        }
        return body
    }

    private func fetchLatestReleaseTag() async throws -> String {
        var request = URLRequest(url: releasesLatestURL)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, for: releasesLatestURL)

        // URLSession has already followed the redirect, so `response.url` is
        // the resolved `/releases/tag/vX.Y.Z`.
        let tag = response.url?.lastPathComponent ?? ""
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isVersionString(version) else {
            throw UpdateError.malformedVersion(tag)
        }
        return version
    }

    private static func validate(_ response: URLResponse, for url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        // URLSession does not throw on 4xx/5xx — the body just comes back as
        // the error page, so the status has to be checked by hand.
        guard (200 ..< 300).contains(http.statusCode) else {
            throw UpdateError.badStatus(code: http.statusCode, url: url)
        }
    }

    /// `1.2`, `1.2.3` or `1.2.3.4` — digits and dots only.
    private static func isVersionString(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 24 else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (2 ... 4).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Update

    func performUpdate() {
        // `.error` has to be retryable — the view offers a "Try again" button
        // and guarding on `.idle` alone would make it dead.
        switch updateState {
        case .idle, .error:
            break
        case .downloading, .installing, .done:
            return
        }
        updateState = .downloading(progress: 0)

        Task {
            do {
                try await installLatest()
            } catch {
                updateState = .error(error.localizedDescription)
            }
        }
    }

    private func installLatest() async throws {
        let destination = Bundle.main.bundleURL
        // Fail before downloading 10 MB if we could never write the result —
        // e.g. running from a read-only DMG or a directory owned by root.
        try Self.verifyWritable(destination)

        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PulseUpdate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // 1. Download
        let zip = workDir.appendingPathComponent("Pulse.zip")
        try await downloadWithProgress(from: downloadURL, to: zip)

        // 2. Unzip
        updateState = .installing
        let extracted = workDir.appendingPathComponent("extract")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Self.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", extracted.path])

        let newApp = extracted.appendingPathComponent("Pulse.app")
        guard FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS").path) else {
            throw UpdateError.appNotFound
        }

        // 3. Clear quarantine before the swap, so the app we hand over is
        //    already clean even if we are killed mid-relaunch.
        _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // 4. Stage beside the destination (same volume, as replaceItemAt needs)
        //    and swap atomically. A plain remove-then-copy would leave the user
        //    with no app at all if the copy failed halfway.
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".PulseUpdate-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: newApp, to: staged)
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }

        // 5. Relaunch, then quit.
        scheduleRelaunch(of: destination)
        updateState = .done
        try await Task.sleep(nanoseconds: 300_000_000)
        NSApp.terminate(nil)
    }

    /// `open` is a no-op while an instance of the same bundle ID is still
    /// running, so the relaunch has to outlive us: a detached shell waits for
    /// this PID to disappear and only then opens the new bundle.
    private func scheduleRelaunch(of app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let quoted = "'" + app.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        sleep 0.3
        open \(quoted)
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }

    // MARK: - Helpers

    private static func verifyWritable(_ bundle: URL) throws {
        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(path: parent.path)
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw UpdateError.commandFailed(
                command: (launchPath as NSString).lastPathComponent,
                status: task.terminationStatus
            )
        }
        return task.terminationStatus
    }

    private func downloadWithProgress(from url: URL, to destination: URL) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        try Self.validate(response, for: url)
        let total = response.expectedContentLength

        // Accumulating one byte at a time costs millions of iterations (and
        // amortised Data growth) for a ~10 MB archive; collect into chunks and
        // append those instead.
        var handle: FileHandle?
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        handle = try FileHandle(forWritingTo: destination)
        defer { try? handle?.close() }

        var chunk = Data()
        chunk.reserveCapacity(Self.chunkSize)
        var received: Int64 = 0
        var lastReported = 0.0

        for try await byte in asyncBytes {
            chunk.append(byte)
            if chunk.count >= Self.chunkSize {
                try handle?.write(contentsOf: chunk)
                received += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)

                if total > 0 {
                    let progress = min(Double(received) / Double(total), 0.99)
                    // Publishing on every chunk churns SwiftUI for no visible
                    // gain; 1% steps are as much as the bar can show.
                    if progress - lastReported >= 0.01 {
                        lastReported = progress
                        updateState = .downloading(progress: progress)
                    }
                }
            }
        }
        if !chunk.isEmpty {
            try handle?.write(contentsOf: chunk)
            received += Int64(chunk.count)
        }
        try handle?.close()
        handle = nil

        guard received > 0 else { throw UpdateError.emptyDownload }
    }

    private static let chunkSize = 64 * 1024

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
        case badStatus(code: Int, url: URL)
        case malformedVersion(String)
        case notWritable(path: String)
        case commandFailed(command: String, status: Int32)
        case emptyDownload

        var errorDescription: String? {
            switch self {
            case .appNotFound:
                return "Pulse.app not found in the downloaded archive."
            case .badStatus(let code, let url):
                return "\(url.host ?? "Server") returned HTTP \(code)."
            case .malformedVersion(let body):
                let preview = body.prefix(20)
                return body.isEmpty
                    ? "Version endpoint returned an empty response."
                    : "Unexpected version response: \u{201C}\(preview)\u{2026}\u{201D}"
            case .notWritable(let path):
                return "No permission to write to \(path). Move Pulse to /Applications and try again."
            case .commandFailed(let command, let status):
                return "\(command) failed with status \(status)."
            case .emptyDownload:
                return "Downloaded archive was empty."
            }
        }
    }
}
