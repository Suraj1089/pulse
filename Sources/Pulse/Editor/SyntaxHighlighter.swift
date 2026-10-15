import AppKit

/// Colors text with layout-manager *temporary attributes*. They never touch
/// the text storage, so highlighting causes no relayout, no undo entries and
/// no extra copies of the document.
final class SyntaxHighlighter {
    /// Documents up to this size are highlighted in full; larger ones only
    /// around the visible range.
    static let fullPassLimit = 300_000

    private var compiled: [String: (NSRegularExpression, [TokenKind])] = [:]

    private func expression(for language: Language) -> (NSRegularExpression, [TokenKind])? {
        if let cached = compiled[language.name] { return cached }
        let pattern = language.rules.map { "(" + $0.pattern + ")" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let entry = (regex, language.rules.map { $0.kind })
        compiled[language.name] = entry
        return entry
    }

    func highlight(range: NSRange, in layoutManager: NSLayoutManager, language: Language?) {
        guard let storage = layoutManager.textStorage else { return }
        let text = storage.string as NSString
        let target = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: target)
        guard let language, target.length > 0, let compiled = expression(for: language) else { return }
        let (regex, kinds) = compiled

        regex.enumerateMatches(in: storage.string, options: [], range: target) { match, _, _ in
            guard let match else { return }
            for group in 1...kinds.count where match.range(at: group).location != NSNotFound {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor,
                    value: Theme.color(for: kinds[group - 1]),
                    forCharacterRange: match.range(at: group)
                )
                break
            }
        }
    }

    /// The range worth highlighting for the current viewport: everything for
    /// small files, otherwise the visible lines plus a margin, widened to
    /// line boundaries.
    static func rangeToHighlight(textView: NSTextView) -> NSRange {
        let text = textView.string as NSString
        guard text.length > fullPassLimit,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return NSRange(location: 0, length: text.length)
        }
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let margin = 20_000
        let start = max(0, visible.location - margin)
        let end = min(text.length, NSMaxRange(visible) + margin)
        return text.lineRange(for: NSRange(location: start, length: end - start))
    }
}
