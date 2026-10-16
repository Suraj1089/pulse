import Foundation

/// What Pulse reopens at launch, per window: the folder, the tabs, and the
/// text of any buffer that was never saved, so quitting never loses work.
/// session.json holds every open window (older files hold just one).
struct SessionState: Codable {
    struct Entry: Codable {
        var path: String?
        var unsavedText: String?
        var selection: Int
        var special: Document.Special? = nil
    }

    var root: String?
    var entries: [Entry]
    var active: Int?
    var terminalOpen: Bool
    /// The window's frame (NSStringFromRect), so windows reopen where they were.
    var frame: String? = nil

    /// Settable so tests never read or overwrite the real session.
    static var fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pulse", isDirectory: true).appendingPathComponent("session.json")
    }()

    /// The first window's state.
    static func load() -> SessionState? { loadAll().first }

    /// Every saved window, oldest first; a single-window file from an older
    /// Pulse reads as one window.
    static func loadAll() -> [SessionState] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        if let session = try? JSONDecoder().decode(AppSession.self, from: data) { return session.windows }
        if let single = try? JSONDecoder().decode(SessionState.self, from: data) { return [single] }
        return []
    }

    static func saveAll(_ windows: [SessionState]) {
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(AppSession(windows: windows)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func save() { SessionState.saveAll([self]) }
}

private struct AppSession: Codable {
    var windows: [SessionState]
}

enum RecentFolders {
    private static let key = "recentFolders"

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: key)
    }
}
