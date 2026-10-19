import AppKit

/// Draws line numbers for the visible lines only, using the document's
/// cached line index, so the cost does not grow with file length. Right of
/// the numbers, a chevron folds a block: shown on folded lines, and on every
/// line that starts a block while the pointer is over the gutter.
final class LineNumberRuler: NSRulerView {
    weak var document: Document?
    private var digits = 0
    /// Width of the chevron column.
    static let foldColumn: CGFloat = 14
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        // Since macOS 14 views do not clip by default and the ruler floats
        // over the text. Without clipping, filling the dirty rect painted
        // over the code.
        clipsToBounds = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override var requiredThickness: CGFloat { ruleThickness }

    func updateThickness() {
        let count = max(3, String(document?.lineCount ?? 1).count)
        guard count != digits else { return }
        digits = count
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: Theme.gutterFont]).width
        ruleThickness = ceil(CGFloat(count) * digitWidth + 22 + LineNumberRuler.foldColumn)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let document else { return }

        Theme.editorBackground.setFill()
        NSRect(x: 0, y: rect.minY, width: ruleThickness, height: rect.height).fill()

        let text = textView.string as NSString
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let yOffset = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        let currentLine = document.line(at: min(textView.selectedRange().location, text.length))

        let normal: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: NSColor.secondaryLabelColor]
        let rightEdge = ruleThickness - 10 - LineNumberRuler.foldColumn
        let storage = textView.textStorage
        let tabWidth = (textView as? CodeTextView)?.indentWidth ?? 4

        var line = document.line(at: visible.location)
        let lastLine = document.lineCount - 1
        while line <= lastLine {
            let start = document.start(ofLine: line)
            if start > NSMaxRange(visible) { break }
            // A folded block's lines take no space: carry on after it.
            if let fold = storage?.fold(at: start - 1) {
                line = document.line(at: NSMaxRange(fold)) + 1
                continue
            }
            let fragment: NSRect
            if start >= text.length {
                fragment = layoutManager.extraLineFragmentRect
                if fragment.isEmpty { break }
            } else {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let label = String(line + 1) as NSString
            let attributes = line == currentLine ? current : normal
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + yOffset + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: rightEdge - size.width, y: y), withAttributes: attributes)
            let folded = line < lastLine && storage?.isFolded(at: document.start(ofLine: line + 1) - 1) == true
            if folded || (hovering && Folding.startsBlock(lineAt: start, in: text, tabWidth: tabWidth)) {
                drawChevron(folded: folded, at: NSPoint(x: ruleThickness - 4 - LineNumberRuler.foldColumn / 2,
                                                        y: fragment.minY + yOffset + fragment.height / 2))
            }
            line += 1
        }
    }

    /// › for a folded block, ⌄ for one that can fold.
    private func drawChevron(folded: Bool, at center: NSPoint) {
        let path = NSBezierPath()
        let size: CGFloat = 3.5
        if folded {
            path.move(to: NSPoint(x: center.x - size / 2, y: center.y - size))
            path.line(to: NSPoint(x: center.x + size / 2, y: center.y))
            path.line(to: NSPoint(x: center.x - size / 2, y: center.y + size))
        } else {
            path.move(to: NSPoint(x: center.x - size, y: center.y - size / 2))
            path.line(to: NSPoint(x: center.x, y: center.y + size / 2))
            path.line(to: NSPoint(x: center.x + size, y: center.y - size / 2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// A click in the chevron column folds or unfolds that line's block.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= ruleThickness - LineNumberRuler.foldColumn - 6, let start = lineStart(at: point),
              let textView = clientView as? CodeTextView else {
            super.mouseDown(with: event)
            return
        }
        textView.toggleFold(atLineStart: start)
    }

    /// Where the line drawn at `point` starts (a wrapped line's first part
    /// counts as the line), or nil below the text.
    func lineStart(at point: NSPoint) -> Int? {
        guard let textView = clientView as? NSTextView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let document, layoutManager.numberOfGlyphs > 0 else { return nil }
        let y = textView.convert(point, from: self).y - textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        var glyphs = NSRange()
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        guard y >= fragment.minY, y <= fragment.maxY else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyphs.location)
        return document.start(ofLine: document.line(at: character))
    }
}
