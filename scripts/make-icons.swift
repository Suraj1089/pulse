// Builds every Pulse icon from the logo mark in assets/logo.svg:
// the app icon (AppIcon.iconset + .icns), the website icons and favicon,
// the README icon, and the icon in the social card.
//
//   swift scripts/make-icons.swift
//
// The mark is drawn from the SVG's own path (below) rather than the SVG file,
// so small sizes can use a larger, thicker mark that stays legible at 16 px.
// If assets/logo.svg changes, update `markPath` and `markTransform` to match.
import AppKit

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func hex(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

let blue = hex(0x2563EB)          // the logo's stroke, rgb(37, 99, 235)
let tileColor = NSColor.white

// MARK: The mark

/// The SVG path: "M272.612,547.325 C296.17,546.948 314.69,561.373 315.224,561.35
/// C316.883,561.28 331,511 331,511 L343,560 L352,534 L371,550.666 L395.388,537.325"
/// inside transform matrix(0.765625,0,0,0.816327,165.28125,85.857143) and
/// translate(-369.5,-498.5), on a 103 × 51 viewBox with an 11.37 stroke.
let viewBox = NSSize(width: 103, height: 51)

func markPath() -> NSBezierPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        // SVG transforms, then flip y (SVG grows down, AppKit up).
        let tx = x * 0.765625 + 165.28125 - 369.5
        let ty = y * 0.816327 + 85.857143 - 498.5
        return NSPoint(x: tx, y: viewBox.height - ty)
    }
    let path = NSBezierPath()
    path.move(to: p(272.612, 547.325))
    path.curve(to: p(315.224, 561.35), controlPoint1: p(296.17, 546.948), controlPoint2: p(314.69, 561.373))
    path.curve(to: p(331, 511), controlPoint1: p(316.883, 561.28), controlPoint2: p(331, 511))
    path.line(to: p(343, 560))
    path.line(to: p(352, 534))
    path.line(to: p(371, 550.666))
    path.line(to: p(395.388, 537.325))
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

/// The stroke in viewBox units: the SVG's 11.37 under its ~0.79 scale.
let regularStroke: CGFloat = 11.37 * (0.765625 + 0.816327) / 2

/// Draws the mark centered in `box`, `width` wide, with `stroke` in viewBox units.
func drawMark(in box: NSRect, widthFraction: CGFloat, stroke: CGFloat, color: NSColor = blue) {
    let path = markPath()
    // Fit the path's own bounds (stroke included) into the box.
    let bounds = path.bounds.insetBy(dx: -stroke / 2, dy: -stroke / 2)
    let scale = box.width * widthFraction / bounds.width
    var t = AffineTransform(translationByX: -bounds.midX, byY: -bounds.midY)
    t.append(AffineTransform(scaleByX: scale, byY: scale))
    t.append(AffineTransform(translationByX: box.midX, byY: box.midY))
    path.transform(using: t)
    path.lineWidth = stroke * scale
    color.setStroke()
    path.stroke()
}

// MARK: Images

func png(_ size: Int, _ draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The macOS app icon: Apple's template (824-pt rounded square with a soft
/// shadow on a 1024 canvas), white, with the blue mark. At 32 px and below
/// the mark is bigger and its line thicker so it stays readable.
func appIcon(_ size: Int) -> Data {
    png(size) { rect in
        let s = rect.width / 1024
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tile = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.shadowBlurRadius = 24 * s
        shadow.set()
        tileColor.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        // A hairline edge so the white tile reads on white backgrounds too.
        hex(0xD9D9DE).setStroke()
        tile.lineWidth = max(1, 2 * s)
        tile.stroke()
        let small = size <= 32
        drawMark(in: body, widthFraction: small ? 0.84 : 0.70, stroke: small ? regularStroke * 1.55 : regularStroke)
    }
}

/// iOS/Safari touch icon: full-bleed and opaque (the system rounds it).
func touchIcon(_ size: Int) -> Data {
    png(size) { rect in
        tileColor.setFill()
        rect.fill()
        drawMark(in: rect, widthFraction: 0.72, stroke: regularStroke * 1.15)
    }
}

/// A .ico holding PNG images (supported by every current browser).
func ico(_ images: [(Int, Data)]) -> Data {
    var data = Data()
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
    u16(0); u16(1); u16(images.count)
    var offset = 6 + 16 * images.count
    for (size, png) in images {
        data.append(UInt8(size >= 256 ? 0 : size)); data.append(UInt8(size >= 256 ? 0 : size))
        data.append(0); data.append(0)
        u16(1); u16(32); u32(png.count); u32(offset)
        offset += png.count
    }
    images.forEach { data.append($0.1) }
    return data
}

func write(_ data: Data, _ path: String) {
    let url = repo.appendingPathComponent(path)
    try! data.write(to: url)
    print("wrote \(path) (\(data.count / 1024) KB)")
}

// MARK: App icon

let iconset = "Sources/Pulse/Resources/AppIcon.iconset"
for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    write(appIcon(pixels), "\(iconset)/icon_\(name).png")
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "Sources/Pulse/Resources/AppIcon.icns"]
iconutil.currentDirectoryURL = repo
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("wrote Sources/Pulse/Resources/AppIcon.icns")

// MARK: README and website

write(appIcon(1024), "assets/icon.png")
write(appIcon(1024), "site/icon.png")
write(appIcon(512), "site/icon-512.png")
write(touchIcon(180), "site/apple-touch-icon.png")
write(ico([(16, appIcon(16)), (32, appIcon(32)), (48, appIcon(48))]), "site/favicon.ico")

// MARK: Social card: replace the old icon in its top-left corner, keep the rest.

let cardURL = repo.appendingPathComponent("site/og-image.png")
if let card = NSBitmapImageRep(data: try! Data(contentsOf: cardURL)) {
    // The old icon is the dark square at the top left: left of the "Pulse"
    // label (x < 132) and above the headline (y < 160).
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<160 { for x in 0..<132 {
        guard let c = card.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if c.brightnessComponent < 0.35 && c.alphaComponent > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    } }
    // Only a roughly square shape the size of an icon is replaced.
    if maxX > minX, maxX - minX < 90, abs((maxX - minX) - (maxY - minY)) < 6 {
        let background = card.colorAt(x: 20, y: 20) ?? .white
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: card)
        // Bitmap rows count from the top; drawing coordinates from the bottom.
        let height = CGFloat(card.pixelsHigh)
        let old = NSRect(x: CGFloat(minX), y: height - CGFloat(maxY) - 1,
                         width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        background.setFill()
        old.insetBy(dx: -2, dy: -2).fill()
        // The template's tile is 824 of 1024: grow the canvas so the tile matches the old icon.
        let canvas = old.width * 1024 / 824
        let image = NSImage(data: appIcon(Int(canvas.rounded())))!
        image.draw(in: NSRect(x: old.midX - canvas / 2, y: old.midY - canvas / 2, width: canvas, height: canvas))
        NSGraphicsContext.restoreGraphicsState()
        write(card.representation(using: .png, properties: [:])!, "site/og-image.png")
        print("  replaced the old icon at \(minX),\(minY) (\(maxX - minX + 1) × \(maxY - minY + 1) px)")
    } else {
        print("site/og-image.png: old icon not found; left unchanged")
    }
}
