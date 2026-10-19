import AppKit

/// Draws a text view in strips anchored to the document instead of in one
/// backing the size of the visible area.
///
/// AppKit backs a large view with a single layer covering its visible rect
/// and redraws all of it into a new drawable on every scroll frame. Core
/// Animation keeps two or three of those in flight (more when drawing falls
/// behind), so a fast scroll briefly cost several screens' worth of memory.
/// Strips stay where they are in the document: a scroll moves them, and only
/// the strips coming into view draw. Everything is drawn on the main thread
/// by the text view's own `draw(_:)`.
///
/// Drawing a layer again while its contents are on screen makes Core
/// Animation give it a second backing store, kept as a spare. So while
/// scrolling, strips that come into view are new layers and the ones that
/// left are dropped, and a strip whose whole visible part changes (a caret
/// move, typing, colors) is replaced by a new layer: each keeps one buffer.
/// Only part of a strip changing draws over it. When most strips change at
/// once (a jump, a sideways scroll), the strips are drawn over instead,
/// which costs less than a whole new set while the previous one is still in
/// flight.
final class TextStrips: NSObject, CALayerDelegate {
    /// Points. Taller strips cover more than the visible rect; shorter ones mean more layers.
    static let height: CGFloat = 64

    private unowned let view: NSTextView
    private var strips: [Int: CALayer] = [:]
    /// The horizontal span the strips cover: the visible width.
    private var span: (x: CGFloat, width: CGFloat) = (0, 0)
    /// Laying out can resize the view, which asks for an update again.
    private var updating = false
    /// For tests: how many times a strip has drawn.
    private(set) var draws = 0

    init(view: NSTextView) {
        self.view = view
    }

    /// Covers the visible part of the view with strips. New ones draw before
    /// the frame is shown.
    func update() {
        guard !updating, let host = view.layer, let layoutManager = view.layoutManager, let container = view.textContainer else { return }
        updating = true
        defer { updating = false }
        // Lay out first, so drawing never resizes the view while Core
        // Animation displays. The visible rect is read after: filling layout
        // holes can change the view's height and scroll position.
        let origin = view.textContainerOrigin
        layoutManager.ensureLayout(forBoundingRect: view.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = view.visibleRect.intersection(view.bounds)
        guard !visible.isEmpty else {
            removeAll()
            return
        }
        // A new width changes every strip's size: new layers, not a second buffer each.
        if visible.width != span.width { removeAll() }
        span = (visible.minX, visible.width)
        let first = Int((visible.minY / Self.height).rounded(.down))
        let rows = first...max(first, Int(((visible.maxY - 0.5) / Self.height).rounded(.down)))
        var spare: [CALayer] = []
        for (row, strip) in strips where !rows.contains(row) {
            spare.append(strip)
            strips[row] = nil
        }
        // A few strips coming in: new layers. Most of them: draw over the ones that left.
        if (rows.count - strips.count) * 2 <= rows.count {
            spare.forEach { $0.removeFromSuperlayer() }
            spare = []
        }
        let scale = view.window?.backingScaleFactor ?? host.contentsScale
        for row in rows {
            let frame = frame(of: row)
            if let strip = strips[row] {
                if strip.frame.size != frame.size || strip.contentsScale != scale {
                    // The last strip as the text grows, or a new display.
                    renew(row, frame: frame, scale: scale)
                } else if strip.frame != frame {
                    // A sideways scroll: every strip changes, so draw over them, as for a jump.
                    strip.frame = frame
                    strip.setNeedsDisplay()
                }
            } else {
                let strip = spare.popLast() ?? makeStrip(in: host)
                strip.frame = frame
                strip.contentsScale = scale
                strip.setNeedsDisplay()
                strips[row] = strip
            }
        }
        spare.forEach { $0.removeFromSuperlayer() }
    }

    /// Redraws the part of each strip in `rect` (view coordinates).
    func invalidate(_ rect: NSRect) {
        for (row, strip) in strips {
            let dirty = strip.frame.intersection(rect)
            guard !dirty.isNull, !dirty.isEmpty else { continue }
            if dirty.contains(strip.frame.intersection(view.visibleRect)) {
                renew(row)
            } else {
                strip.setNeedsDisplay(dirty.offsetBy(dx: -strip.frame.minX, dy: -strip.frame.minY))
            }
        }
    }

    func invalidateAll() {
        strips.keys.forEach { renew($0) }
    }

    func removeAll() {
        strips.values.forEach { $0.removeFromSuperlayer() }
        strips = [:]
    }

    /// For tests: the strips' frames, top to bottom.
    var frames: [CGRect] { strips.keys.sorted().compactMap { strips[$0]?.frame } }

    private func frame(of row: Int) -> CGRect {
        let top = CGFloat(row) * Self.height
        return CGRect(x: span.x, y: top, width: span.width, height: max(0, min(Self.height, view.bounds.maxY - top)))
    }

    /// A new layer for the strip at `row`, unless that one hasn't drawn yet.
    private func renew(_ row: Int, frame: CGRect? = nil, scale: CGFloat? = nil) {
        guard let old = strips[row] else { return }
        let frame = frame ?? old.frame, scale = scale ?? old.contentsScale
        guard old.contents != nil, let host = old.superlayer else {
            old.frame = frame
            old.contentsScale = scale
            return old.setNeedsDisplay()
        }
        let strip = makeStrip(in: nil)
        strip.frame = frame
        strip.contentsScale = scale
        host.replaceSublayer(old, with: strip)
        strip.setNeedsDisplay()
        strips[row] = strip
    }

    private func makeStrip(in host: CALayer?) -> CALayer {
        let strip = CALayer()
        strip.delegate = self
        strip.isOpaque = view.drawsBackground
        strip.anchorPoint = .zero
        // Below the text view's subviews (the insertion point).
        host?.insertSublayer(strip, at: 0)
        return strip
    }

    // MARK: CALayerDelegate

    func draw(_ layer: CALayer, in context: CGContext) {
        draws += 1
        let frame = layer.frame
        if !layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: frame.height)
            context.scaleBy(x: 1, y: -1)
        }
        let dirty = context.boundingBoxOfClipPath.offsetBy(dx: frame.minX, dy: frame.minY).intersection(frame)
        guard !dirty.isNull, !dirty.isEmpty else { return }
        context.translateBy(x: -frame.minX, y: -frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.draw(dirty) }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Strips move and resize at once; an implicit animation would slide them.
    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}
