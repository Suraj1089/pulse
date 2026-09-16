import AppKit

/// A real open Chrome tab. Title, URL and which tab is active in its window
/// all come straight from Chrome via AppleScript. Chrome does **not** expose
/// per-tab memory or per-tab idle time through scripting (that needs its
/// remote-debugging protocol, which isn't available against an
/// already-running, normally-launched browser) — so unlike everything else
/// in this app, there is no real per-tab memory number to show here.
struct ChromeTab: Identifiable {
    var id: String { "\(windowIndex).\(tabIndex)" }
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    let isActive: Bool

    var host: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Talks to a *running* Google Chrome via AppleScript (Apple Events). The
/// first call triggers the standard macOS Automation permission prompt;
/// until it's granted (System Settings → Privacy & Security → Automation),
/// every call here just returns `nil`/no-ops rather than throwing.
enum ChromeTabsBridge {
    static let bundleIdentifier = "com.google.Chrome"

    /// `NSWorkspace` access — call on the main thread.
    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Synchronous — this is an Apple Event round-trip (and may block on a
    /// permission dialog the first time), so call it off the main queue.
    /// Callers are expected to have already checked `isRunning` on main.
    static func fetchTabs() -> [ChromeTab]? {
        guard let script = NSAppleScript(source: fetchSource) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, let raw = result.stringValue else { return nil }
        return parse(raw)
    }

    static func closeTab(windowIndex: Int, tabIndex: Int) {
        run("tell application \"Google Chrome\" to close tab \(tabIndex) of window \(windowIndex)")
    }

    /// Closes every tab that isn't the active tab in its window, in
    /// descending tab-index order so earlier closes don't shift the indices
    /// of tabs still queued to close.
    static func closeBackgroundTabs(_ tabs: [ChromeTab]) {
        for tab in tabs.filter({ !$0.isActive }).sorted(by: { $0.tabIndex > $1.tabIndex }) {
            closeTab(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex)
        }
    }

    static func quit() {
        run("tell application \"Google Chrome\" to quit")
    }

    private static func run(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
    }

    /// Built with the bare `tab`/`linefeed` constants rather than quoted
    /// `\t`/`\n` escapes, so there's no ambiguity between Swift's and
    /// AppleScript's escaping rules.
    private static let fetchSource = """
    set output to ""
    tell application "Google Chrome"
        set winIndex to 0
        repeat with w in windows
            set winIndex to winIndex + 1
            set activeIdx to active tab index of w
            set tabIndex to 0
            repeat with t in tabs of w
                set tabIndex to tabIndex + 1
                set output to output & winIndex & tab & tabIndex & tab & (title of t) & tab & (URL of t) & tab & (tabIndex = activeIdx) & linefeed
            end repeat
        end repeat
    end tell
    return output
    """

    private static func parse(_ raw: String) -> [ChromeTab] {
        raw.split(separator: "\n").compactMap { line -> ChromeTab? in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 5, let windowIndex = Int(fields[0]), let tabIndex = Int(fields[1]) else { return nil }
            return ChromeTab(
                windowIndex: windowIndex,
                tabIndex: tabIndex,
                title: fields[2],
                url: fields[3],
                isActive: fields[4] == "true"
            )
        }
    }
}
