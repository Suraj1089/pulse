import Foundation

struct SearchMatch {
    let line: Int          // one-based; the first line of a multi-line match
    let column: Int        // UTF-16 offset of the match within the line
    let length: Int        // UTF-16 length of the whole match (may span lines)
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
///
/// A query of several words matches across lines: any run of spaces or
/// newlines in it matches any run of whitespace in a file, and everything
/// else is literal. So a pasted block of code (or the same block typed on
/// one line, or reindented) finds the code however it is wrapped.
///
/// `filter` (files to include / exclude) limits which files are searched:
/// ripgrep gets it as globs, so it never reads excluded folders, and its
/// output is checked against the same rules as the built-in scan.
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

    func run(query: String, root: URL, caseSensitive: Bool, filter: PathFilter = PathFilter(), index: FileIndex,
             useRipgrep: Bool = ProjectSearch.ripgrep != nil,
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
        let words = ProjectSearch.words(of: query)
        if useRipgrep, let rg = ProjectSearch.ripgrep {
            if let words {
                runRipgrepBlock(rg, pattern: ProjectSearch.ripgrepPattern(words), root: root, caseSensitive: caseSensitive,
                                filter: filter, completion: deliver)
            } else {
                runRipgrep(rg, query: query, root: root, caseSensitive: caseSensitive, filter: filter, completion: deliver)
            }
        } else {
            index.withPaths { allPaths in
                DispatchQueue.global(qos: .userInitiated).async {
                    let paths = filter.isEmpty ? allPaths : allPaths.filter(filter.matches)
                    let (results, truncated) = words.map {
                        ProjectSearch.scanBlocks(paths: paths, root: root, words: $0, caseSensitive: caseSensitive)
                    } ?? ProjectSearch.scan(paths: paths, root: root, query: query, caseSensitive: caseSensitive)
                    deliver(results, truncated)
                }
            }
        }
    }

    private func runRipgrep(_ executable: String, query: String, root: URL, caseSensitive: Bool, filter: PathFilter,
                            completion: @escaping ([SearchFileResult], Bool) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.currentDirectoryURL = root
        var arguments = [
            "--line-number", "--no-heading", "--null", "--color", "never",
            "--fixed-strings", "--max-columns", "400", "--max-count", "200",
            caseSensitive ? "--case-sensitive" : "--ignore-case",
        ]
        arguments += filter.ripgrepArguments
        arguments += ["--", query, "."]
        task.arguments = arguments
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
            // "\r\n" is one Character in Swift, so a CRLF file's line would
            // otherwise swallow the next result.
            for record in output.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
                // Format: path NUL line:text
                guard let nul = record.firstIndex(of: "\0") else { continue }
                var path = String(record[..<nul])
                if path.hasPrefix("./") { path.removeFirst(2) }
                guard filter.matches(path) else { continue }
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
                if total >= ProjectSearch.maxMatches { truncated = true; break }
            }
            completion(order.compactMap { byPath[$0] }, truncated)
        }
    }

    // MARK: Multi-word queries (blocks of code)

    /// The words of a query that spans whitespace, or nil for a single word
    /// (searched as plain text, line by line).
    static func words(of query: String) -> [String]? {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        return words.count > 1 ? words : nil
    }

    /// A ripgrep (Rust regex) pattern: each word literally, any whitespace between.
    static func ripgrepPattern(_ words: [String]) -> String {
        let meta = Set("\\.+*?()|[]{}^$#&-~")
        return words.map { word in
            word.reduce(into: "") { result, character in
                if meta.contains(character) { result.append("\\") }
                result.append(character)
            }
        }.joined(separator: "\\s+")
    }

    private func runRipgrepBlock(_ executable: String, pattern: String, root: URL, caseSensitive: Bool, filter: PathFilter,
                                 completion: @escaping ([SearchFileResult], Bool) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.currentDirectoryURL = root
        // JSON gives each match's exact start, which plain output can't for matches spanning lines.
        var arguments = [
            "--json", "--multiline", "--max-count", "200",
            caseSensitive ? "--case-sensitive" : "--ignore-case",
            "-e", pattern,
        ]
        arguments += filter.ripgrepArguments
        arguments += ["--", "."]
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        process = task
        do { try task.run() } catch { completion([], false); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            var order: [String] = []
            var byPath: [String: SearchFileResult] = [:]
            var total = 0
            var truncated = false
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["type"] as? String == "match",
                      let match = object["data"] as? [String: Any],
                      var path = (match["path"] as? [String: Any])?["text"] as? String,
                      let text = (match["lines"] as? [String: Any])?["text"] as? String,
                      let firstLine = match["line_number"] as? Int,
                      let submatches = match["submatches"] as? [[String: Any]] else { continue }
                if path.hasPrefix("./") { path.removeFirst(2) }
                guard filter.matches(path) else { continue }
                let result: SearchFileResult
                if let existing = byPath[path] {
                    result = existing
                } else {
                    result = SearchFileResult(url: root.appendingPathComponent(path), relativePath: path)
                    byPath[path] = result
                    order.append(path)
                }
                for submatch in submatches {
                    guard let start = submatch["start"] as? Int, let end = submatch["end"] as? Int,
                          let found = ProjectSearch.blockMatch(firstLine: firstLine, text: text, startByte: start, endByte: end) else { continue }
                    result.matches.append(found)
                    total += 1
                }
                if total >= ProjectSearch.maxMatches { truncated = true; break }
            }
            completion(order.compactMap { byPath[$0] }.filter { !$0.matches.isEmpty }, truncated)
        }
    }

    /// Built-in search for multi-word queries, when ripgrep isn't installed.
    private static func scanBlocks(paths: [String], root: URL, words: [String], caseSensitive: Bool) -> ([SearchFileResult], Bool) {
        let pattern = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else {
            return ([], false)
        }
        var results: [SearchFileResult] = []
        var total = 0
        for path in paths {
            let url = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count < 2_000_000, !data.prefix(4096).contains(0) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let result = SearchFileResult(url: url, relativePath: path)
            for found in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                guard let range = Range(found.range, in: text) else { continue }
                let start = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.utf8.distance(from: text.startIndex, to: range.upperBound)
                if let match = blockMatch(firstLine: 1, text: text, startByte: start, endByte: end) {
                    result.matches.append(match)
                    total += 1
                }
                if total >= maxMatches { break }
            }
            if !result.matches.isEmpty { results.append(result) }
            if total >= maxMatches { return (results, true) }
        }
        return (results, false)
    }

    /// Where a match given as UTF-8 byte offsets into `text` (which starts at
    /// `firstLine`) begins: its line, column and full length, with that line
    /// as the preview.
    static func blockMatch(firstLine: Int, text: String, startByte: Int, endByte: Int) -> SearchMatch? {
        let bytes = Array(text.utf8)
        guard startByte >= 0, startByte <= endByte, endByte <= bytes.count else { return nil }
        let newline = UInt8(ascii: "\n")
        let lineStart = bytes[..<startByte].lastIndex(of: newline).map { $0 + 1 } ?? 0
        var lineEnd = bytes[startByte...].firstIndex(of: newline) ?? bytes.count
        if lineEnd > lineStart, bytes[lineEnd - 1] == UInt8(ascii: "\r") { lineEnd -= 1 }
        let line = firstLine + bytes[..<startByte].filter { $0 == newline }.count
        let lineText = String(decoding: bytes[lineStart..<max(lineStart, lineEnd)], as: UTF8.self)
        let column = String(decoding: bytes[lineStart..<startByte], as: UTF8.self).utf16.count
        let length = String(decoding: bytes[startByte..<endByte], as: UTF8.self).utf16.count
        let (preview, previewStart) = previewOf(lineText, column: column)
        return SearchMatch(line: line, column: column, length: length, preview: preview, previewStart: previewStart)
    }

    /// The line without its indentation, cut to a readable length.
    private static func previewOf(_ text: String, column: Int) -> (String, Int) {
        let ns = text as NSString
        let leading = min(text.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count, ns.length)
        return (String(ns.substring(from: leading).prefix(240)), max(0, column - leading))
    }

    // MARK: Single words, line by line

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
        let (preview, previewStart) = previewOf(text, column: column)
        return SearchMatch(line: line, column: column, length: found.location == NSNotFound ? 0 : found.length,
                           preview: preview, previewStart: previewStart)
    }
}
