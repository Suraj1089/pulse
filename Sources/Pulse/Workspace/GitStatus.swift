import Foundation

struct GitChange {
    enum Kind: Character {
        case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "U", conflicted = "!"
    }

    let path: String        // relative to the repository root
    let kind: Kind
    var originalPath: String? = nil   // a staged rename's old path
}

struct GitSnapshot {
    var branch: String
    var staged: [GitChange] = []
    var changes: [GitChange] = []
}

/// git, as short-lived child processes started only when asked, so git's
/// memory is never Pulse's: `run` reads status, `stage`/`unstage` move files
/// in and out of the index. `branch` reads .git/HEAD and starts no process.
final class GitStatus {
    private var process: Process?
    private var generation = 0

    static let git: String? = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// The repository root containing `url`, if any.
    static func repositoryRoot(for url: URL) -> URL? {
        var directory = url.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory }
            // For a directory URL, "/" has the parent "/..", so stop at the root
            // rather than comparing paths.
            if directory.pathComponents.count <= 1 { return nil }
            directory = directory.deletingLastPathComponent()
        }
    }

    /// Current branch name, or a short commit id when HEAD is detached.
    static func branch(repository: URL) -> String? {
        var gitDirectory = repository.appendingPathComponent(".git")
        // Worktrees and submodules have a `.git` file pointing elsewhere.
        if let link = try? String(contentsOf: gitDirectory, encoding: .utf8), link.hasPrefix("gitdir:") {
            let path = link.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: path, relativeTo: repository).standardizedFileURL
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        return String(head.prefix(7))
    }

    func cancel() {
        generation += 1
        // Started on a background queue, so it may not be running yet;
        // terminate() on a process that never started throws.
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    func run(repository: URL, completion: @escaping (GitSnapshot?) -> Void) {
        cancel()
        guard let git = GitStatus.git else { completion(nil); return }
        let current = generation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", repository.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        self.process = process
        DispatchQueue.global(qos: .userInitiated).async {
            var snapshot: GitSnapshot?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let branch = GitStatus.branch(repository: repository) ?? "HEAD"
                    snapshot = GitStatus.parse(data, branch: branch)
                }
            } catch {}
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.process = nil
                completion(snapshot)
            }
        }
    }

    /// `git add` for the given paths (new, modified, deleted or conflicted).
    static func stage(_ paths: [String], repository: URL, completion: @escaping (String?) -> Void) {
        execute(["add", "-A", "--"] + paths, repository: repository, completion: completion)
    }

    /// Moves staged changes back to the working tree, keeping the edits.
    static func unstage(_ paths: [String], repository: URL, completion: @escaping (String?) -> Void) {
        execute(["restore", "--staged", "--"] + paths, repository: repository) { error in
            guard error != nil else { completion(nil); return }
            // A repository with no commits has no HEAD to restore from.
            execute(["rm", "--cached", "-r", "-q", "--"] + paths, repository: repository, completion: completion)
        }
    }

    /// Runs git off the main thread; completes on main with nil or an error message.
    private static func execute(_ arguments: [String], repository: URL, completion: @escaping (String?) -> Void) {
        guard let git else { completion("git is not installed"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["-C", repository.path] + arguments
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            var message: String?
            do {
                try process.run()
                let output = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if message?.isEmpty ?? true { message = "git \(arguments.first ?? "") failed" }
                }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async { completion(message) }
        }
    }

    /// Parses `git status --porcelain=v1 -z`: "XY path\0", with renames
    /// followed by an extra "\0origPath".
    static func parse(_ data: Data, branch: String) -> GitSnapshot {
        var snapshot = GitSnapshot(branch: branch)
        let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < fields.count {
            let entry = Array(fields[index])
            index += 1
            guard entry.count > 3 else { continue }
            let x = entry[0], y = entry[1]
            let path = String(entry[3...])
            var originalPath: String?
            if x == "R" || x == "C" {
                originalPath = index < fields.count ? fields[index] : nil
                index += 1
            }
            if x == "?" {
                snapshot.changes.append(GitChange(path: path, kind: .untracked))
            } else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                snapshot.changes.append(GitChange(path: path, kind: .conflicted))
            } else {
                if let kind = kind(x) { snapshot.staged.append(GitChange(path: path, kind: kind, originalPath: originalPath)) }
                if let kind = kind(y) { snapshot.changes.append(GitChange(path: path, kind: kind)) }
            }
        }
        return snapshot
    }

    private static func kind(_ code: Character) -> GitChange.Kind? {
        switch code {
        case "M", "T": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R", "C": return .renamed
        default: return nil
        }
    }
}
