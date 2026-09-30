// Draws Yap's app icon and writes native/Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift [--preview <png>]
//
// An opening quote mark and a text cursor on paper: what you say, typed where you are.
import AppKit

let arguments = CommandLine.arguments

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple's continuous-corner app icon shape, approximated with a superellipse.
func squircle(_ rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / exponent) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / exponent) * (s < 0 ? -1 : 1)
        let point = NSPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        step == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

func withShadow(_ shadowColor: NSColor, blur: CGFloat, y: CGFloat = 0, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon(size: CGFloat) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.scaleBy(x: size / 1024, y: size / 1024)

    // Paper tile on the macOS icon grid (824 pt body in a 1024 pt canvas).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tile = squircle(body)
    withShadow(NSColor.black.withAlphaComponent(0.28), blur: 24, y: -10) {
        color(0xF7F3EA).setFill()
        tile.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: color(0xF8F5EE), ending: color(0xE6DFCF))!.draw(in: body, angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.5), NSColor.white.withAlphaComponent(0)],
               atLocations: [0, 0.35], colorSpace: .sRGB)!.draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.06).setStroke()
    let edge = squircle(body.insetBy(dx: 1.5, dy: 1.5))
    edge.lineWidth = 3
    edge.stroke()

    // The quote mark, from the system serif, measured by its actual ink.
    let font = NSFont(
        descriptor: NSFont.systemFont(ofSize: 700, weight: .heavy).fontDescriptor.withDesign(.serif)!, size: 700)!
    var glyph = CGGlyph()
    var character: UniChar = 0x201C
    CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1)
    let outline = CTFontCreatePathForGlyph(font as CTFont, glyph, nil)!
    let ink = outline.boundingBoxOfPath

    let caretSize = CGSize(width: 56, height: 470)
    let gap: CGFloat = 64
    let left = 512 - (ink.width + gap + caretSize.width) / 2
    let caretRect = CGRect(x: left + ink.width + gap, y: 512 - caretSize.height / 2, width: caretSize.width, height: caretSize.height)
    // Set high, the way an opening quote sits at the start of a line, but pulled toward centre for balance.
    let centredTop = 512 + ink.height / 2
    let top = centredTop + (caretRect.maxY - centredTop) * 0.6

    var move = CGAffineTransform(translationX: left - ink.minX, y: top - ink.maxY)
    let quote = outline.copy(using: &move)!
    withShadow(NSColor.black.withAlphaComponent(0.16), blur: 16, y: -7) {
        context.setFillColor(color(0x121212).cgColor)
        context.addPath(quote)
        context.fillPath()
    }

    let caret = NSBezierPath(roundedRect: caretRect, xRadius: caretSize.width / 2, yRadius: caretSize.width / 2)
    withShadow(color(0xFF5A1F, 0.35), blur: 30, y: -6) {
        color(0xFF5A1F).setFill()
        caret.fill()
    }
    NSGradient(starting: color(0xFF7A3D), ending: color(0xF2470F))!.draw(in: caret, angle: -90)
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if let index = arguments.firstIndex(of: "--preview") {
    try! png(pixels: 512).write(to: URL(fileURLWithPath: arguments[index + 1]))
    exit(0)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = URL(fileURLWithPath: "native/Resources/AppIcon.icns")
try! FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
print("Wrote \(output.path)")
