import AppKit

enum DocumentError: LocalizedError {
    case binary(String)
    case tooLarge(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .binary(let name): return "“\(name)” looks like a binary file."
        case .tooLarge(let name): return "“\(name)” is larger than 16 MB."
        case .unreadable(let name): return "“\(name)” is not UTF-8 or Latin-1 text."
        }
    }
}

/// One open file. Its text lives in an `NSTextStorage`; the single editor
/// view swaps storages when the active tab changes, so ten open files cost
/// ten strings, not ten text views.
final class Document {
    /// The largest file Pulse opens, and (in characters, one a byte for
    /// ASCII) the largest an edit can make one. Its text, a copy for Undo
    /// and AppKit's own copies during a change must fit Pulse's 100 MB.
    static let maxBytes = 16 * 1024 * 1024

    /// Tabs that show a view instead of text, like VS Code's settings editors.
    enum Special: String, Codable {
        case keyboardShortcuts
        case welcome
        /// A changed file's diff, from Source Control. One at a time, like a
        /// preview tab: clicking another change reuses it. Not restored.
        case diff

        var title: String {
            switch self {
            case .keyboardShortcuts: return "Keyboard Shortcuts"
            case .welcome: return "Welcome"
            case .diff: return "Changes"
            }
        }
    }

    private(set) var url: URL?
    let storage = NSTextStorage()
    let undoManager = UndoManager()
    private(set) var language: Language?
    private(set) var lastModified: Date?
    private(set) var special: Special?
    /// What a `.diff` tab shows.
    var diffTarget: GitDiffTarget?

    var selectedRange = NSRange(location: 0, length: 0)
    /// Document point at the top-left of the visible text (see EditorScrollView).
    var scrollPoint: NSPoint = .zero
    var onDirtyChange: (() -> Void)?

    var isDirty = false {
        didSet { if oldValue != isDirty { onDirtyChange?() } }
    }

    var displayName: String {
        if special == .diff, let diffTarget {
            return "\(diffTarget.fileName) (\(diffTarget.staged ? "Staged" : "Changes"))"
        }
        return special?.title ?? url?.lastPathComponent ?? "Untitled"
    }
    var length: Int { storage.length }

    init(url: URL?, text: String) {
        self.url = url
        self.language = Language.detect(url: url)
        // Not an NSAttributedString with the attributes: from a mapped file
        // that path stores ASCII at 2 bytes a character instead of 1.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        storage.setAttributes(Document.baseAttributes, range: NSRange(location: 0, length: storage.length))
        refreshModificationDate()
    }

    convenience init(special: Special) {
        self.init(url: nil, text: "")
        self.special = special
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.editorFont, .foregroundColor: Theme.text]
    }

    static func open(_ url: URL) throws -> Document {
        let name = url.lastPathComponent
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.count > maxBytes { throw DocumentError.tooLarge(name) }
        if data.prefix(8192).contains(0) { throw DocumentError.binary(name) }
        // The storage copies the text straight from the mapped file: ASCII
        // text needs no other copy of the file in memory on the way.
        let document = data.withUnsafeBytes { bytes -> Document? in
            guard let base = bytes.baseAddress else { return Document(url: url, text: "") }
            let pointer = UnsafeMutableRawPointer(mutating: base)
            let text = NSString(bytesNoCopy: pointer, length: bytes.count, encoding: String.Encoding.utf8.rawValue, freeWhenDone: false)
                ?? NSString(bytesNoCopy: pointer, length: bytes.count, encoding: String.Encoding.isoLatin1.rawValue, freeWhenDone: false)
            return text.map { Document(url: url, text: $0 as String) }
        }
        guard let document else { throw DocumentError.unreadable(name) }
        return document
    }

    // MARK: Saving

    func save(to target: URL? = nil) throws {
        guard let destination = target ?? url else { return }
        try write(to: destination)
        if url != destination {
            url = destination
            language = Language.detect(url: destination)
        }
        refreshModificationDate()
        isDirty = false
    }

    /// Writes the text as UTF-8 a chunk at a time into a temporary file next
    /// to `destination`, then renames it into place with the old file's
    /// permissions, as `Data.write(options: .atomic)` does. Converted in one
    /// piece, a large file took a buffer its size on every autosave.
    private func write(to destination: URL) throws {
        let text = storage.string as NSString
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).pulse-save")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: destination.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            var buffer = [UInt8](repeating: 0, count: 3 * 65_536)
            var location = 0
            while location < text.length {
                let range = NSRange(location: location, length: min(65_536, text.length - location))
                var used = 0
                var remaining = NSRange()
                text.getBytes(&buffer, maxLength: buffer.count, usedLength: &used, encoding: String.Encoding.utf8.rawValue,
                              range: range, remaining: &remaining)
                // It stops before half a surrogate pair split by the chunk (the
                // next chunk starts there) and at a lone one (nothing converts).
                guard used > 0 else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
                try handle.write(contentsOf: buffer[0..<used])
                location = remaining.length > 0 ? remaining.location : NSMaxRange(range)
            }
            if let mode = try? FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
            }
            guard rename(temp.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
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
        // Refilled in place: a new array on every keystroke in a large file
        // would stay in the footprint for seconds after it is freed.
        lineStarts.removeAll(keepingCapacity: true)
        lineStarts.append(0)
        let chunk = 16_384
        var buffer = [unichar](repeating: 0, count: chunk)
        var position = 0
        while position < length {
            let count = min(chunk, length - position)
            text.getCharacters(&buffer, range: NSRange(location: position, length: count))
            for i in 0..<count where buffer[i] == 10 {
                lineStarts.append(position + i + 1)
            }
            position += count
        }
        linesValid = true
    }
}

extension NSString {
    /// How many bytes `range` takes as UTF-8; nil if it can't be converted
    /// (a lone surrogate).
    func utf8Count(in range: NSRange) -> Int? {
        var count = 0
        var remaining = NSRange()
        getBytes(nil, maxLength: Int.max, usedLength: &count, encoding: String.Encoding.utf8.rawValue, range: range, remaining: &remaining)
        return remaining.length == 0 ? count : nil
    }

    /// The UTF-8 bytes of `range`, converted straight into one buffer of the
    /// right size. `data(using:)`, `write(to:atomically:encoding:)` and the
    /// pasteboard first convert into a buffer of 3 bytes a character, the
    /// largest allocation a big file otherwise causes. The buffer is its own
    /// pages, given back the moment the data is released: freed malloc
    /// memory this size stays in the footprint for seconds.
    func utf8Data(in range: NSRange) -> Data? {
        guard let count = utf8Count(in: range) else { return nil }
        guard count > 0 else { return Data() }
        var address: vm_address_t = 0
        guard vm_allocate(mach_task_self_, &address, vm_size_t(count), VM_FLAGS_ANYWHERE) == KERN_SUCCESS,
              let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return nil }
        let data = Data(bytesNoCopy: pointer, count: count, deallocator: .virtualMemory)
        let converted = getBytes(pointer, maxLength: count, usedLength: nil, encoding: String.Encoding.utf8.rawValue,
                                 range: range, remaining: nil)
        return converted ? data : nil
    }
}
