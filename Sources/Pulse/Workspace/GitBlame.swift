import Foundation

/// Who last changed each line of one file, from `git blame --incremental`,
/// which names each commit once and gives line ranges, not the file's text.
/// Compact on purpose: the commits (author, time, summary) plus 4 bytes a
/// line, about 6 KB for a 1,000-line file.
struct GitBlame {
    struct Commit {
        var author = ""
        var time: Int64 = 0      // author time, seconds since 1970
        var summary = ""
    }

    /// A line git said nothing about.
    static let unknown: Int32 = -1
    /// A line changed since the last commit.
    static let uncommitted: Int32 = -2

    /// A file's history can be long; what Pulse keeps of it is not.
    static let maxLines = 1_000_000
    static let maxCommits = 20_000
    static let maxSummary = 80
    /// Output past this is not read (git is stopped); its lines show nothing.
    static let maxOutputBytes = 32 * 1024 * 1024

    private(set) var commits: [Commit] = []
    /// Per line: an index into `commits`, `unknown` or `uncommitted`.
    private(set) var lines: [Int32] = []

    init(commits: [Commit] = [], lines: [Int32] = []) {
        self.commits = commits
        self.lines = lines
    }

    func commit(at line: Int) -> Int32 {
        lines.indices.contains(line) ? lines[line] : GitBlame.unknown
    }

    /// What the editor shows after `line`: "Ada, 3 days ago · Fix the parser".
    func label(at line: Int, now: TimeInterval) -> String? {
        let index = commit(at: line)
        if index == GitBlame.uncommitted { return "You · Not committed yet" }
        guard index >= 0, Int(index) < commits.count else { return nil }
        let commit = commits[Int(index)]
        return "\(commit.author), \(GitBlame.age(TimeInterval(commit.time), now: now)) · \(commit.summary)"
    }

    /// "just now", "5 minutes ago", "1 week ago", "2 years ago".
    static func age(_ time: TimeInterval, now: TimeInterval) -> String {
        let seconds = max(0, now - time)
        func ago(_ count: Double, _ unit: String) -> String {
            let whole = Int(count)
            return whole == 1 ? "1 \(unit) ago" : "\(whole) \(unit)s ago"
        }
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return ago(seconds / 60, "minute")
        case ..<86_400: return ago(seconds / 3_600, "hour")
        case ..<604_800: return ago(seconds / 86_400, "day")
        case ..<2_629_800: return ago(seconds / 604_800, "week")
        case ..<31_557_600: return ago(seconds / 2_629_800, "month")
        default: return ago(seconds / 31_557_600, "year")
        }
    }

    /// Lines `range` of the text before an edit become `count` changed lines.
    mutating func change(_ range: Range<Int>, to count: Int) {
        GitBlame.change(&lines, range, to: count)
    }

    static func change(_ lines: inout [Int32], _ range: Range<Int>, to count: Int) {
        let lower = min(range.lowerBound, lines.count)
        let upper = min(max(range.upperBound, lower), lines.count)
        lines.replaceSubrange(lower..<upper, with: repeatElement(uncommitted, count: count))
    }

    /// Reads `git blame --incremental` a chunk at a time, so its output is
    /// never held whole.
    struct Parser {
        private var commits: [Commit] = []
        private var lines: [Int32] = []
        private var ids: [String: Int32] = [:]
        private var current = GitBlame.unknown
        private var partial = Data()

        mutating func consume(_ chunk: Data) {
            partial.append(chunk)
            var start = partial.startIndex
            while let newline = partial[start...].firstIndex(of: 10) {
                read(String(decoding: partial[start..<newline], as: UTF8.self))
                start = newline + 1
            }
            partial.removeSubrange(partial.startIndex..<start)
        }

        mutating func finish() -> GitBlame {
            if !partial.isEmpty { read(String(decoding: partial, as: UTF8.self)) }
            partial = Data()
            ids = [:]
            return GitBlame(commits: commits, lines: lines)
        }

        private mutating func read(_ line: String) {
            // "<commit> <original line> <final line> <count>" starts each range;
            // a commit's other fields follow the first range that names it.
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            if fields.count == 4, fields[0].utf8.count == 40 || fields[0].utf8.count == 64,
               fields[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
               let first = Int(fields[2]), let count = Int(fields[3]) {
                current = commit(for: String(fields[0]))
                assign(current, from: first - 1, count: count)
                return
            }
            guard current >= 0 else { return }
            if line.hasPrefix("author ") {
                commits[Int(current)].author = String(line.dropFirst(7))
            } else if line.hasPrefix("author-time ") {
                commits[Int(current)].time = Int64(line.dropFirst(12)) ?? 0
            } else if line.hasPrefix("summary ") {
                commits[Int(current)].summary = String(line.dropFirst(8).prefix(GitBlame.maxSummary))
            }
        }

        private mutating func commit(for id: String) -> Int32 {
            // Changes not committed yet come as the all-zero commit.
            if id.utf8.allSatisfy({ $0 == 48 }) { return GitBlame.uncommitted }
            if let index = ids[id] { return index }
            guard commits.count < GitBlame.maxCommits else { return GitBlame.unknown }
            let index = Int32(commits.count)
            commits.append(Commit())
            ids[id] = index
            return index
        }

        private mutating func assign(_ commit: Int32, from start: Int, count: Int) {
            guard start >= 0, count > 0, start < GitBlame.maxLines else { return }
            let end = min(start + count, GitBlame.maxLines)
            if lines.count < end { lines.append(contentsOf: repeatElement(GitBlame.unknown, count: end - lines.count)) }
            for line in start..<end { lines[line] = commit }
        }
    }
}

/// Blame for one open file while it shows it (Document.blame): the latest
/// result, kept in step with edits, and at most one `git blame` at a time,
/// a short-lived child process whose output is parsed as it arrives.
/// Nothing exists until blame is turned on; turning it off frees it all.
final class FileBlame {
    private(set) var result: GitBlame?
    /// While git runs: each line's number in the file git reads (moved by
    /// edits, like `result`), or `GitBlame.uncommitted` for a line changed
    /// since. The result is mapped through it, so typing meanwhile is kept.
    private var origins: [Int32]?
    private var process: Process?
    private var generation = 0
    var onChange: (() -> Void)?
    var onFailure: ((String) -> Void)?

    var isLoading: Bool { origins != nil }

    init(result: GitBlame? = nil) {
        self.result = result
    }

    deinit { cancel() }

    func cancel() {
        generation += 1
        // The process starts on a background queue, so it may not be running
        // yet; terminate() on a process that never started throws.
        if process?.isRunning == true { process?.terminate() }
        process = nil
        origins = nil
    }

    /// Lines `range` of the text before an edit become `count` changed lines.
    func change(_ range: Range<Int>, to count: Int) {
        result?.change(range, to: count)
        if origins != nil { GitBlame.change(&origins!, range, to: count) }
    }

    /// Blames `file` as saved, which has `lineCount` lines (as Document counts them).
    func load(_ file: URL, lineCount: Int) {
        cancel()
        guard let git = GitStatus.git else { onFailure?("git is not installed"); return }
        let current = generation
        origins = (0..<lineCount).map { Int32(clamping: $0) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", file.deletingLastPathComponent().path, "blame", "--incremental", "--", file.lastPathComponent]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        self.process = process
        let name = file.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            var parser = GitBlame.Parser()
            var failure: String?
            do {
                try process.run()
                let handle = output.fileHandleForReading
                var total = 0
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    parser.consume(chunk)
                    total += chunk.count
                    if total > GitBlame.maxOutputBytes {
                        process.terminate()
                        break
                    }
                }
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if total <= GitBlame.maxOutputBytes && process.terminationStatus != 0 {
                    failure = FileBlame.explain(message, name: name)
                }
            } catch {
                failure = error.localizedDescription
            }
            let blame = failure == nil ? parser.finish() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.process = nil
                if let blame {
                    self.finish(with: blame)
                } else {
                    self.origins = nil
                    self.onFailure?(failure ?? "git blame failed")
                }
            }
        }
    }

    private func finish(with blame: GitBlame) {
        guard var lines = origins else { return }
        origins = nil
        for index in lines.indices where lines[index] >= 0 {
            lines[index] = blame.commit(at: Int(lines[index]))
        }
        result = GitBlame(commits: blame.commits, lines: lines)
        onChange?()
    }

    /// git's complaint, as a sentence for the status bar.
    static func explain(_ message: String, name: String) -> String {
        if message.contains("no such path") { return "“\(name)” isn’t committed yet, so its lines have no history." }
        let first = message.split(separator: "\n").first.map(String.init) ?? "git blame failed"
        return first.hasPrefix("fatal: ") ? String(first.dropFirst(7)) : first
    }
}
