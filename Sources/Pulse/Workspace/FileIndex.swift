import Foundation

/// Relative paths of every file in the project, for Go to File and the
/// built-in search fallback. Built lazily on a background queue the first
/// time it is needed, and dropped when the app regains focus.
final class FileIndex {
    static let limit = 50_000

    let root: URL
    private(set) var paths: [String] = []
    private(set) var isReady = false
    private var isBuilding = false
    private var waiters: [([String]) -> Void] = []

    init(root: URL) {
        self.root = root
    }

    func invalidate() {
        isReady = false
    }

    func withPaths(_ completion: @escaping ([String]) -> Void) {
        if isReady { completion(paths); return }
        waiters.append(completion)
        guard !isBuilding else { return }
        isBuilding = true
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
            let found = FileIndex.scan(root)
            DispatchQueue.main.async {
                self.paths = found
                self.isReady = true
                self.isBuilding = false
                let pending = self.waiters
                self.waiters = []
                pending.forEach { $0(found) }
            }
        }
    }

    static func scan(_ root: URL) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            return []
        }
        let rootPath = root.standardizedFileURL.path
        var result: [String] = []
        for case let url as URL in enumerator {
            if FileNode.ignoredNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") {
                result.append(String(path.dropFirst(rootPath.count + 1)))
            }
            if result.count >= limit { break }
        }
        return result.sorted()
    }
}
