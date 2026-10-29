import AppKit

/// Where the visible text starts, as a place in the text: the first
/// character of the line at the top, how far above the top that line
/// starts, and the horizontal scroll.
struct ScrollAnchor: Equatable {
    var character = 0
    var offset: CGFloat = 0
    var x: CGFloat = 0
}

/// The editor's scroll view.
///
/// Since macOS 14 the vertical ruler floats over the clip view instead of
/// sitting beside it, and AppKit marks the strip it covers with the clip
/// view's `contentInsets` (the find bar does the same at the top). So the
/// text starts at the clip view's bounds origin plus those insets, and the
/// width text can use is the clip view's width minus them.
final class EditorScrollView: NSScrollView {
    /// When on, the document view is kept exactly as wide as the visible
    /// text area, so wrapped lines end at the right edge, not under it.
    var wrapsLines = false

    /// The document point shown at the top-left of the visible text, right
    /// of the gutter and below the find bar.
    var visibleTextOrigin: NSPoint {
        get {
            let clip = contentView
            return NSPoint(x: clip.bounds.minX + clip.contentInsets.left, y: clip.bounds.minY + clip.contentInsets.top)
        }
        set {
            let clip = contentView
            clip.scroll(to: NSPoint(x: newValue.x - clip.contentInsets.left, y: newValue.y - clip.contentInsets.top))
            reflectScrolledClipView(clip)
        }
    }

    /// The visible text's start as a line rather than a point. A file shown
    /// again is laid out afresh, and with non-contiguous layout the lines
    /// above the visible ones sit at estimated positions until laid out: the
    /// same point showed lines dozens or hundreds away from the ones left.
    var visibleTextAnchor: ScrollAnchor {
        get {
            let origin = visibleTextOrigin
            guard let textView = documentView as? NSTextView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer, layoutManager.numberOfGlyphs > 0 else {
                return ScrollAnchor(character: 0, offset: origin.y, x: origin.x)
            }
            let y = origin.y - textView.textContainerOrigin.y
            var glyphs = NSRange()
            let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: container),
                                                      effectiveRange: &glyphs)
            return ScrollAnchor(character: layoutManager.characterIndexForGlyph(at: glyphs.location), offset: y - line.minY, x: origin.x)
        }
        set {
            guard let textView = documentView as? NSTextView, let layoutManager = textView.layoutManager,
                  let length = textView.textStorage?.length, length > 0 else {
                visibleTextOrigin = NSPoint(x: newValue.x, y: newValue.offset)
                return
            }
            let character = min(newValue.character, length - 1)
            // Right after new text, non-contiguous layout may not have grown
            // the text view down to the line yet, and the clip view would stop
            // short; scrollRangeToVisible lays out and sizes it first.
            textView.scrollRangeToVisible(NSRange(location: character, length: 0))
            let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: character), effectiveRange: nil)
            visibleTextOrigin = NSPoint(x: newValue.x, y: textView.textContainerOrigin.y + line.minY + newValue.offset)
        }
    }

    /// Width available to text, excluding the gutter.
    var visibleTextWidth: CGFloat {
        let clip = contentView
        return max(0, clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right)
    }

    /// Runs on resize, ruler thickness changes and find bar changes, which
    /// are exactly the moments the visible width can change.
    override func tile() {
        super.tile()
        guard wrapsLines, let textView = documentView as? NSTextView else { return }
        let width = visibleTextWidth
        if textView.frame.width != width {
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }
        // widthTracksTextView follows frame changes only; when wrap is turned
        // on with the frame already at this width, the container would keep
        // its unbounded width and nothing would wrap.
        if let container = textView.textContainer {
            let lineWidth = max(0, width - 2 * textView.textContainerInset.width)
            if container.size.width != lineWidth {
                container.size = NSSize(width: lineWidth, height: container.size.height)
            }
        }
    }
}
