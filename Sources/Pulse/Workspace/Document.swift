import AppKit

enum DocumentError: LocalizedError {
    case binary(String)
    case tooLarge(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .binary(let name): return "“\(name)” looks like a binary file."
        case .tooLarge(let name): return "“\(name)” is larger than 64 MB."
        case .unreadable(let name): return "“\(name)” is not UTF-8 or Latin-1 text."
        }
    }
}

/// One open file. Its text lives in an `NSTextStorage`; the single editor
/// view swaps storages when the active tab changes, so ten open files cost
/// ten strings, not ten text views.
final class Document {
    static let maxBytes = 64 * 1024 * 1024

    private(set) var url: URL?
    let storage = NSTextStorage()
    let undoManager = UndoManager()
    private(set) var language: Language?
    private(set) var lastModified: Date?

    var selectedRange = NSRange(location: 0, length: 0)
    var scrollPoint: NSPoint = .zero
    var onDirtyChange: (() -> Void)?

    var isDirty = false {
        didSet { if oldValue != isDirty { onDirtyChange?() } }
    }

    var displayName: String { url?.lastPathComponent ?? "Untitled" }
    var length: Int { storage.length }

    init(url: URL?, text: String) {
        self.url = url
        self.language = Language.detect(url: url)
        storage.setAttributedString(NSAttributedString(string: text, attributes: Document.baseAttributes))
        refreshModificationDate()
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.editorFont, .foregroundColor: Theme.text]
    }

    static func open(_ url: URL) throws -> Document {
        let name = url.lastPathComponent
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.count > maxBytes { throw DocumentError.tooLarge(name) }
        if data.prefix(8192).contains(0) { throw DocumentError.binary(name) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw DocumentError.unreadable(name)
        }
        return Document(url: url, text: text)
    }

    // MARK: Saving

    func save(to target: URL? = nil) throws {
        guard let destination = target ?? url else { return }
        try storage.string.write(to: destination, atomically: true, encoding: .utf8)
        if url != destination {
            url = destination
            language = Language.detect(url: destination)
        }
        refreshModificationDate()
        isDirty = false
    }

    /// Re-reads the file if it changed on disk and has no local edits.
    /// Returns true when the text was replaced.
    @discardableResult
    func reloadIfChangedOnDisk() -> Bool {
        guard let url, !isDirty else { return false }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified, let lastModified, modified > lastModified else { return false }
        guard let fresh = try? Document.open(url) else { return false }
        let selection = selectedRange
        storage.setAttributedString(fresh.storage)
        let length = storage.length
        selectedRange = NSRange(location: min(selection.location, length), length: 0)
        undoManager.removeAllActions()
        invalidateLines()
        refreshModificationDate()
        return true
    }

    private func refreshModificationDate() {
        guard let url else { lastModified = nil; return }
        lastModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func applyFont() {
        storage.beginEditing()
        storage.addAttribute(.font, value: Theme.editorFont, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    // MARK: Line index (for the gutter and go-to-line)

    private var lineStarts: [Int] = [0]
    private var linesValid = false

    func invalidateLines() { linesValid = false }

    var lineCount: Int {
        ensureLines()
        return lineStarts.count
    }

    /// Zero-based line containing `location`.
    func line(at location: Int) -> Int {
        ensureLines()
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Character offset where zero-based `line` starts.
    func start(ofLine line: Int) -> Int {
        ensureLines()
        return lineStarts[max(0, min(line, lineStarts.count - 1))]
    }

    private func ensureLines() {
        guard !linesValid else { return }
        let text = storage.string as NSString
        let length = text.length
        var starts = [0]
        starts.reserveCapacity(length / 32 + 1)
        let chunk = 16_384
        var buffer = [unichar](repeating: 0, count: chunk)
        var position = 0
        while position < length {
            let count = min(chunk, length - position)
            text.getCharacters(&buffer, range: NSRange(location: position, length: count))
            for i in 0..<count where buffer[i] == 10 {
                starts.append(position + i + 1)
            }
            position += count
        }
        lineStarts = starts
        linesValid = true
    }
}
