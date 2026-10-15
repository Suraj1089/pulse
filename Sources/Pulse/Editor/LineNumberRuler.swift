import AppKit

/// Draws line numbers for the visible lines only, using the document's
/// cached line index, so the cost does not grow with file length.
final class LineNumberRuler: NSRulerView {
    weak var document: Document?
    private var digits = 0

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
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
        ruleThickness = ceil(CGFloat(count) * digitWidth + 22)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let document else { return }

        Theme.editorBackground.setFill()
        rect.fill()

        let text = textView.string as NSString
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let yOffset = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        let currentLine = document.line(at: min(textView.selectedRange().location, text.length))

        let normal: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: NSColor.secondaryLabelColor]
        let rightEdge = ruleThickness - 10

        var line = document.line(at: visible.location)
        let lastLine = document.lineCount - 1
        while line <= lastLine {
            let start = document.start(ofLine: line)
            if start > NSMaxRange(visible) { break }
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
            line += 1
        }
    }
}
