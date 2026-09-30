import CoreGraphics
import XCTest

@testable import yap_helper

final class HotkeySpecTests: XCTestCase {
    private func flags(_ raw: UInt64) -> CGEventFlags { CGEventFlags(rawValue: raw) }

    private let fn = CGEventFlags.maskSecondaryFn.rawValue
    private let opt = CGEventFlags.maskAlternate.rawValue
    private let cmd = CGEventFlags.maskCommand.rawValue
    private let ctrl = CGEventFlags.maskControl.rawValue
    private let shift = CGEventFlags.maskShift.rawValue
    private let leftOption: UInt64 = 0x20
    private let rightOption: UInt64 = 0x40

    func testParsesNamesAndAliases() throws {
        XCTAssertEqual(try HotkeySpec.parse("fn").description, "fn")
        XCTAssertEqual(try HotkeySpec.parse("Right-Option").description, "right_option")
        XCTAssertEqual(try HotkeySpec.parse("ctrl + opt + space").description, "ctrl+opt+space")
        XCTAssertTrue(try HotkeySpec.parse("right_command").isModifierOnly)
        XCTAssertEqual(try HotkeySpec.parse("f18").keyCode, 79)
    }

    func testRejectsBadHotkeys() {
        XCTAssertThrowsError(try HotkeySpec.parse(""))
        XCTAssertThrowsError(try HotkeySpec.parse("hyper"))
        XCTAssertThrowsError(try HotkeySpec.parse("a+b"))
    }

    func testFnAloneMatchesOnlyWithoutOtherModifiers() throws {
        let spec = try HotkeySpec.parse("fn")
        XCTAssertTrue(spec.modifiersMatch(flags(fn)))
        XCTAssertFalse(spec.modifiersMatch(flags(fn | cmd)))
        XCTAssertFalse(spec.modifiersMatch(flags(0)))
    }

    func testCapsLockDoesNotBlockTheHotkey() throws {
        let spec = try HotkeySpec.parse("fn")
        XCTAssertTrue(spec.modifiersMatch(flags(fn | CGEventFlags.maskAlphaShift.rawValue)))
    }

    func testSideSpecificModifiers() throws {
        let spec = try HotkeySpec.parse("right_option")
        XCTAssertTrue(spec.modifiersMatch(flags(opt | rightOption)))
        XCTAssertFalse(spec.modifiersMatch(flags(opt | leftOption)))
        // Releasing right option while left is still down counts as a release.
        XCTAssertTrue(spec.modifiersMatch(flags(opt | leftOption | rightOption)))
        XCTAssertFalse(spec.modifiersMatch(flags(opt | leftOption)))
    }

    func testModifierCombination() throws {
        let spec = try HotkeySpec.parse("ctrl+opt")
        XCTAssertTrue(spec.modifiersMatch(flags(ctrl | opt)))
        XCTAssertFalse(spec.modifiersMatch(flags(ctrl)))
        XCTAssertFalse(spec.modifiersMatch(flags(ctrl | opt | shift)))
    }

    func testKeyCombosIgnoreTheFnBitThatFunctionKeysCarry() throws {
        XCTAssertTrue(try HotkeySpec.parse("f18").modifiersMatch(flags(fn)))
        XCTAssertTrue(try HotkeySpec.parse("ctrl+f5").modifiersMatch(flags(ctrl | fn)))
        XCTAssertFalse(try HotkeySpec.parse("ctrl+f5").modifiersMatch(flags(fn)))
        XCTAssertFalse(try HotkeySpec.parse("space").modifiersMatch(flags(cmd)))
    }
}

final class HotkeyDisplayNameTests: XCTestCase {
    func testDisplayNames() throws {
        XCTAssertEqual(try HotkeySpec.parse("fn").displayName, "fn")
        XCTAssertEqual(try HotkeySpec.parse("right_option").displayName, "Right ⌥")
        XCTAssertEqual(try HotkeySpec.parse("ctrl+opt+space").displayName, "⌃⌥Space")
        XCTAssertEqual(try HotkeySpec.parse("cmd+shift+d").displayName, "⌘⇧D")
        XCTAssertEqual(try HotkeySpec.parse("f18").displayName, "F18")
    }
}
