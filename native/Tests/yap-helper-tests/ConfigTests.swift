import AppKit
import XCTest

@testable import yap_helper

final class ConfigTests: XCTestCase {
    func testSwitchedOnUnlessTheConfigSaysOtherwise() throws {
        XCTAssertFalse(try decode("{}").paused)
        XCTAssertTrue(try decode(#"{"paused": true}"#).paused)
        // The rest of a partial config keeps its defaults.
        let config = try decode(#"{"paused": true, "hotkey": "right_option"}"#)
        XCTAssertEqual(config.hotkey, "right_option")
        XCTAssertTrue(config.format)
    }

    func testOffGlyphIsTheRestingGlyphDimmed() {
        let idle = coverage(of: .idle)
        let off = coverage(of: .off)
        XCTAssertGreaterThan(idle, 0)
        XCTAssertEqual(off / idle, 0.4, accuracy: 0.05)
    }

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    /// Sum of the glyph's alpha, drawn at 4×.
    private func coverage(of state: MenuBarIcon.State) -> Double {
        let size = 72
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 4, y: 4)
        MenuBarIcon.draw(state, in: context)
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
        return (0..<(size * size)).reduce(0.0) { $0 + Double(pixels[$1 * 4 + 3]) / 255 }
    }
}
