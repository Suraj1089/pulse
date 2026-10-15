import Foundation

/// What Pulse reopens at launch: the folder, the tabs, and the text of any
/// buffer that was never saved, so quitting never loses work.
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

    /// Settable so tests never read or overwrite the real session.
    static var fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pulse", isDirectory: true).appendingPathComponent("session.json")
    }()

    static func load() -> SessionState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save() {
        let url = SessionState.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
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
