import AppKit

/// Checks GitHub for a newer release and installs it. Every network and
/// file step runs as a short-lived child process (curl, ditto, sh), so
/// Pulse loads no networking code and nothing runs while idle: checks
/// happen at launch and at most once a day on activation.
enum Updater {
    struct Release {
        let version: String
        let zip: URL
        let page: URL
    }

    static let repository = "Suraj1089/pulse"
    /// The supported way to install from outside the app. Releases aren't
    /// notarized, so macOS blocks a copy downloaded in a browser; the
    /// script fetches it with curl and clears the quarantine flag.
    static let installCommand = "curl -fsSL https://pulse0.app/install.sh | bash"
    private static let lastCheckKey = "updateLastCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Only official release builds (scripts/package.sh) check on their own;
    /// local builds are usually ahead of any release.
    static var checksAutomatically: Bool {
        Bundle.main.object(forInfoDictionaryKey: "PulseReleaseBuild") as? Bool ?? false
    }

    /// "2.0.10" is newer than "2.0.9"; missing parts count as 0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Calls back with a newer release, if there is one and a check is due.
    static func checkIfDue(completion: @escaping (Release?) -> Void) {
        guard checksAutomatically else { return }
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < checkInterval { return }
        latest { result in
            if case .success = result { UserDefaults.standard.set(Date(), forKey: lastCheckKey) }
            if case .success(let release) = result, isVersion(release.version, newerThan: currentVersion) {
                completion(release)
            } else {
                completion(nil)
            }
        }
    }

    /// The latest published release, from the GitHub API.
    static func latest(completion: @escaping (Result<Release, UpdateError>) -> Void) {
        run("/usr/bin/curl", ["-fsSL", "--max-time", "15", "-H", "Accept: application/vnd.github+json",
                              "https://api.github.com/repos/\(repository)/releases/latest"]) { status, output in
            guard status == 0,
                  let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                completion(.failure(.message("Could not reach GitHub to check for updates.")))
                return
            }
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { $0["name"] as? String == "Pulse.zip" }?["browser_download_url"] as? String
            let fallback = "https://github.com/\(repository)/releases/download/\(tag)/Pulse.zip"
            completion(.success(Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                                        zip: URL(string: zip ?? fallback)!, page: page)))
        }
    }

    enum UpdateError: Error {
        case message(String)
        var text: String { if case .message(let text) = self { return text }; return "" }
    }

    /// Downloads and checks `release`, then quits Pulse; a detached script
    /// waits for the quit, swaps the app bundle in place and reopens it.
    /// Calls back only on failure.
    static func install(_ release: Release, failure: @escaping (UpdateError) -> Void) {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            failure(.message("Pulse can't replace itself in \(target.deletingLastPathComponent().path)."))
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PulseUpdate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let failure: (UpdateError) -> Void = { error in
            try? FileManager.default.removeItem(at: work)
            failure(error)
        }
        let zip = work.appendingPathComponent("Pulse.zip")
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        run("/usr/bin/curl", ["-fsSL", "--max-time", "300", "-o", zip.path, release.zip.absoluteString]) { status, _ in
            guard status == 0 else { failure(.message("The download failed.")); return }
            run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) { status, _ in
                let app = unpacked.appendingPathComponent("Pulse.app")
                let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
                guard status == 0,
                      info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                      info?["CFBundleShortVersionString"] as? String == release.version else {
                    failure(.message("The downloaded file is not Pulse \(release.version)."))
                    return
                }
                swapAndRelaunch(new: app, target: target, work: work)
            }
        }
    }

    private static func swapAndRelaunch(new: URL, target: URL, work: URL) {
        // Moves the old bundle aside first and puts it back if the copy fails.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.old"
        if mv "$3" "$3.old" && ditto "$2" "$3"; then
          rm -rf "$3.old"
        else
          rm -rf "$3"; mv "$3.old" "$3"
        fi
        xattr -cr "$3" 2>/dev/null
        rm -rf "$4"
        open "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "pulse-update", String(ProcessInfo.processInfo.processIdentifier),
                             new.path, target.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }

    /// Runs a tool off the main thread; completes on main with its exit status and stdout.
    private static func run(_ tool: String, _ arguments: [String], completion: @escaping (Int32, Data) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var status: Int32 = -1
            var output = Data()
            if (try? process.run()) != nil {
                output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                status = process.terminationStatus
            }
            DispatchQueue.main.async { completion(status, output) }
        }
    }
}
