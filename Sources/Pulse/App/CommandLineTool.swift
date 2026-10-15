import AppKit

/// The `pulse` terminal command, like VS Code's `code`: a link in a folder on
/// the user's PATH pointing at the script inside Pulse.app. Release builds
/// install it on first launch when that needs no password; Pulse › Install
/// 'pulse' Command does it on demand (asking for a password only if needed).
enum CommandLineTool {
    enum Outcome {
        case installed(String)          // folder the link was created in
        case alreadyInstalled(String)
        case needsPassword
        case unavailable(String)        // why it cannot be installed
    }

    private static let attemptedKey = "cliInstallAttempted"
    private static let fileManager = FileManager.default

    static var script: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/pulse") }

    /// A `pulse` link to this copy of Pulse exists in one of the usual folders.
    static var isInstalled: Bool {
        fallbackFolders.contains { folder in
            let link = (folder as NSString).appendingPathComponent("pulse")
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link) else { return false }
            let resolved = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: folder, isDirectory: true)).standardizedFileURL
            return resolved.path == script.standardizedFileURL.path
        }
    }

    /// What to run in a terminal when installing from Pulse doesn't work.
    static var manualCommand: String {
        let path = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \(path) /usr/local/bin/pulse"
    }

    /// Common user-writable bin folders, used when the shell's PATH can't be read.
    private static var fallbackFolders: [String] {
        ["/usr/local/bin", "/opt/homebrew/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/bin"]
    }

    /// Release builds, once: install if it needs no password. Every launch:
    /// repair a link left pointing at a Pulse.app that no longer exists.
    static func installAutomaticallyIfNeeded(completion: @escaping (Outcome) -> Void) {
        guard Updater.checksAutomatically, fileManager.isExecutableFile(atPath: script.path) else { return }
        repairBrokenLinks()
        guard !UserDefaults.standard.bool(forKey: attemptedKey) else { return }
        UserDefaults.standard.set(true, forKey: attemptedKey)
        install(completion: completion)
    }

    /// Links `pulse` into the first suitable folder on PATH.
    static func install(completion: @escaping (Outcome) -> Void) {
        guard fileManager.isExecutableFile(atPath: script.path) else {
            completion(.unavailable("This copy of Pulse doesn't include the command. Use a release build or scripts/bundle.sh."))
            return
        }
        shellPath { path in
            let folders = path ?? fallbackFolders.filter { fileManager.fileExists(atPath: $0) }
            completion(link(in: folders))
        }
    }

    private static func link(in folders: [String]) -> Outcome {
        for folder in folders where !folder.isEmpty && !isSystemFolder(folder) {
            let link = (folder as NSString).appendingPathComponent("pulse")
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: link) {
                let resolved = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: folder, isDirectory: true)).standardizedFileURL
                if resolved.path == script.standardizedFileURL.path { return .alreadyInstalled(folder) }
                guard resolved.path.hasSuffix("/Contents/Resources/pulse") else {
                    return .unavailable("Another program called “pulse” is already at \(link).")
                }
                // An older or moved copy of Pulse: point the link at this one.
                guard fileManager.isWritableFile(atPath: folder) else { continue }
                try? fileManager.removeItem(atPath: link)
            } else if fileManager.fileExists(atPath: link) {
                return .unavailable("Another program called “pulse” is already at \(link).")
            } else if !fileManager.isWritableFile(atPath: folder) {
                continue
            }
            do {
                try fileManager.createSymbolicLink(atPath: link, withDestinationPath: script.path)
                return .installed(folder)
            } catch {
                continue
            }
        }
        return .needsPassword
    }

    /// Installs into /usr/local/bin (on PATH by default) with the standard
    /// macOS administrator prompt, which the user answers.
    static func installWithPassword(completion: @escaping (Outcome) -> Void) {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "mkdir -p /usr/local/bin && ln -sfn \(quoted(script.path)) /usr/local/bin/pulse"
        let source = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                if let error {
                    completion(.unavailable(error[NSAppleScript.errorMessage] as? String ?? "The command was not installed."))
                } else {
                    completion(.installed("/usr/local/bin"))
                }
            }
        }
    }

    /// Re-points links in the usual folders whose Pulse.app is gone.
    private static func repairBrokenLinks() {
        for folder in fallbackFolders {
            let link = (folder as NSString).appendingPathComponent("pulse")
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link),
                  destination.hasSuffix("/Contents/Resources/pulse"),
                  !fileManager.fileExists(atPath: destination),
                  fileManager.isWritableFile(atPath: folder) else { continue }
            try? fileManager.removeItem(atPath: link)
            try? fileManager.createSymbolicLink(atPath: link, withDestinationPath: script.path)
        }
    }

    private static func isSystemFolder(_ folder: String) -> Bool {
        ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].contains(folder) || folder.hasPrefix("/System/")
    }

    /// The PATH an interactive login shell sets up (GUI apps don't inherit
    /// it), read once with a short-lived shell; nil if that fails.
    private static func shellPath(completion: @escaping ([String]?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-ilc", "printf '__PULSE_PATH__%s__PULSE_END__' \"$PATH\""]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var result: [String]?
            if (try? process.run()) != nil {
                // Don't let a slow shell profile hold this up.
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if let start = output.range(of: "__PULSE_PATH__"), let end = output.range(of: "__PULSE_END__", range: start.upperBound..<output.endIndex) {
                    result = output[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
