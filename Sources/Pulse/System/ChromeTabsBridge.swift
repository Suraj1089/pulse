import AppKit

/// A real open Chrome tab with a stable per-session ID from Chrome's
/// AppleScript dictionary (`id of t`).
struct ChromeTab: Identifiable, Equatable {
    let id: Int
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    let isActive: Bool

    var host: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Title cleaned up per Phase 3.4
    var cleanedTitle: String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip leading media/recording glyphs (●, 🔴, •)
        if t.hasPrefix("● ") || t.hasPrefix("• ") {
            t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // 2. Move leading unread count "(12) Inbox" -> "Inbox (12)"
        if t.hasPrefix("(") {
            if let closingParen = t.firstIndex(of: ")") {
                let badge = String(t[...closingParen])
                let remainder = String(t[t.index(after: closingParen)...]).trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty {
                    t = "\(remainder) \(badge)"
                }
            }
        }

        // 3. Strip trailing site name that repeats the host (e.g. " — GitHub")
        let hostPart = host.split(separator: ".").first.map(String.init) ?? ""
        if !hostPart.isEmpty {
            for separator in [" — ", " - ", " · ", " | "] {
                if let range = t.range(of: separator, options: .backwards) {
                    let suffix = t[range.upperBound...].lowercased()
                    if suffix.contains(hostPart.lowercased()) {
                        t = String(t[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
        }

        // 4. Fallback if empty
        if t.isEmpty {
            if let urlObj = URL(string: url), !urlObj.path.isEmpty && urlObj.path != "/" {
                t = "\(host)\(urlObj.path)"
            } else {
                t = host.isEmpty ? "New Tab" : host
            }
        }

        return t
    }

    /// Suitable for an idle-time hint. Chrome's AppleScript tab ID can change
    /// while the tab remains open, so it must not be used for elapsed time.
    var idleKey: String {
        "\(url)\u{1F}\(cleanedTitle)"
    }
}

/// Talks to Google Chrome via AppleScript with stable tab IDs.
enum ChromeTabsBridge {
    static let bundleIdentifier = "com.google.Chrome"

    /// Call on the main thread.
    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Fetches tabs with their stable IDs.
    static func fetchTabs() -> [ChromeTab]? {
        guard let script = NSAppleScript(source: fetchSource) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, let raw = result.stringValue else { return nil }
        return parse(raw)
    }

    /// Activates a tab in Google Chrome and brings Chrome frontmost.
    static func activateTab(id: Int) {
        let source = """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t) is \(id) then
                        set active tab index of w to (index of t)
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        run(source)
    }

    static func quit() {
        run("tell application \"Google Chrome\" to quit")
    }

    private static func run(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
    }

    private static let fetchSource = """
    set tabChar to character id 9
    set nl to character id 10
    set output to ""
    tell application "Google Chrome"
        set winIndex to 0
        repeat with w in windows
            set winIndex to winIndex + 1
            set activeIdx to active tab index of w
            set tabIndex to 0
            repeat with t in tabs of w
                set tabIndex to tabIndex + 1
                set output to output & (id of t) & tabChar & winIndex & tabChar & tabIndex & tabChar & (title of t) & tabChar & (URL of t) & tabChar & (tabIndex = activeIdx) & nl
            end repeat
        end repeat
    end tell
    return output
    """

    private static func parse(_ raw: String) -> [ChromeTab] {
        raw.split(separator: "\n").compactMap { line -> ChromeTab? in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 6,
                  let tabID = Int(fields[0]),
                  let windowIndex = Int(fields[1]),
                  let tabIndex = Int(fields[2]) else { return nil }
            return ChromeTab(
                id: tabID,
                windowIndex: windowIndex,
                tabIndex: tabIndex,
                title: fields[3],
                url: fields[4],
                isActive: fields[5] == "true"
            )
        }
    }
}
