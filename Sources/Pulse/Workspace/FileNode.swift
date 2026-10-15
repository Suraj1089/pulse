import Foundation

/// A file or folder in the sidebar. Children are read from disk only when a
/// folder is expanded, and refreshed in place so expansion state survives.
final class FileNode: NSObject {
    static let ignoredNames: Set<String> = [
        ".git", ".hg", ".svn", ".DS_Store", "node_modules", ".build", "DerivedData",
        ".swiftpm", "__pycache__", ".idea", ".venv", ".next", ".gradle", "Pods",
    ]

    let url: URL
    let isDirectory: Bool
    private var cachedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        super.init()
    }

    var name: String { url.lastPathComponent }

    var children: [FileNode] {
        if let cachedChildren { return cachedChildren }
        let loaded = FileNode.list(url)
        cachedChildren = loaded
        return loaded
    }

    /// Re-reads folders that were already loaded, reusing existing nodes.
    func refresh() {
        guard isDirectory, let current = cachedChildren else { return }
        let existing = Dictionary(current.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { first, _ in first })
        cachedChildren = FileNode.list(url).map { fresh in
            if let old = existing[fresh.url.standardizedFileURL], old.isDirectory == fresh.isDirectory {
                old.refresh()
                return old
            }
            return fresh
        }
    }

    /// Finds the loaded node for `target`, loading folders along the path.
    func node(for target: URL) -> FileNode? {
        let rootPath = url.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else { return nil }
        let parts = targetPath.dropFirst(rootPath.count + 1).split(separator: "/")
        var current: FileNode = self
        for part in parts {
            guard let next = current.children.first(where: { $0.name == part }) else { return nil }
            current = next
        }
        return current
    }

    private static func list(_ directory: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        return urls
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { FileNode(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}
