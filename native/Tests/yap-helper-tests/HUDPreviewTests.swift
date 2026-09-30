import SwiftUI
import XCTest

@testable import yap_helper

/// Renders every HUD state in light and dark appearance. Doubles as a way to eyeball the pill:
/// the PNGs land in $TMPDIR/yap-hud-previews.
final class HUDPreviewTests: XCTestCase {
    @MainActor
    func testEveryStateRenders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yap-hud-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, HUD.Content)] = [
            ("recording", .listening(handsFree: false)),
            ("hands-free", .listening(handsFree: true)),
            ("transcribing", .transcribing),
            ("copied", .message(symbol: "doc.on.clipboard.fill", title: "Copied", detail: "⌘V to paste")),
            ("no-speech", .message(symbol: "waveform.slash", title: "Didn’t catch that")),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, content) in states {
                let model = HUDModel()
                model.content = content
                model.levelProvider = { 0.45 }
                let view = HUDView(model: model)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 360, height: 76)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.95))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage, name)
                XCTAssertEqual(image.width, 720, name)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        print("HUD previews: \(directory.path)")
    }
}
