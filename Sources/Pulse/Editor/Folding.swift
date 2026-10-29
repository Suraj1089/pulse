import AppKit

extension NSAttributedString.Key {
    /// On the characters a fold hides: how many folds hide them (an Int), so
    /// a block folded inside a folded block stays folded when the outer one
    /// opens. A text storage attribute, so a fold moves with edits and every
    /// pane showing the file folds alike. Never typed (CodeTextView strips it
    /// from its typing attributes), never saved.
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
/// (often its closing brace) stays visible. `FoldingLayoutManager` gives
/// the lines it hides no height and doesn't draw them, so a folded block
/// takes no space. Folds never touch: the line break that ends a block's last
/// line stays visible, so the hidden run around a character is the outermost
/// fold hiding it.
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
    /// The outermost fold hiding the character at `index`, if it is hidden:
    /// the run of hidden text around it.
    func fold(at index: Int) -> NSRange? {
        guard isFolded(at: index) else { return nil }
        let all = NSRange(location: 0, length: length)
        var run = NSRange()
        // Nested folds split the run by depth; one step per depth change.
        var start = index
        while start > 0, attribute(.folded, at: start - 1, longestEffectiveRange: &run, in: all) != nil { start = run.location }
        var end = index
        while end < length, attribute(.folded, at: end, longestEffectiveRange: &run, in: all) != nil { end = NSMaxRange(run) }
        return NSRange(location: start, length: end - start)
    }

    func isFolded(at index: Int) -> Bool {
        index >= 0 && index < length && attribute(.folded, at: index, effectiveRange: nil) != nil
    }

    /// Folds `ranges` (`by` 1) or opens one level of folding in them (-1).
    /// Like any attribute change, every layout manager on this text lays
    /// those lines out again.
    func changeFolding(by delta: Int, in ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }
        beginEditing()
        for range in ranges {
            var runs: [(NSRange, Int)] = []
            enumerateAttribute(.folded, in: range) { value, run, _ in runs.append((run, (value as? Int) ?? 0)) }
            for (run, depth) in runs {
                if depth + delta > 0 { addAttribute(.folded, value: depth + delta, range: run) } else { removeAttribute(.folded, range: run) }
            }
        }
        endEditing()
    }
}

/// The editor panes' layout manager: lays folded text out as nothing. A line
/// that starts in hidden text gets no height, and hidden glyphs aren't drawn.
/// Each hidden line stays a line of its own with its own glyphs, so typing
/// on a folded block's first line lays out that line alone (folding with null
/// glyphs and zero-width line breaks made the block one line: each keystroke
/// typeset all of it, and the shared typesetter kept buffers that large).
final class FoldingLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the lines that have height. By line, not by character: AppKit
    /// draws whole lines, and the line break after a fold ends a hidden line.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, glyphsToShow.length > 0 else { return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin) }
        var hasFolds = false
        storage.enumerateAttribute(.folded, in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil),
                                   options: .longestEffectiveRangeNotRequired) { value, _, stop in
            if value != nil {
                hasFolds = true
                stop.pointee = true
            }
        }
        guard hasFolds else { return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin) }
        var shownFrom = glyphsToShow.location
        func drawShown(upTo end: Int) {
            if end > shownFrom { super.drawGlyphs(forGlyphRange: NSRange(location: shownFrom, length: end - shownFrom), at: origin) }
        }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphs, _ in
            guard rect.height == 0 else { return }
            drawShown(upTo: max(shownFrom, glyphs.location))
            shownFrom = max(shownFrom, NSMaxRange(glyphs))
        }
        drawShown(upTo: NSMaxRange(glyphsToShow))
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage, glyphRange.length > 0,
              storage.isFolded(at: characterIndexForGlyph(at: glyphRange.location)) else { return false }
        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
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
        guard let storage = textStorage else { return }
        let text = foldText
        var regions: [NSRange] = []
        var start = 0
        while start < text.length {
            if let region = Folding.region(ofLineAt: start, in: text, tabWidth: indentWidth) {
                if !storage.isFolded(at: region.location) { regions.append(region) }
                start = NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(region), length: 0)))
            } else {
                start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            }
        }
        fold(regions)
    }

    func unfoldAll() {
        guard let storage = textStorage else { return }
        var folds: [NSRange] = []
        storage.enumerateAttribute(.folded, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            if value != nil { folds.append(run) }
        }
        storage.changeFolding(by: -Int.max, in: folds) // every level
        foldsDidChange()
    }

    private func fold(_ regions: [NSRange]) {
        guard let storage = textStorage, !regions.isEmpty else { return }
        storage.changeFolding(by: 1, in: regions)
        // A caret left in hidden text goes to the end of its fold's first line.
        let caret = selectedRange()
        if let fold = regions.first(where: { NSIntersectionRange($0, caret).length > 0 || ($0.location < caret.location && caret.location <= NSMaxRange($0)) }) {
            setSelectedRange(NSRange(location: fold.location, length: 0))
        }
        foldsDidChange()
    }

    /// Opens one level: a block folded inside this one stays folded.
    private func unfold(_ range: NSRange) {
        textStorage?.changeFolding(by: -1, in: [range])
        foldsDidChange()
    }

    /// Every pane showing this text redraws its text and gutter: the lines
    /// below the fold moved, and laying them out again doesn't redraw them.
    private func foldsDidChange() {
        for layoutManager in textStorage?.layoutManagers ?? [] {
            guard let textView = layoutManager.firstTextView else { continue }
            textView.setNeedsDisplay(textView.visibleRect)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }

    /// Keeps the caret out of folded text. A click or End past a fold lands
    /// at the end of the folded line, as in VS Code, and a key that moves the
    /// caret into one (⌥→) goes past it. A selection made with keys or the
    /// mouse that reaches into a fold takes it in whole (⇧→ at the end of a
    /// folded line, a triple-click on it). A jump into hidden text (Go to
    /// Line, a search match) unfolds it, as does a selection that takes in
    /// part of a fold otherwise.
    func rangesAroundFolds(_ ranges: [NSValue]) -> [NSValue] {
        guard let storage = textStorage, storage.length > 0 else { return ranges }
        let previous = selectedRange().location
        return ranges.map { value in
            var range = value.rangeValue
            if range.length > 0 {
                if handlingInput { range = takingInFolds(range) }
                unfoldPartlyCovered(by: range)
                return NSValue(range: range)
            }
            // Folds inside folds open from the outside in, until the caret shows.
            while range.location > 0, let fold = storage.fold(at: range.location - 1) {
                if range.location == NSMaxRange(fold) { return NSValue(range: NSRange(location: fold.location, length: 0)) }
                if handlingInput {
                    let forward = previous <= fold.location && NSMaxRange(fold) < storage.length
                    return NSValue(range: NSRange(location: forward ? NSMaxRange(fold) + 1 : fold.location, length: 0))
                }
                unfold(fold)
            }
            return value
        }
    }

    /// `range` widened over each fold it reaches into from outside.
    private func takingInFolds(_ range: NSRange) -> NSRange {
        guard let storage = textStorage else { return range }
        var start = range.location
        var end = NSMaxRange(range)
        if let fold = storage.fold(at: start), fold.location < start, end >= NSMaxRange(fold) { start = fold.location }
        if let fold = storage.fold(at: end - 1), end < NSMaxRange(fold), start <= fold.location { end = NSMaxRange(fold) }
        return NSRange(location: start, length: end - start)
    }

    /// Unfolds each fold `range` takes in only part of (at either end).
    private func unfoldPartlyCovered(by range: NSRange) {
        guard let storage = textStorage else { return }
        for index in [range.location, NSMaxRange(range) - 1] {
            while let fold = storage.fold(at: index), NSIntersectionRange(fold, range).length < fold.length { unfold(fold) }
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

    /// An edit that takes away part of a fold unfolds it first, as does one
    /// right after its hidden text: deleting the line break there (⌫ at the
    /// start of the next line) would join that line to a hidden one. One that
    /// removes a whole fold, or inserts into one (Indent on a selection
    /// around it), leaves it folded.
    func unfoldPartlyChanged(_ ranges: [NSRange]) {
        guard let storage = textStorage else { return }
        for range in ranges {
            while let fold = storage.fold(at: range.location - 1), NSMaxRange(fold) == range.location { unfold(fold) }
            if range.length > 0 { unfoldPartlyCovered(by: range) }
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
            // A fold nested in one shown here, or one this run continues.
            guard value != nil, NSMaxRange(run) > NSMaxRange(placeholders.last?.fold ?? NSRange()),
                  let fold = storage.fold(at: run.location), fold.location >= characters.location else { return }
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
