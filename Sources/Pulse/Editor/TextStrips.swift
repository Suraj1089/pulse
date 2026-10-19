import AppKit

/// Draws a text view in strips anchored to the document instead of in one
/// backing the size of the visible area.
///
/// AppKit backs a large view with a single layer covering its visible rect
/// and redraws all of it into a new drawable on every scroll frame. Core
/// Animation keeps two or three of those in flight (more when drawing falls
/// behind), so a fast scroll briefly cost several screens' worth of memory.
/// Strips stay where they are in the document: a scroll moves them, only the
/// strip coming into view draws, and strips that scroll out are reused.
/// Everything is drawn on the main thread by the text view's own `draw(_:)`.
final class TextStrips: NSObject, CALayerDelegate {
    /// Points. Taller strips cover more than the visible rect; shorter ones mean more layers.
    static let height: CGFloat = 64

    private unowned let view: NSTextView
    private var strips: [Int: CALayer] = [:]
    /// The horizontal span the strips cover: the visible width.
    private var span: (x: CGFloat, width: CGFloat) = (0, 0)
    /// Laying out can resize the view, which asks for an update again.
    private var updating = false

    init(view: NSTextView) {
        self.view = view
    }

    /// Covers the visible part of the view with strips. New ones draw before
    /// the frame is shown; ones that left the visible rect take their place.
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
        if visible.minX != span.x || visible.width != span.width {
            span = (visible.minX, visible.width)
            strips.values.forEach { $0.setNeedsDisplay() }
        }
        let first = Int((visible.minY / Self.height).rounded(.down))
        let last = Int(((visible.maxY - 0.5) / Self.height).rounded(.down))
        var spare: [CALayer] = []
        for (row, strip) in strips where row < first || row > last {
            spare.append(strip)
            strips[row] = nil
        }
        let scale = view.window?.backingScaleFactor ?? host.contentsScale
        for row in first...max(first, last) {
            let strip: CALayer
            if let existing = strips[row] {
                strip = existing
            } else {
                strip = spare.popLast() ?? makeStrip(in: host)
                strip.setNeedsDisplay()
                strips[row] = strip
            }
            let frame = frame(of: row)
            if strip.frame != frame || strip.contentsScale != scale {
                strip.frame = frame
                strip.contentsScale = scale
                strip.setNeedsDisplay()
            }
        }
        spare.forEach { $0.removeFromSuperlayer() }
    }

    /// Redraws the part of each strip in `rect` (view coordinates).
    func invalidate(_ rect: NSRect) {
        for strip in strips.values {
            let dirty = strip.frame.intersection(rect)
            if !dirty.isNull, !dirty.isEmpty {
                strip.setNeedsDisplay(dirty.offsetBy(dx: -strip.frame.minX, dy: -strip.frame.minY))
            }
        }
    }

    func invalidateAll() {
        strips.values.forEach { $0.setNeedsDisplay() }
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

    private func makeStrip(in host: CALayer) -> CALayer {
        let strip = CALayer()
        strip.delegate = self
        strip.isOpaque = view.drawsBackground
        strip.anchorPoint = .zero
        // Below the text view's subviews (the insertion point).
        host.insertSublayer(strip, at: 0)
        return strip
    }

    // MARK: CALayerDelegate

    func draw(_ layer: CALayer, in context: CGContext) {
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
