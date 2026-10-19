import AppKit
import XCTest
@testable import Pulse

/// The text view draws in strips anchored to the document (Editor/TextStrips.swift),
/// not in one backing the size of the visible area. What the layers show must be
/// what the text view draws, and the strips must cover the visible text and no more.
final class EditorDrawingTests: PulseTestCase {
    /// A long line to scroll sideways, blocks to fold, and enough lines to scroll far.
    private func source(blocks: Int) -> String {
        var text = "let long = \"" + String(repeating: "wide ", count: 120) + "\"\n"
        for i in 0..<blocks {
            text += "func block\(i)() {\n    let value = \(i) // line \(i)\n    print(value)\n}\n\n"
        }
        return text
    }

    private func open(blocks: Int = 600) throws -> MainWindowController {
        let root = try makeFolder(files: ["main.swift": source(blocks: blocks), "other.swift": source(blocks: 40)])
        return makeController(opening: [root.appendingPathComponent("main.swift")])
    }

    func testLayersShowWhatTheTextViewDraws() throws {
        let controller = try open()
        let textView = try XCTUnwrap(controller.editor.textView)
        let text = textView.string as NSString
        try assertLayersMatch(controller, "opened")

        textView.scroll(NSPoint(x: 0, y: 2_037))
        try assertLayersMatch(controller, "scrolled")

        // The caret's line is highlighted; selecting moves the highlight away.
        let onScreen = textView.characterIndexForInsertion(at: NSPoint(x: 0, y: textView.visibleRect.minY + 120))
        let lineStart = text.range(of: "func ", options: [], range: NSRange(location: onScreen, length: 400)).location
        textView.setSelectedRange(NSRange(location: lineStart, length: 0))
        try assertLayersMatch(controller, "caret")
        try assertCurrentLineShows(controller, at: lineStart)
        textView.setSelectedRange(NSRange(location: lineStart + 3, length: 80))
        try assertLayersMatch(controller, "selection")

        textView.setSelectedRange(NSRange(location: lineStart, length: 0))
        textView.foldAtCaret()
        XCTAssertEqual(textView.foldPlaceholders(in: textView.visibleRect).count, 1, "the fold is on screen")
        try assertLayersMatch(controller, "folded")

        // Syntax colours redraw only the characters they change.
        let word = text.range(of: "print", options: [], range: NSRange(location: lineStart + 200, length: 400))
        textView.layoutManager?.addTemporaryAttribute(.foregroundColor, value: NSColor.systemRed, forCharacterRange: word)
        try assertLayersMatch(controller, "recoloured")

        textView.insertText("let typed = 1\n", replacementRange: textView.selectedRange())
        try assertLayersMatch(controller, "typed")

        textView.scroll(NSPoint(x: 300, y: 0))
        try assertLayersMatch(controller, "sideways")

        controller.editor.toggleWrap()
        try assertLayersMatch(controller, "wrapped")
        controller.window?.setContentSize(NSSize(width: 900, height: 560))
        try assertLayersMatch(controller, "resized")
        controller.editor.toggleWrap()
        try assertLayersMatch(controller, "unwrapped")

        let main = try XCTUnwrap(controller.editor.activeDocument?.url)
        controller.editor.open(main.deletingLastPathComponent().appendingPathComponent("other.swift"))
        try assertLayersMatch(controller, "other tab")
        controller.editor.open(main)
        try assertLayersMatch(controller, "back")

        defer { AppAppearance.current = .auto }
        AppAppearance.current = .dark
        try assertLayersMatch(controller, "dark")
        AppAppearance.current = .light
        try assertLayersMatch(controller, "light")
    }

    func testStripsCoverTheVisibleTextAndNoMore() throws {
        let controller = try open()
        let textView = try XCTUnwrap(controller.editor.textView)
        for y: CGFloat in [0, 1_000, 1_030, 30_000, 7_777, 1_000_000, 0] {
            textView.scroll(NSPoint(x: 0, y: y))
            try display(controller)
            let visible = textView.visibleRect.intersection(textView.bounds)
            let frames = textView.stripFrames
            guard let first = frames.first, let last = frames.last else { return XCTFail("no strips at \(y)") }
            XCTAssertLessThanOrEqual(first.minY, visible.minY, "top covered at \(y)")
            XCTAssertGreaterThanOrEqual(last.maxY, visible.maxY, "bottom covered at \(y)")
            XCTAssertLessThanOrEqual(frames.count, Int((visible.height / TextStrips.height).rounded(.up)) + 1, "at \(y)")
            for (above, below) in zip(frames, frames.dropFirst()) {
                XCTAssertEqual(above.maxY, below.minY, "no gaps at \(y)")
            }
            for frame in frames {
                XCTAssertEqual(frame.minX, visible.minX, "at \(y)")
                XCTAssertEqual(frame.width, visible.width, "at \(y)")
            }
            let sublayers = textView.layer?.sublayers ?? []
            XCTAssertEqual(sublayers.filter { $0.delegate is TextStrips }.count, frames.count, "strips that scrolled away are reused or gone")
            XCTAssertFalse(sublayers.contains { !($0.delegate is TextStrips) && $0.bounds.width * $0.bounds.height > visible.width * visible.height / 2 },
                           "no backing the size of the visible area at \(y)")
            XCTAssertNil(textView.layer?.contents, "the text view's own layer draws nothing")
        }
    }

    /// A step of a trackpad scroll brings in at most one strip (two when it
    /// crosses a boundary); nothing else redraws.
    func testScrollingDrawsOnlyTheStripsComingIntoView() throws {
        let controller = try open()
        let textView = try XCTUnwrap(controller.editor.textView)
        try display(controller)
        for step in 1...20 {
            let before = textView.stripDraws
            try scrollWheel(-60, in: controller)
            try display(controller)
            XCTAssertLessThanOrEqual(textView.stripDraws - before, 2, "step \(step)")
        }
        XCTAssertGreaterThan(textView.visibleRect.minY, 600, "the steps scrolled")
    }

    func testAFrameChangeAloneRedrawsNoStrip() throws {
        let controller = try open()
        let textView = try XCTUnwrap(controller.editor.textView)
        textView.scroll(NSPoint(x: 0, y: 1_000))
        try display(controller)
        let before = textView.stripDraws
        // What laying out more of the text does to the view's height.
        textView.setFrameSize(NSSize(width: textView.frame.width, height: textView.frame.height + 100))
        try display(controller)
        XCTAssertEqual(textView.stripDraws, before)
    }

    // MARK: Helpers

    /// A scroll-wheel event of `delta` pixels, continuous like a trackpad's.
    private func scrollWheel(_ delta: Int32, in controller: MainWindowController) throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        try XCTUnwrap(controller.editor.activePane).scrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
    }

    /// Compares what Core Animation shows for the editor (its layer tree,
    /// strips included) with what AppKit draws for it with `cacheDisplay`.
    private func assertLayersMatch(_ controller: MainWindowController, _ label: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let (drawn, shown) = try images(controller)
        XCTAssertGreaterThan(drawn.ink, 0.005, "the editor shows text \(label)", file: file, line: line)
        XCTAssertLessThan(drawn.fraction(differingFrom: shown, by: 6), 0.002, "layers vs drawing \(label)", file: file, line: line)
    }

    /// The caret's line has the current-line colour in what the layers show.
    private func assertCurrentLineShows(_ controller: MainWindowController, at location: Int,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let textView = try XCTUnwrap(controller.editor.textView)
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: location), effectiveRange: nil)
        let x = textView.visibleRect.maxX - 40
        let y = fragment.midY + textView.textContainerOrigin.y
        let (_, shown) = try images(controller)
        func pixel(_ point: NSPoint) -> [Int] { shown.pixel(at: scroll.convert(point, from: textView), in: scroll) }
        let current = pixel(NSPoint(x: x, y: y)), below = pixel(NSPoint(x: x, y: y + 2 * fragment.height))
        XCTAssertGreaterThan(zip(current, below).map { abs($0 - $1) }.max() ?? 0, 4, "current line \(current) vs next \(below)", file: file, line: line)
    }

    /// Brings the layers up to date. Off screen, AppKit runs no display
    /// pass of its own, so the views' layers are displayed here.
    private func display(_ controller: MainWindowController) throws {
        layout(controller)
        spin(0.05)
        func display(_ layer: CALayer) {
            layer.displayIfNeeded()
            layer.sublayers?.forEach(display)
        }
        display(try XCTUnwrap(controller.editor.textView.enclosingScrollView?.layer, "the editor is layer-backed"))
    }

    /// The editor drawn by AppKit, and as its layers show it.
    private func images(_ controller: MainWindowController) throws -> (drawn: Pixels, shown: Pixels) {
        try display(controller)
        let scroll = try XCTUnwrap(controller.editor.textView.enclosingScrollView)
        let root = try XCTUnwrap(scroll.layer)
        let rep = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let scale = CGFloat(width) / scroll.bounds.width
        let drawn = try XCTUnwrap(Pixels(width: width, height: height) { $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) })
        // Which way up the layer tree renders depends on its geometry; take the one that fits.
        let upright = try XCTUnwrap(Pixels(width: width, height: height) {
            $0.scaleBy(x: scale, y: scale)
            root.render(in: $0)
        })
        let flipped = try XCTUnwrap(Pixels(width: width, height: height) {
            $0.translateBy(x: 0, y: CGFloat(height))
            $0.scaleBy(x: scale, y: -scale)
            root.render(in: $0)
        })
        let shown = drawn.fraction(differingFrom: upright, by: 24, every: 7) <= drawn.fraction(differingFrom: flipped, by: 24, every: 7) ? upright : flipped
        return (drawn, shown)
    }

    /// RGBA pixels, top row first.
    private struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]

        init?(width: Int, height: Int, draw: (CGContext) -> Void) {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            draw(context)
            guard let data = context.data else { return nil }
            self.width = width
            self.height = height
            bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        }

        /// The share of pixels (every `step`th one) where a channel differs by more than `tolerance`.
        func fraction(differingFrom other: Pixels, by tolerance: Int, every step: Int = 1) -> Double {
            var differing = 0, counted = 0
            bytes.withUnsafeBufferPointer { a in
                other.bytes.withUnsafeBufferPointer { b in
                    for i in stride(from: 0, to: a.count, by: 4 * step) {
                        counted += 1
                        if abs(Int(a[i]) - Int(b[i])) > tolerance || abs(Int(a[i + 1]) - Int(b[i + 1])) > tolerance
                            || abs(Int(a[i + 2]) - Int(b[i + 2])) > tolerance { differing += 1 }
                    }
                }
            }
            return Double(differing) / Double(max(1, counted))
        }

        /// The share of pixels clearly unlike the most common one (the background).
        var ink: Double {
            bytes.withUnsafeBufferPointer { a in
                var counts: [UInt32: Int] = [:]
                for i in stride(from: 0, to: a.count, by: 4 * 61) {
                    counts[UInt32(a[i]) << 16 | UInt32(a[i + 1]) << 8 | UInt32(a[i + 2]), default: 0] += 1
                }
                guard let background = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
                let r = Int(background >> 16), g = Int(background >> 8 & 0xFF), b = Int(background & 0xFF)
                var inked = 0
                for i in stride(from: 0, to: a.count, by: 4)
                where abs(Int(a[i]) - r) > 24 || abs(Int(a[i + 1]) - g) > 24 || abs(Int(a[i + 2]) - b) > 24 { inked += 1 }
                return Double(inked) / Double(width * height)
            }
        }

        /// The colour at `point` in `view`'s coordinates (the view these pixels show).
        func pixel(at point: NSPoint, in view: NSView) -> [Int] {
            let scale = CGFloat(width) / view.bounds.width
            let top = view.isFlipped ? point.y - view.bounds.minY : view.bounds.maxY - point.y
            let x = min(width - 1, max(0, Int(((point.x - view.bounds.minX) * scale).rounded(.down))))
            let y = min(height - 1, max(0, Int((top * scale).rounded(.down))))
            let i = (y * width + x) * 4
            return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
        }
    }
}
