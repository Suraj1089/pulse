import Foundation

/// Project search's "files to include" and "files to exclude", as in VS Code:
/// comma-separated glob patterns, matched without regard to case against
/// paths relative to the project folder.
///
/// - `*` and `?` stay within one name, `**` spans folders, `{a,b}` is either
///   alternative; every other character is literal.
/// - A pattern matches at any depth (`*.ts`, `test`, `src/util`) unless it
///   starts with `./` or `/`, which ties it to the project folder.
/// - A pattern that matches a folder takes everything inside it.
/// - A file is searched when it matches an include pattern (if there are
///   any) and no exclude pattern.
///
/// The built-in search filters its file list with `matches(_:)`; ripgrep
/// gets the same rules as `--iglob` arguments.
struct PathFilter {
    private struct Pattern {
        /// The glob in ripgrep's syntax (gitignore rules), without a trailing "/**".
        let ripgrepGlob: String
        let regex: NSRegularExpression

        func matches(_ path: String) -> Bool {
            regex.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
        }
    }

    private let include: [Pattern]
    private let exclude: [Pattern]

    init(include: String = "", exclude: String = "") {
        self.include = PathFilter.patterns(in: include, keepingMatchAll: false)
        self.exclude = PathFilter.patterns(in: exclude, keepingMatchAll: true)
    }

    var isEmpty: Bool { include.isEmpty && exclude.isEmpty }

    func matches(_ relativePath: String) -> Bool {
        if !include.isEmpty, !include.contains(where: { $0.matches(relativePath) }) { return false }
        return !exclude.contains { $0.matches(relativePath) }
    }

    /// Each pattern also as "pattern/**" (a matching folder's contents).
    /// Includes go first: with ripgrep the last matching glob wins, so an
    /// exclude beats an include.
    var ripgrepArguments: [String] {
        var arguments: [String] = []
        for pattern in include {
            arguments += ["--iglob", pattern.ripgrepGlob, "--iglob", "\(pattern.ripgrepGlob)/**"]
        }
        for pattern in exclude {
            arguments += ["--iglob", "!\(pattern.ripgrepGlob)", "--iglob", "!\(pattern.ripgrepGlob)/**"]
        }
        return arguments
    }

    // MARK: Parsing

    /// Splits at commas outside braces, so "*.{ts,tsx}, docs" is two patterns.
    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            switch character {
            case "{": depth += 1
            case "}": depth = max(0, depth - 1)
            case "," where depth == 0:
                parts.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// An include of every file ("*", "**/*", "./") restricts nothing, and
    /// ripgrep would let it into gitignored folders, so it is dropped.
    private static func patterns(in text: String, keepingMatchAll: Bool) -> [Pattern] {
        split(text).compactMap { (raw: String) -> Pattern? in
            var glob = Substring(raw)
            var anchored = false
            if glob.hasPrefix("./") {
                glob = glob.dropFirst(2)
                anchored = true
            } else if glob.hasPrefix("/") {
                glob = glob.dropFirst()
                anchored = true
            }
            while glob.hasSuffix("/") { glob = glob.dropLast() }
            let matchesAll = glob.allSatisfy { $0 == "*" || $0 == "/" }
            guard !glob.isEmpty, keepingMatchAll || !matchesAll else { return nil }
            let chars = Array(glob)
            let braces = bracesBalance(chars)
            let anyDepth = anchored ? "" : "(?:.*/)?"
            let pattern = "^\(anyDepth)\(regexBody(chars, braces: braces))(?:/.*)?$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            var body = ripgrepBody(chars, braces: braces)
            if anchored {
                body = "/\(body)"
            } else if !body.hasPrefix("**/") {
                body = "**/\(body)"
            }
            return Pattern(ripgrepGlob: body, regex: regex)
        }
    }

    /// Unbalanced braces are taken literally (ripgrep would reject them).
    private static func bracesBalance(_ chars: [Character]) -> Bool {
        var depth = 0
        for character in chars {
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    private static func regexBody(_ chars: [Character], braces: Bool) -> String {
        var out = ""
        var depth = 0
        var i = 0
        while i < chars.count {
            let character = chars[i]
            if character == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    // "**" spans folders only as a whole name, as in ripgrep;
                    // "a**b" is the same as "a*b".
                    let startsName = i == 0 || chars[i - 1] == "/"
                    let endsName = i + 2 == chars.count || chars[i + 2] == "/"
                    if startsName, endsName {
                        if i + 2 < chars.count {
                            out += "(?:.*/)?"
                            i += 3
                        } else {
                            out += ".*"
                            i += 2
                        }
                        continue
                    }
                    out += "[^/]*"
                    i += 2
                    continue
                }
                out += "[^/]*"
            } else if character == "?" {
                out += "[^/]"
            } else if braces, character == "{" {
                out += "(?:"
                depth += 1
            } else if braces, character == "}", depth > 0 {
                out += ")"
                depth -= 1
            } else if braces, character == ",", depth > 0 {
                out += "|"
            } else {
                out += NSRegularExpression.escapedPattern(for: String(character))
            }
            i += 1
        }
        return out
    }

    /// The glob for ripgrep: characters this filter takes literally are escaped.
    private static func ripgrepBody(_ chars: [Character], braces: Bool) -> String {
        var out = ""
        for character in chars {
            switch character {
            case "[", "]", "\\":
                out += "\\"
            case "{" where !braces, "}" where !braces:
                out += "\\"
            default:
                break
            }
            out.append(character)
        }
        return out
    }
}
