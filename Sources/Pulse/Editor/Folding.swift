import AppKit

extension NSAttributedString.Key {
    /// On the characters a fold hides. A text storage attribute, so a fold
    /// moves with edits and every pane showing the file folds alike. Never
    /// typed (CodeTextView strips it from its typing attributes), never saved.
    static let folded = NSAttributedString.Key("PulseFolded")
}

/// Code folding by indentation, as VS Code folds files that have no
/// language-specific folding: a line starts a block when the next non-blank
/// line is indented deeper, and the block runs to the last line before one
/// indented no deeper. Nothing is worked out ahead of time: the gutter checks
/// the lines it draws, and a block's end is found only when it is folded.
///
/// A fold is the `.folded` attribute on what it hides, from the header's line
/// break to the end of the block's last line, so the line after the block
/// (often its closing brace) stays visible. `FoldingLayoutDelegate` lays
/// those characters out as nothing, so a folded block takes no lines.
enum Folding {
    /// Where the line starting at `start` ends, before its line break.
    static func contentEnd(ofLineAt start: Int, in text: NSString) -> Int {
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
        return contentsEnd
    }

    /// Where the line after the one starting at `start` starts.
    private static func nextLine(after start: Int, in text: NSString) -> Int {
        var end = 0
        text.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: start, length: 0))
        return end
    }

    /// The indentation of the line starting at `start`, in columns (a tab
    /// reaches the next multiple of `tabWidth`); nil for a blank line.
    static func indent(ofLineAt start: Int, in text: NSString, tabWidth: Int) -> Int? {
        var column = 0
        var index = start
        while index < text.length {
            switch text.character(at: index) {
            case 32: column += 1
            case 9: column += tabWidth - column % tabWidth
            case 10, 13: return nil
            default: return column
            }
            index += 1
        }
        return nil
    }

    /// Whether the line starting at `start` starts a block. Looks only as
    /// far as the next non-blank line, so the gutter can ask for each line
    /// it draws.
    static func startsBlock(lineAt start: Int, in text: NSString, tabWidth: Int) -> Bool {
        guard let level = indent(ofLineAt: start, in: text, tabWidth: tabWidth) else { return false }
        var line = nextLine(after: start, in: text)
        for _ in 0..<200 where line < text.length {
            if let next = indent(ofLineAt: line, in: text, tabWidth: tabWidth) { return next > level }
            line = nextLine(after: line, in: text)
        }
        return false
    }

    /// What folding the line starting at `start` hides, or nil if the line
    /// doesn't start a block. Reads to the end of the block, so it is for
    /// commands, not drawing. Blank lines at the end of a block stay visible.
    static func region(ofLineAt start: Int, in text: NSString, tabWidth: Int) -> NSRange? {
        guard let level = indent(ofLineAt: start, in: text, tabWidth: tabWidth) else { return nil }
        let headerEnd = contentEnd(ofLineAt: start, in: text)
        var lastEnd: Int?
        var line = nextLine(after: start, in: text)
        while line < text.length {
            if let next = indent(ofLineAt: line, in: text, tabWidth: tabWidth) {
                if next <= level { break }
                lastEnd = contentEnd(ofLineAt: line, in: text)
            }
            line = nextLine(after: line, in: text)
        }
        guard let lastEnd, lastEnd > headerEnd else { return nil }
        return NSRange(location: headerEnd, length: lastEnd - headerEnd)
    }
}

extension NSTextStorage {
    /// The fold hiding the character at `index`, if it is folded.
    func fold(at index: Int) -> NSRange? {
        guard index >= 0, index < length else { return nil }
        var range = NSRange()
        let value = attribute(.folded, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: length))
        return value == nil ? nil : range
    }

    func isFolded(at index: Int) -> Bool {
        index >= 0 && index < length && attribute(.folded, at: index, effectiveRange: nil) != nil
    }

    /// Folds or unfolds `ranges`, and has every layout manager on this text
    /// generate their glyphs again (an attribute change alone only lays
    /// them out again).
    func setFolded(_ folded: Bool, in ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }
        beginEditing()
        for range in ranges {
            if folded { addAttribute(.folded, value: true, range: range) } else { removeAttribute(.folded, range: range) }
        }
        endEditing()
        for layoutManager in layoutManagers {
            for range in ranges {
                layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
                layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            }
        }
    }
}

/// Lays folded text out as nothing: its glyphs are null, and its line
/// breaks and tabs zero-width control characters, so a folded block adds no
/// line fragments. Stateless: one instance serves every editor pane.
final class FoldingLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    static let shared = FoldingLayoutDelegate()

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        let first = characterIndexes[0]
        let span = NSRange(location: first, length: characterIndexes[glyphRange.length - 1] - first + 1)
        var hasFolds = false
        storage.enumerateAttribute(.folded, in: span, options: .longestEffectiveRangeNotRequired) { value, _, stop in
            if value != nil {
                hasFolds = true
                stop.pointee = true
            }
        }
        guard hasFolds else { return 0 }
        let changed = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: glyphRange.length)
        defer { changed.deallocate() }
        for i in 0..<glyphRange.length {
            let property = properties[i]
            if storage.isFolded(at: characterIndexes[i]) {
                changed[i] = property.contains(.controlCharacter) ? .controlCharacter : .null
            } else {
                changed[i] = property
            }
        }
        layoutManager.setGlyphs(glyphs, properties: changed, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        layoutManager.textStorage?.isFolded(at: charIndex) == true ? .zeroAdvancement : action
    }
}

// MARK: - Folding in the editor

extension CodeTextView {
    private var foldText: NSString { string as NSString }

    /// Folds the block the caret's line starts or, failing that, the
    /// innermost block around it (View › Folding › Fold, ⌥⌘[).
    func foldAtCaret() {
        let text = foldText
        let caret = min(selectedRange().location, text.length)
        var start = text.lineRange(for: NSRange(location: caret, length: 0)).location
        if let region = Folding.region(ofLineAt: start, in: text, tabWidth: indentWidth) {
            if textStorage?.isFolded(at: region.location) != true { fold([region]) }
            return
        }
        // Up to the nearest less indented line whose block holds the caret.
        var level = Folding.indent(ofLineAt: start, in: text, tabWidth: indentWidth) ?? Int.max
        for _ in 0..<10_000 where start > 0 {
            start = text.lineRange(for: NSRange(location: start - 1, length: 0)).location
            guard let indent = Folding.indent(ofLineAt: start, in: text, tabWidth: indentWidth), indent < level else { continue }
            if let region = Folding.region(ofLineAt: start, in: text, tabWidth: indentWidth),
               region.location < caret, caret <= NSMaxRange(region) {
                fold([region])
                return
            }
            level = indent
        }
    }

    /// Unfolds the fold on the caret's line (⌥⌘]).
    func unfoldAtCaret() {
        let text = foldText
        let caret = min(selectedRange().location, text.length)
        let start = text.lineRange(for: NSRange(location: caret, length: 0)).location
        if let fold = textStorage?.fold(at: Folding.contentEnd(ofLineAt: start, in: text)) { unfold(fold) }
    }

    /// The gutter's chevron: folds or unfolds the block the line starts.
    func toggleFold(atLineStart start: Int) {
        let text = foldText
        if let fold = textStorage?.fold(at: Folding.contentEnd(ofLineAt: start, in: text)) {
            unfold(fold)
        } else if let region = Folding.region(ofLineAt: start, in: text, tabWidth: indentWidth) {
            fold([region])
        }
    }

    /// Folds every outermost block (a block inside one is hidden with it).
    func foldAll() {
        let text = foldText
        var regions: [NSRange] = []
        var start = 0
        while start < text.length {
            if let region = Folding.region(ofLineAt: start, in: text, tabWidth: indentWidth) {
                regions.append(region)
                start = NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(region), length: 0)))
            } else {
                start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            }
        }
        fold(regions)
    }

    func unfoldAll() {
        guard let storage = textStorage, storage.length > 0 else { return }
        unfold(NSRange(location: 0, length: storage.length))
    }

    private func fold(_ regions: [NSRange]) {
        guard let storage = textStorage, !regions.isEmpty else { return }
        storage.setFolded(true, in: regions)
        // A caret left in hidden text goes to the end of its fold's first line.
        let caret = selectedRange()
        if let fold = regions.first(where: { NSIntersectionRange($0, caret).length > 0 || ($0.location < caret.location && caret.location <= NSMaxRange($0)) }) {
            setSelectedRange(NSRange(location: fold.location, length: 0))
        }
        foldsDidChange()
    }

    private func unfold(_ range: NSRange) {
        textStorage?.setFolded(false, in: [range])
        foldsDidChange()
    }

    /// Every pane showing this text redraws its gutter.
    private func foldsDidChange() {
        for layoutManager in textStorage?.layoutManagers ?? [] {
            layoutManager.firstTextView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }

    /// Keeps the caret out of folded text. A click or End past a fold lands
    /// at the end of the folded line, as in VS Code; a jump into hidden text
    /// (Go to Line, a search match) unfolds it, as does a selection that
    /// takes in part of a fold.
    func rangesAroundFolds(_ ranges: [NSValue]) -> [NSValue] {
        guard let storage = textStorage, storage.length > 0 else { return ranges }
        return ranges.map { value in
            let range = value.rangeValue
            if range.length > 0 {
                for index in [range.location, NSMaxRange(range) - 1] {
                    if let fold = storage.fold(at: index), NSIntersectionRange(fold, range).length < fold.length { unfold(fold) }
                }
                return value
            }
            guard range.location > 0, let fold = storage.fold(at: range.location - 1) else { return value }
            if range.location == NSMaxRange(fold) { return NSValue(range: NSRange(location: fold.location, length: 0)) }
            unfold(fold)
            return value
        }
    }

    /// Arrow keys step over a fold: right from the end of a folded line to
    /// the start of the next visible line, left from there back. True if the
    /// caret moved.
    func stepOverFold(forward: Bool) -> Bool {
        guard let storage = textStorage, selectedRanges.count == 1 else { return false }
        let caret = selectedRange()
        guard caret.length == 0 else { return false }
        if forward {
            guard let fold = storage.fold(at: caret.location), fold.location == caret.location,
                  NSMaxRange(fold) < storage.length else { return false }
            setSelectedRange(NSRange(location: NSMaxRange(fold) + 1, length: 0))
        } else {
            guard let fold = storage.fold(at: caret.location - 2), NSMaxRange(fold) == caret.location - 1 else { return false }
            setSelectedRange(NSRange(location: fold.location, length: 0))
        }
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// An edit that takes away part of a fold unfolds it first. One that
    /// removes a whole fold, or inserts into one (Indent on a selection
    /// around it), leaves it folded.
    func unfoldPartlyChanged(_ ranges: [NSRange]) {
        guard let storage = textStorage else { return }
        for range in ranges where range.length > 0 {
            for index in [range.location, NSMaxRange(range) - 1] {
                if let fold = storage.fold(at: index), NSIntersectionRange(fold, range).length < fold.length { unfold(fold) }
            }
        }
    }

    /// The "⋯" after each folded line in `rect`, with the fold it stands for.
    func foldPlaceholders(in rect: NSRect) -> [(fold: NSRange, rect: NSRect)] {
        guard let storage = textStorage, storage.length > 0, let layoutManager, let textContainer else { return [] }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var placeholders: [(fold: NSRange, rect: NSRect)] = []
        storage.enumerateAttribute(.folded, in: characters) { value, run, _ in
            guard value != nil, let fold = storage.fold(at: run.location), fold.location >= characters.location else { return }
            let glyph = layoutManager.glyphIndexForCharacter(at: fold.location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let height = min(line.height - 2, 16)
            let x = origin.x + line.minX + layoutManager.location(forGlyphAt: glyph).x + 6
            placeholders.append((fold, NSRect(x: x, y: origin.y + line.minY + (line.height - height) / 2, width: 26, height: height)))
        }
        return placeholders
    }

    func drawFoldPlaceholders(in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.editorFont, .foregroundColor: NSColor.secondaryLabelColor]
        let label = "⋯" as NSString
        let size = label.size(withAttributes: attributes)
        for placeholder in foldPlaceholders(in: rect) where placeholder.rect.intersects(rect) {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: placeholder.rect, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: placeholder.rect.midX - size.width / 2, y: placeholder.rect.midY - size.height / 2),
                       withAttributes: attributes)
        }
    }

    /// A click on a fold's "⋯" unfolds it. True if the click was one.
    func unfoldPlaceholder(at point: NSPoint) -> Bool {
        guard let hit = foldPlaceholders(in: visibleRect).first(where: { $0.rect.contains(point) }) else { return false }
        unfold(hit.fold)
        return true
    }
}
