import Foundation

struct GitChange {
    enum Kind: Character {
        case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "U", conflicted = "!"
    }

    let path: String        // relative to the repository root
    let kind: Kind
}

struct GitSnapshot {
    var branch: String
    var staged: [GitChange] = []
    var changes: [GitChange] = []
}

/// Read-only git. `status` runs `git status` as a short-lived child process,
/// only when asked, so git's memory is never Pulse's. `branch` reads
/// .git/HEAD directly and starts no process at all.
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
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
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
        process?.terminate()
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
            if x == "R" || x == "C" { index += 1 }  // skip the original path
            if x == "?" {
                snapshot.changes.append(GitChange(path: path, kind: .untracked))
            } else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                snapshot.changes.append(GitChange(path: path, kind: .conflicted))
            } else {
                if let kind = kind(x) { snapshot.staged.append(GitChange(path: path, kind: kind)) }
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
