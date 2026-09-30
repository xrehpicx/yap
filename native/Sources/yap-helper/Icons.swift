import AppKit

/// Menu bar glyphs, drawn in code so they stay crisp at every scale and tint with the menu bar.
/// Every state is "something flowing into a text cursor", like the HUD: sound bars at rest,
/// the same bars punched out of a solid tile while listening, dots while transcribing, and the
/// caret turned into an exclamation mark when something needs fixing.
enum MenuBarIcon {
    enum State {
        case idle, recording, transcribing, attention
    }

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            if let context = NSGraphicsContext.current?.cgContext { draw(state, in: context) }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Yap"
        return image
    }

    private static let caret = CGRect(x: 13.3, y: 2.5, width: 1.9, height: 13)
    private static let barHeights: [CGFloat] = [3.5, 7.0, 10.0, 5.5]

    static func draw(_ state: State, in context: CGContext) {
        let marks = CGMutablePath()
        if state == .transcribing {
            for index in 0..<3 {
                marks.addEllipse(in: CGRect(x: 3.1 + CGFloat(index) * 2.9, y: caret.midY - 0.9, width: 1.8, height: 1.8))
            }
        } else {
            for (index, height) in barHeights.enumerated() {
                let bar = CGRect(x: 3 + CGFloat(index) * 2.2, y: caret.midY - height / 2, width: 1.4, height: height)
                marks.addRoundedRect(in: bar, cornerWidth: 0.7, cornerHeight: 0.7)
            }
        }
        if state == .attention {
            let stem = CGRect(x: caret.minX, y: caret.minY + 3.6, width: caret.width, height: caret.height - 3.6)
            marks.addRoundedRect(in: stem, cornerWidth: 0.95, cornerHeight: 0.95)
            marks.addEllipse(in: CGRect(x: caret.midX - 1.15, y: caret.minY - 0.2, width: 2.3, height: 2.3))
        } else {
            marks.addRoundedRect(in: caret, cornerWidth: 0.95, cornerHeight: 0.95)
        }

        context.setFillColor(NSColor.black.cgColor)
        if state == .recording {
            let tile = CGRect(x: 0.5, y: 0.5, width: 17, height: 17)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
            context.setBlendMode(.clear)
        }
        context.addPath(marks)
        context.fillPath()
        context.setBlendMode(.normal)
    }
}

/// Small colored dot used as the status line's image in the menu.
enum StatusDot {
    static func image(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }
}
