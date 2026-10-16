import Foundation

/// One changed file as Source Control lists it: what to diff, and against what.
struct GitDiffTarget: Equatable {
    let repository: URL
    let path: String                 // relative to the repository root
    var originalPath: String? = nil  // a staged rename's old path
    let staged: Bool                 // index vs HEAD; otherwise working tree vs index
    let kind: GitChange.Kind

    var fileURL: URL { repository.appendingPathComponent(path) }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// A unified diff, flattened for display: the text of every shown line
/// (without the +/- marker), and per line its kind and old/new line numbers.
/// Compact on purpose: a 50,000-line diff costs its text plus 9 bytes a line.
struct GitDiff {
    enum LineKind: UInt8 {
        case context, added, removed, hunk, note
    }

    /// Diff output above either limit is cut off (and says so): enough for
    /// any reviewable change, small enough to stay inside the memory budget.
    static let maxBytes = 3 * 1024 * 1024
    static let maxLines = 50_000

    var text = ""
    var kinds: [LineKind] = []
    var oldNumbers: [Int32] = []     // 0 when the line has no old-side number
    var newNumbers: [Int32] = []
    /// UTF-16 offset of each line in `text`, for mapping layout back to lines.
    var lineStarts: [Int] = []
    var hunkLines: [Int] = []
    var added = 0
    var removed = 0
    var isBinary = false
    var isTruncated = false
    /// Running UTF-16 length of `text` (counting it again per line would be quadratic).
    private var utf16Length = 0

    var lineCount: Int { kinds.count }

    /// The same diff without its text, once a text view holds it.
    var withoutText: GitDiff {
        var copy = self
        copy.text = ""
        return copy
    }
    var isEmpty: Bool { kinds.isEmpty }

    /// The line containing UTF-16 offset `location` (binary search).
    func line(containing location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        guard high >= 0 else { return 0 }
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private mutating func append(_ line: Substring, kind: LineKind, old: Int, new: Int) {
        lineStarts.append(utf16Length)
        utf16Length += line.utf16.count + 1
        text += line
        text += "\n"
        kinds.append(kind)
        oldNumbers.append(Int32(clamping: old))
        newNumbers.append(Int32(clamping: new))
    }

    /// Parses `git diff` output: unified (`diff --git`) or combined (`diff
    /// --cc`, for conflicts). File headers are dropped; hunk headers stay as
    /// separator lines.
    static func parse(_ data: Data, truncated: Bool = false) -> GitDiff {
        var diff = GitDiff()
        diff.isTruncated = truncated
        let output = String(decoding: data, as: UTF8.self)
        var inHunk = false
        var markerWidth = 1      // 2 in a combined diff
        var oldLine = 0, newLine = 0
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if diff.kinds.count >= maxLines {
                diff.isTruncated = true
                break
            }
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if line.hasPrefix("diff --") {
                inHunk = false
                markerWidth = line.hasPrefix("diff --cc") || line.hasPrefix("diff --combined") ? 2 : 1
                continue
            }
            if line.hasPrefix("@@") {
                inHunk = true
                (oldLine, newLine) = hunkStarts(line)
                diff.hunkLines.append(diff.kinds.count)
                diff.append(line, kind: .hunk, old: 0, new: 0)
                continue
            }
            guard inHunk else {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { diff.isBinary = true }
                continue
            }
            if line.hasPrefix("\\") {
                diff.append(line.dropFirst(2), kind: .note, old: 0, new: 0)
                continue
            }
            guard line.count >= markerWidth else {
                // A trailing empty string after the final newline.
                continue
            }
            let marker = line.prefix(markerWidth)
            let content = line.dropFirst(markerWidth)
            if marker.contains("+") {
                diff.append(content, kind: .added, old: 0, new: newLine)
                newLine += 1
                diff.added += 1
            } else if marker.contains("-") {
                diff.append(content, kind: .removed, old: markerWidth == 1 ? oldLine : 0, new: 0)
                if markerWidth == 1 { oldLine += 1 }
                diff.removed += 1
            } else {
                diff.append(content, kind: .context, old: markerWidth == 1 ? oldLine : 0, new: newLine)
                oldLine += 1
                newLine += 1
            }
        }
        return diff
    }

    /// "@@ -12,7 +12,9 @@" → (12, 12). In a combined diff ("@@@ -a -b +c @@@")
    /// the old side is the first parent; the new side is always the last range.
    static func hunkStarts(_ header: Substring) -> (Int, Int) {
        var old = 0, new = 0
        // Ranges sit between the opening and closing @@; a function name may follow.
        for token in header.split(separator: " ").dropFirst() {
            if token.hasPrefix("@") { break }
            guard let sign = token.first, sign == "-" || sign == "+" else { continue }
            let number = Int(token.dropFirst().split(separator: ",").first ?? "") ?? 0
            if sign == "-" && old == 0 { old = number }
            if sign == "+" { new = number }
        }
        return (old, new)
    }
}

/// Runs `git diff` for one file as a short-lived child process, so the diff
/// algorithm's memory is git's, and reads at most `GitDiff.maxBytes` of its
/// output. One load at a time; starting another cancels the previous one.
final class GitDiffLoader {
    enum Result {
        case diff(GitDiff)
        case failed(String)
    }

    private var process: Process?
    private var generation = 0

    func cancel() {
        generation += 1
        // The process starts on a background queue, so it may not be running
        // yet; terminate() on a process that never started throws.
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    static func arguments(for target: GitDiffTarget) -> [String] {
        let common = ["diff", "--no-color", "--no-ext-diff"]
        if target.kind == .untracked {
            // Exits 1 when the files differ, which they always do here.
            return common + ["--no-index", "--", "/dev/null", target.path]
        }
        if target.staged {
            return common + ["--cached", "-M", "--"] + [target.originalPath, target.path].compactMap { $0 }
        }
        return common + ["--", target.path]
    }

    func load(_ target: GitDiffTarget, completion: @escaping (Result) -> Void) {
        cancel()
        guard let git = GitStatus.git else { completion(.failed("git is not installed")); return }
        let current = generation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", target.repository.path] + GitDiffLoader.arguments(for: target)
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        self.process = process
        DispatchQueue.global(qos: .userInitiated).async {
            var result: Result
            do {
                try process.run()
                var data = Data()
                var truncated = false
                let handle = output.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if data.count > GitDiff.maxBytes {
                        // Stop git rather than read (and hold) the rest.
                        truncated = true
                        process.terminate()
                        break
                    }
                }
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if !truncated && process.terminationStatus > 1 {
                    let first = message.split(separator: "\n").first.map(String.init) ?? "git diff failed"
                    result = .failed(first)
                } else {
                    if truncated, let lastNewline = data.lastIndex(of: 10) {
                        data = data.prefix(upTo: lastNewline)
                    }
                    result = .diff(GitDiff.parse(data, truncated: truncated))
                }
            } catch {
                result = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.process = nil
                completion(result)
            }
        }
    }
}
