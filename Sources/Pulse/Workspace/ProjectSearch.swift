import Foundation

struct SearchMatch {
    let line: Int          // one-based
    let column: Int        // UTF-16 offset of the match within the line
    let length: Int
    let preview: String
    let previewStart: Int  // where the match starts within `preview`
}

final class SearchFileResult: NSObject {
    let url: URL
    let relativePath: String
    var matches: [SearchMatch] = []

    init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
        super.init()
    }
}

/// Plain-text search across the project. Uses ripgrep when it is installed
/// (it runs as a short-lived child process, so its memory is never Pulse's),
/// otherwise a simple built-in scan.
final class ProjectSearch {
    static let maxMatches = 2_000

    private var process: Process?
    private var generation = 0

    static let ripgrep: String? = {
        let candidates = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func cancel() {
        generation += 1
        process?.terminate()
        process = nil
    }

    func run(query: String, root: URL, caseSensitive: Bool, index: FileIndex,
             completion: @escaping ([SearchFileResult], Bool) -> Void) {
        cancel()
        let current = generation
        let deliver: ([SearchFileResult], Bool) -> Void = { [weak self] results, truncated in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.process = nil
                completion(results, truncated)
            }
        }
        if let rg = ProjectSearch.ripgrep {
            runRipgrep(rg, query: query, root: root, caseSensitive: caseSensitive, completion: deliver)
        } else {
            index.withPaths { paths in
                DispatchQueue.global(qos: .userInitiated).async {
                    let (results, truncated) = ProjectSearch.scan(paths: paths, root: root, query: query, caseSensitive: caseSensitive)
                    deliver(results, truncated)
                }
            }
        }
    }

    private func runRipgrep(_ executable: String, query: String, root: URL, caseSensitive: Bool,
                            completion: @escaping ([SearchFileResult], Bool) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.currentDirectoryURL = root
        task.arguments = [
            "--line-number", "--no-heading", "--null", "--color", "never",
            "--fixed-strings", "--max-columns", "400", "--max-count", "200",
            caseSensitive ? "--case-sensitive" : "--ignore-case",
            "--", query, ".",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        process = task
        do { try task.run() } catch { completion([], false); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            var order: [String] = []
            var byPath: [String: SearchFileResult] = [:]
            var total = 0
            var truncated = false
            for record in output.split(separator: "\n", omittingEmptySubsequences: true) {
                // Format: path NUL line:text
                guard let nul = record.firstIndex(of: "\0") else { continue }
                var path = String(record[..<nul])
                if path.hasPrefix("./") { path.removeFirst(2) }
                let rest = record[record.index(after: nul)...]
                guard let colon = rest.firstIndex(of: ":"), let line = Int(rest[..<colon]) else { continue }
                let text = String(rest[rest.index(after: colon)...])
                let result: SearchFileResult
                if let existing = byPath[path] {
                    result = existing
                } else {
                    result = SearchFileResult(url: root.appendingPathComponent(path), relativePath: path)
                    byPath[path] = result
                    order.append(path)
                }
                result.matches.append(ProjectSearch.match(line: line, text: text, query: query, caseSensitive: caseSensitive))
                total += 1
                if total >= maxMatches { truncated = true; break }
            }
            completion(order.compactMap { byPath[$0] }, truncated)
        }
    }

    private static func scan(paths: [String], root: URL, query: String, caseSensitive: Bool) -> ([SearchFileResult], Bool) {
        var results: [SearchFileResult] = []
        var total = 0
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for path in paths {
            let url = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count < 2_000_000, !data.prefix(4096).contains(0) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard text.range(of: query, options: options) != nil else { continue }
            let result = SearchFileResult(url: url, relativePath: path)
            var lineNumber = 0
            text.enumerateLines { line, stop in
                lineNumber += 1
                if line.range(of: query, options: options) != nil {
                    result.matches.append(match(line: lineNumber, text: line, query: query, caseSensitive: caseSensitive))
                    total += 1
                    if total >= maxMatches { stop = true }
                }
            }
            results.append(result)
            if total >= maxMatches { return (results, true) }
        }
        return (results, false)
    }

    private static func match(line: Int, text: String, query: String, caseSensitive: Bool) -> SearchMatch {
        let ns = text as NSString
        let found = ns.range(of: query, options: caseSensitive ? [] : [.caseInsensitive])
        let column = found.location == NSNotFound ? 0 : found.location
        // Trim leading whitespace for the preview but keep the match visible.
        let leading = text.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
        let preview = ns.substring(from: min(leading, ns.length))
        let trimmed = min(leading, ns.length)
        return SearchMatch(line: line, column: column, length: found.location == NSNotFound ? 0 : found.length,
                           preview: String(preview.prefix(240)), previewStart: max(0, column - trimmed))
    }
}
