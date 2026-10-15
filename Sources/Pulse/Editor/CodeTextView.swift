import AppKit

/// NSTextView tuned for code: spaces for tabs, auto-indent, line comments,
/// block indent/outdent and a current-line highlight.
final class CodeTextView: NSTextView {
    var indentWidth = 4
    var lineComment: String?

    private var indentUnit: String { String(repeating: " ", count: indentWidth) }
    private var nsText: NSString { string as NSString }

    // MARK: Current line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
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

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
    }

    // MARK: Typing

    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0, nsText.substring(with: selectedRange()).contains("\n") {
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
        transformSelectedLines { lines in
            lines.map { line in
                if right { return line.isEmpty ? line : indentUnit + line }
                var trimmed = Substring(line)
                var removed = 0
                while removed < indentWidth, trimmed.first == " " {
                    trimmed = trimmed.dropFirst()
                    removed += 1
                }
                if removed == 0, trimmed.first == "\t" { trimmed = trimmed.dropFirst() }
                return String(trimmed)
            }
        }
    }

    /// Adds or removes the language's line comment on the selected lines.
    func toggleLineComment() {
        guard let token = lineComment else { NSSound.beep(); return }
        transformSelectedLines { lines in
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !nonEmpty.isEmpty else { return lines }
            let allCommented = nonEmpty.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(token)
            }
            if allCommented {
                return lines.map { line in
                    guard let range = line.range(of: token) else { return line }
                    var result = line
                    var end = range.upperBound
                    if end < result.endIndex, result[end] == " " { end = result.index(after: end) }
                    result.removeSubrange(range.lowerBound..<end)
                    return result
                }
            }
            let indent = nonEmpty.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let index = line.index(line.startIndex, offsetBy: indent)
                return String(line[..<index]) + token + " " + String(line[index...])
            }
        }
    }

    private func transformSelectedLines(_ transform: ([String]) -> [String]) {
        let selection = selectedRange()
        var range = nsText.lineRange(for: selection)
        // A selection ending at column 0 of a line does not include that line.
        if selection.length > 0, NSMaxRange(selection) == range.location + range.length,
           NSMaxRange(selection) > 0, nsText.character(at: NSMaxRange(selection) - 1) == 10 {
            range = nsText.lineRange(for: NSRange(location: selection.location, length: selection.length - 1))
        }
        let block = nsText.substring(with: range)
        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        let replaced = transform(lines).joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        guard replaced != block else { return }
        insertText(replaced, replacementRange: range)
        let newLength = (replaced as NSString).length - (hasTrailingNewline ? 1 : 0)
        setSelectedRange(NSRange(location: range.location, length: max(0, newLength)))
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
