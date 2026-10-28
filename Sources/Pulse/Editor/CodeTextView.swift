import AppKit

/// NSTextView tuned for code: spaces for tabs, auto-indent, line comments,
/// block indent/outdent, a current-line highlight and folding (Folding.swift).
final class CodeTextView: NSTextView {
    var indentWidth = 4
    var lineComment: String?
    /// Took keyboard focus: its pane becomes the one commands go to.
    var onFocus: (() -> Void)?
    /// Says why an edit, copy or paste didn't happen (the status bar shows it).
    var onRefuse: ((String) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    // MARK: Read only (Document.isReadOnly sets isEditable)

    /// Undo and Redo would change a read-only file, so it has none while locked.
    override var undoManager: UndoManager? { isEditable ? super.undoManager : nil }

    /// Typing into a read-only file says why nothing happens. Keys that only
    /// move the caret, Escape and shortcuts work as usual.
    override func keyDown(with event: NSEvent) {
        if !isEditable, event.modifierFlags.isDisjoint(with: [.command, .control]),
           let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
           key != 0x1B, key == 0xF728 || !(0xF700...0xF8FF).contains(key) {
            refuse("This file is read-only. Click Read Only in the status bar to edit it.")
            return
        }
        super.keyDown(with: event)
    }

    private var indentUnit: String { String(repeating: " ", count: indentWidth) }
    private var nsText: NSString { string as NSString }

    // MARK: Drawing in strips (TextStrips.swift)

    private lazy var strips = TextStrips(view: self)
    /// For tests: the strips' frames, top to bottom.
    var stripFrames: [CGRect] { strips.frames }
    /// For tests: how many times a strip has drawn.
    var stripDraws: Int { strips.draws }

    /// AppKit then gives the view no backing of its own; the strips draw it.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        strips.update()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        strips.invalidate(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { strips.invalidateAll() } }
    }

    /// Laying out more of the text changes the view's height as the user
    /// scrolls, and with AppKit's default policy each change redrew the whole
    /// view: every strip, many times a second. A frame change moves no text;
    /// whatever does change asks for display itself.
    override var layerContentsRedrawPolicy: NSView.LayerContentsRedrawPolicy {
        get { .onSetNeedsDisplay }
        set {}
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        strips.update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        strips.update()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        strips.update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        strips.invalidateAll()
    }

    /// A scroll or a resize of the clip view changes what is visible without
    /// asking this view to redraw.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleRectChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(visibleRectChanged), name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func visibleRectChanged() {
        strips.update()
    }

    // MARK: Current line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCurrentLine(in: rect)
        drawFoldPlaceholders(in: rect)
        drawBlame(in: rect)
    }

    private func drawCurrentLine(in rect: NSRect) {
        guard selectedRange().length == 0, let layoutManager else { return }
        let location = min(selectedRange().location, nsText.length)
        var lineRect: NSRect
        if location == nsText.length && (nsText.length == 0 || nsText.character(at: nsText.length - 1) == 10) {
            lineRect = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        guard !lineRect.isEmpty else { return }
        lineRect.origin.x = 0
        lineRect.size.width = max(bounds.width, visibleRect.maxX)
        lineRect.origin.y += textContainerOrigin.y
        Theme.currentLine.setFill()
        lineRect.intersection(rect).fill()
    }

    // MARK: Blame (View › Blame)

    /// The file shown, whose blame (if on) is drawn after its lines.
    weak var document: Document?

    /// Who changed a line, when and why, after the first line with text of
    /// each run of lines from one commit, and after the caret's line. Only
    /// for the lines in `rect`: nothing is laid out or kept ahead.
    func blameAnnotations(in rect: NSRect) -> [(line: Int, label: String, point: NSPoint, uncommitted: Bool)] {
        guard let document, let blame = document.blame?.result, let layoutManager, let textContainer,
              let storage = textStorage, storage.length > 0 else { return [] }
        let text = nsText
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caret = selectedRange()
        let caretLine = caret.length == 0 ? document.line(at: caret.location) : -1
        let lineHeight = layoutManager.defaultLineHeight(for: Theme.blameFont)
        let now = Date().timeIntervalSince1970
        var annotations: [(line: Int, label: String, point: NSPoint, uncommitted: Bool)] = []
        var line = document.line(at: characters.location)
        let last = document.line(at: NSMaxRange(characters))
        while line <= last {
            let start = document.start(ofLine: line)
            // A folded block's lines take no space: carry on after it.
            if storage.isFolded(at: start - 1), let fold = storage.fold(at: start - 1) {
                line = document.line(at: NSMaxRange(fold)) + 1
                continue
            }
            if line == caretLine || startsBlameRun(line, in: blame, document: document),
               let label = blame.label(at: line, now: now) {
                let end = Folding.contentEnd(ofLineAt: start, in: text)
                var fragment = layoutManager.extraLineFragmentRect
                var x = fragment.minX
                if end > start {
                    let glyph = layoutManager.glyphIndexForCharacter(at: end - 1)
                    fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    x = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX
                } else if start < text.length {
                    fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
                    x = fragment.minX
                }
                // Past a folded block's "⋯".
                if storage.isFolded(at: end) { x += 32 }
                let point = NSPoint(x: origin.x + x + 24, y: origin.y + fragment.minY + (fragment.height - lineHeight) / 2)
                annotations.append((line, label, point, blame.commit(at: line) == GitBlame.uncommitted))
            }
            line += 1
        }
        return annotations
    }

    private func drawBlame(in rect: NSRect) {
        guard document?.blame?.result != nil else { return }
        let font = Theme.blameFont
        for annotation in blameAnnotations(in: rect) where annotation.point.x < rect.maxX {
            let color = annotation.uncommitted ? Theme.gitModified : Theme.blame
            (annotation.label as NSString).draw(at: annotation.point, withAttributes: [.font: font, .foregroundColor: color])
        }
    }

    /// Whether `line` is the first line with text in its run of lines from one commit.
    private func startsBlameRun(_ line: Int, in blame: GitBlame, document: Document) -> Bool {
        let commit = blame.commit(at: line)
        guard commit != GitBlame.unknown, !isBlankLine(line, in: document) else { return false }
        var previous = line - 1
        while previous >= 0, line - previous <= 200, blame.commit(at: previous) == commit {
            if !isBlankLine(previous, in: document) { return false }
            previous -= 1
        }
        return true
    }

    private func isBlankLine(_ line: Int, in document: Document) -> Bool {
        let text = nsText
        var index = document.start(ofLine: line)
        while index < text.length {
            switch text.character(at: index) {
            case 10, 13: return true
            case 32, 9: index += 1
            default: return false
            }
        }
        return true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let ranges = stillSelecting ? ranges : rangesAroundFolds(ranges)
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Must allow layout: with non-contiguous layout, a redraw that skips
        // layout paints the background but no glyphs.
        setNeedsDisplay(visibleRect)
    }

    /// Text typed after a fold would take `.folded` from the hidden
    /// character before it and vanish.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var attributes = newValue
            attributes[.folded] = nil
            super.typingAttributes = attributes
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if unfoldPlaceholder(at: point) { return }
        if let index = definitionClick(event, at: point) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: index, length: 0))
            onGoToDefinition?()
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Go to Definition (⌘-click)

    /// ⌘-click on a name: EditorViewController looks for its definition.
    var onGoToDefinition: (() -> Void)?

    /// The character clicked, when `event` is a ⌘-click on a name in a
    /// language Go to Definition knows. A ⌘-drag stays AppKit's (it adds a
    /// selection): this reads ahead to the mouse-up or the first drag.
    private func definitionClick(_ event: NSEvent, at point: NSPoint) -> Int? {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, event.clickCount == 1,
              onGoToDefinition != nil, document?.language?.definitions.isEmpty == false,
              let layoutManager, let textContainer, let window else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layoutManager.characterIndex(for: local, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard nsText.isIdentifierCharacter(at: index), nsText.identifierRange(at: index) != nil,
              layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).contains(local),
              window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged])?.type == .leftMouseUp else { return nil }
        return index
    }

    override func moveRight(_ sender: Any?) { if !stepOverFold(forward: true) { super.moveRight(sender) } }
    override func moveForward(_ sender: Any?) { if !stepOverFold(forward: true) { super.moveForward(sender) } }
    override func moveLeft(_ sender: Any?) { if !stepOverFold(forward: false) { super.moveLeft(sender) } }
    override func moveBackward(_ sender: Any?) { if !stepOverFold(forward: false) { super.moveBackward(sender) } }

    /// AppKit's text checking (spelling, candidates, correction bubbles; all
    /// off here) asks for the selected text on every selection change, twice,
    /// and for each range of every change, and NSTextView answers with
    /// copies: Select All in a 14 MB file briefly cost 85 MB, and Indent on
    /// its 100,000 lines made 100,000 of them. It gets nothing.
    @objc(annotatedSubstringForProposedRange:actualRange:)
    func annotatedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    // MARK: Large changes

    /// Changes spanning more characters than this get Pulse's own Undo, and
    /// selections this long its own Copy and Paste.
    static let largeChange = 262_144
    /// The pasteboard copies what goes through it twice more inside Pulse.
    static let maxClipboardBytes = 8 * 1024 * 1024

    private func refuse(_ message: String) {
        NSSound.beep()
        onRefuse?(message)
    }

    /// Before a change NSTextView copies everything from the first changed
    /// character to the last for Undo, into a growable string at 3 bytes a
    /// character and then again: Replace All or Delete in a 14 MB file took
    /// 57 MB more. A large change keeps only the text each range replaces
    /// (a few bytes a match for Replace All, nothing for Indent), as native
    /// strings at 1 byte an ASCII character. When that is itself large
    /// (Delete All, pasting over everything), the older history goes first,
    /// so Undo holds at most one such copy of a file.
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        // Pulse's own commands (comment, indent, a large paste) come here too.
        guard isEditable else { return false }
        let ranges = affectedRanges.map(\.rangeValue)
        unfoldPartlyChanged(ranges)
        guard let strings = replacementStrings, strings.count == ranges.count, let first = ranges.first, let last = ranges.last,
              let storage = textStorage else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        let lengths = strings.map { ($0 as NSString).length }
        let inserted = lengths.reduce(0, +)
        let removed = ranges.reduce(0) { $0 + $1.length }
        let undoing = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        if inserted > removed, storage.length + inserted - removed > Document.maxBytes, !undoing {
            refuse("Pulse edits files up to 16 MB. This change would make the file larger.")
            return false
        }
        guard allowsUndo, let undoManager, undoManager.isUndoRegistrationEnabled else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        // Large insertions too: NSTextView's Undo of one would copy the text
        // it removes. Its own Undo and Redo register their inverse past this
        // method, so they stay its own.
        let large = NSMaxRange(last) - first.location > CodeTextView.largeChange || inserted > CodeTextView.largeChange
        guard isReplacing || (large && !undoing) else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        // NSTextView makes its copy whenever it allows Undo, registered or not.
        allowsUndo = false
        let allowed = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        allowsUndo = true
        guard allowed else { return false }
        breakUndoCoalescing()
        if !undoing, removed > CodeTextView.largeChange { undoManager.removeAllActions() }
        let old = ranges.map(copyText)
        var shift = 0
        let after = zip(ranges, lengths).map { range, length -> NSRange in
            defer { shift += length - range.length }
            return NSRange(location: range.location + shift, length: length)
        }
        // The storage, not this view: the file may be open in another pane,
        // and this one may close first.
        undoManager.registerUndo(withTarget: storage) { storage in
            guard let view = storage.layoutManagers.lazy.compactMap({ $0.firstTextView as? CodeTextView }).first,
                  let growth = view.replace(after, with: old) else { return }
            let start = after[0].location
            view.setSelectedRange(NSRange(location: start, length: NSMaxRange(after[after.count - 1]) + growth - start))
            view.scrollRangeToVisible(NSRange(location: start, length: 0))
        }
        return true
    }

    /// Set while `replace` makes a change: Pulse registers its Undo.
    private var isReplacing = false

    /// `range` as a native string, copied a chunk at a time: 1 byte an ASCII
    /// character, where an NSString substring of the storage takes 2 or 3.
    private func copyText(in range: NSRange) -> String {
        let text = nsText
        guard range.length > 4_096 else { return text.substring(with: range) }
        var result = ""
        result.reserveCapacity(range.length)
        var buffer = [unichar](repeating: 0, count: 16_384)
        var location = range.location
        while location < NSMaxRange(range) {
            var length = min(buffer.count, NSMaxRange(range) - location)
            text.getCharacters(&buffer, range: NSRange(location: location, length: length))
            // Keep a surrogate pair in one chunk.
            if length > 1, location + length < NSMaxRange(range), UTF16.isLeadSurrogate(buffer[length - 1]) { length -= 1 }
            result += buffer.withUnsafeBufferPointer { String(decoding: $0.prefix(length), as: UTF16.self) }
            location += length
        }
        return result
    }

    /// Replaces each range (in order, not overlapping) with its string, as
    /// one change with one Undo. Returns how much longer the text got, or
    /// nil if the change was refused.
    private func replace(_ ranges: [NSRange], with strings: [String]) -> Int? {
        guard let storage = textStorage else { return nil }
        isReplacing = true
        let allowed = shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: strings)
        isReplacing = false
        guard allowed else { return nil }
        let wasEmpty = storage.length == 0
        var growth = 0
        storage.beginEditing()
        for (range, string) in zip(ranges, strings).reversed() {
            storage.replaceCharacters(in: range, with: string)
            growth += (string as NSString).length - range.length
        }
        if wasEmpty { storage.setAttributes(typingAttributes, range: NSRange(location: 0, length: storage.length)) }
        storage.endEditing()
        didChangeText()
        return growth
    }

    /// Copy, Cut and drags of a large selection. The pasteboard's own
    /// conversion goes through a buffer of 3 bytes a character.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let selection = selectedRange()
        guard selectedRanges.count == 1, selection.length > CodeTextView.largeChange, types.contains(where: CodeTextView.isPlainText),
              let count = nsText.utf8Count(in: selection) else {
            return super.writeSelection(to: pboard, types: types)
        }
        guard count <= CodeTextView.maxClipboardBytes else {
            refuse("Pulse copies up to 8 MB at a time. For more, use pbcopy in the terminal.")
            return false
        }
        guard let data = nsText.utf8Data(in: selection) else { return super.writeSelection(to: pboard, types: types) }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setData(data, forType: .string)
    }

    /// Paste and drops of a large string: NSTextView reads one into four copies.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard CodeTextView.isPlainText(type), let data = pboard.data(forType: .string),
              data.count > CodeTextView.largeChange else {
            return super.readSelection(from: pboard, type: type)
        }
        // True when refused too: NSTextView would try the next type.
        guard data.count <= CodeTextView.maxClipboardBytes else {
            refuse("Pulse pastes up to 8 MB at a time.")
            return true
        }
        let text = String(decoding: data, as: UTF8.self)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: text), let storage = textStorage else { return true }
        let length = (text as NSString).length
        storage.replaceCharacters(in: range, with: text)
        storage.setAttributes(typingAttributes, range: NSRange(location: range.location, length: length))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + length, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// NSTextView reads and writes plain text as the legacy string type.
    private static func isPlainText(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .string || type.rawValue == "NSStringPboardType"
    }

    // MARK: Typing

    override func insertTab(_ sender: Any?) {
        if nsText.range(of: "\n", options: .literal, range: selectedRange()).location != NSNotFound {
            shiftLines(right: true)
            return
        }
        let location = selectedRange().location
        let lineStart = nsText.lineRange(for: NSRange(location: location, length: 0)).location
        let column = location - lineStart
        let spaces = indentWidth - (column % indentWidth)
        insertText(String(repeating: " ", count: spaces), replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        shiftLines(right: false)
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let line = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        var indentEnd = line.location
        while indentEnd < selection.location {
            let c = nsText.character(at: indentEnd)
            if c == 32 || c == 9 { indentEnd += 1 } else { break }
        }
        let indent = nsText.substring(with: NSRange(location: line.location, length: indentEnd - line.location))
        let previous = previousNonSpace(before: selection.location, lineStart: line.location)
        let next: unichar = NSMaxRange(selection) < nsText.length ? nsText.character(at: NSMaxRange(selection)) : 0

        let opens: [unichar: unichar] = [123: 125, 91: 93, 40: 41] // { } [ ] ( )
        if let previous, let closer = opens[previous] {
            if next == closer {
                let inserted = "\n" + indent + indentUnit + "\n" + indent
                insertText(inserted, replacementRange: selection)
                let caret = selection.location + 1 + (indent as NSString).length + (indentUnit as NSString).length
                setSelectedRange(NSRange(location: caret, length: 0))
            } else {
                insertText("\n" + indent + indentUnit, replacementRange: selection)
            }
            return
        }
        if previous == 58 && lineComment == "#" { // ':' opens a Python block
            insertText("\n" + indent + indentUnit, replacementRange: selection)
            return
        }
        insertText("\n" + indent, replacementRange: selection)
    }

    private func previousNonSpace(before location: Int, lineStart: Int) -> unichar? {
        var i = location - 1
        while i >= lineStart {
            let c = nsText.character(at: i)
            if c != 32 && c != 9 { return c }
            i -= 1
        }
        return nil
    }

    // MARK: Line commands

    /// Indents or outdents every line touched by the selection.
    func shiftLines(right: Bool) {
        let text = nsText
        editSelectedLines { line in
            if right { return line.length == 0 ? nil : (NSRange(location: line.location, length: 0), indentUnit) }
            var removed = 0
            while removed < min(indentWidth, line.length), text.character(at: line.location + removed) == 32 { removed += 1 }
            if removed == 0, line.length > 0, text.character(at: line.location) == 9 { removed = 1 }
            return removed == 0 ? nil : (NSRange(location: line.location, length: removed), "")
        }
    }

    /// Adds or removes the language's line comment on the selected lines.
    func toggleLineComment() {
        guard let token = lineComment else { NSSound.beep(); return }
        let text = nsText
        let tokenLength = (token as NSString).length
        // Where a line's text starts; nil for a blank line.
        func textStart(_ line: NSRange) -> Int? {
            let found = text.rangeOfCharacter(from: CharacterSet.whitespaces.inverted, options: [], range: line)
            return found.location == NSNotFound ? nil : found.location
        }
        var allCommented = true
        var indent = Int.max
        forEachLine(in: selectedLines()) { line in
            guard let start = textStart(line) else { return }
            if start + tokenLength > NSMaxRange(line)
                || text.compare(token, options: .literal, range: NSRange(location: start, length: tokenLength)) != .orderedSame {
                allCommented = false
            }
            var spaces = 0
            while spaces < line.length, [32, 9].contains(text.character(at: line.location + spaces)) { spaces += 1 }
            indent = min(indent, spaces)
        }
        guard indent != .max else { return }
        editSelectedLines { line in
            guard let start = textStart(line) else { return nil }
            if allCommented {
                var length = tokenLength
                if start + length < NSMaxRange(line), text.character(at: start + length) == 32 { length += 1 }
                return (NSRange(location: start, length: length), "")
            }
            return (NSRange(location: line.location + indent, length: 0), token + " ")
        }
    }

    /// The lines the selection touches, with their line breaks. A selection
    /// ending at column 0 of a line does not include that line.
    private func selectedLines() -> NSRange {
        let selection = selectedRange()
        let range = nsText.lineRange(for: selection)
        if selection.length > 0, NSMaxRange(selection) == range.location + range.length,
           NSMaxRange(selection) > 0, nsText.character(at: NSMaxRange(selection) - 1) == 10 {
            return nsText.lineRange(for: NSRange(location: selection.location, length: selection.length - 1))
        }
        return range
    }

    /// Calls `body` with each line in `range`, without its "\n".
    private func forEachLine(in range: NSRange, _ body: (NSRange) -> Void) {
        let text = nsText
        var start = range.location
        while start < NSMaxRange(range) {
            let newline = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: NSMaxRange(range) - start))
            let end = newline.location == NSNotFound ? NSMaxRange(range) : newline.location
            body(NSRange(location: start, length: end - start))
            start = end + 1
        }
    }

    /// Makes `edit`'s replacement in each selected line, as one change, then
    /// selects the lines. Edits in place, without copying the lines, so it
    /// works on a whole large file.
    private func editSelectedLines(_ edit: (NSRange) -> (NSRange, String)?) {
        let lines = selectedLines()
        var ranges: [NSRange] = []
        var strings: [String] = []
        forEachLine(in: lines) { line in
            guard let (range, string) = edit(line) else { return }
            ranges.append(range)
            strings.append(string)
        }
        guard !ranges.isEmpty else { return }
        let trailingNewline = nsText.character(at: NSMaxRange(lines) - 1) == 10
        guard let growth = replace(ranges, with: strings) else { return }
        setSelectedRange(NSRange(location: lines.location, length: max(0, lines.length + growth - (trailingNewline ? 1 : 0))))
    }

    /// Moves the caret to a one-based line number and centers it.
    func goToLine(_ number: Int, in document: Document) {
        let line = max(0, min(number - 1, document.lineCount - 1))
        let location = document.start(ofLine: line)
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(NSRange(location: location, length: 0))
        centerSelectionInVisibleArea(nil)
    }
}
