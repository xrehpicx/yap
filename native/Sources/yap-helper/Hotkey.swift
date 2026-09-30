import CoreGraphics
import Foundation

/// A parsed hotkey: either modifiers alone ("fn", "right_option", "ctrl+opt")
/// or modifiers plus one key ("ctrl+opt+space", "f18").
struct HotkeySpec {
    /// Raw flag bits that must all be set. Side-specific modifiers use the
    /// device-dependent bits so left and right can be told apart.
    var requiredBits: UInt64 = 0
    /// The device-independent modifiers implied by `requiredBits`.
    var requiredModifiers: UInt64 = 0
    var keyCode: Int64?
    var description = ""

    var isModifierOnly: Bool { keyCode == nil }

    static let modifierMask: UInt64 =
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    private static let fn = CGEventFlags.maskSecondaryFn.rawValue
    private static let ctrl = CGEventFlags.maskControl.rawValue
    private static let opt = CGEventFlags.maskAlternate.rawValue
    private static let cmd = CGEventFlags.maskCommand.rawValue
    private static let shift = CGEventFlags.maskShift.rawValue

    // name -> (bits that must be set, device-independent modifier)
    private static let modifiers: [String: (UInt64, UInt64)] = [
        "fn": (fn, fn), "globe": (fn, fn),
        "ctrl": (ctrl, ctrl), "control": (ctrl, ctrl),
        "left_control": (0x1, ctrl), "right_control": (0x2000, ctrl),
        "opt": (opt, opt), "option": (opt, opt), "alt": (opt, opt),
        "left_option": (0x20, opt), "right_option": (0x40, opt),
        "cmd": (cmd, cmd), "command": (cmd, cmd),
        "left_command": (0x08, cmd), "right_command": (0x10, cmd),
        "shift": (shift, shift),
        "left_shift": (0x02, shift), "right_shift": (0x04, shift),
    ]

    private static let keys: [String: Int64] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "`": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]

    /// How the hotkey is written in menus: "fn", "Right ⌥", "⌃⌥Space".
    var displayName: String {
        let symbols: [String: String] = [
            "fn": "fn", "globe": "fn", "ctrl": "⌃", "control": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥",
            "cmd": "⌘", "command": "⌘", "shift": "⇧",
        ]
        let parts = description.split(separator: "+").map { token -> String in
            let name = String(token)
            if let symbol = symbols[name] { return symbol }
            if let side = ["left_", "right_"].first(where: { name.hasPrefix($0) }),
                let symbol = symbols[String(name.dropFirst(side.count))]
            {
                return (side == "left_" ? "Left " : "Right ") + symbol
            }
            return name.count == 1 ? name.uppercased() : name.prefix(1).uppercased() + name.dropFirst()
        }
        // Symbol runs like ⌃⌥Space read as one chord; "Right ⌥" and "fn" need spacing.
        let spaced = parts.contains { $0.contains(" ") || $0 == "fn" }
        return parts.joined(separator: spaced ? " " : "")
    }

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String) throws -> HotkeySpec {
        var spec = HotkeySpec()
        let tokens = text.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_")
        }
        guard !tokens.isEmpty else { throw ParseError(description: "hotkey is empty") }
        for token in tokens {
            if let (bits, modifier) = modifiers[token] {
                spec.requiredBits |= bits
                spec.requiredModifiers |= modifier
            } else if let code = keys[token] {
                guard spec.keyCode == nil else {
                    throw ParseError(description: "hotkey \"\(text)\" has more than one non-modifier key")
                }
                spec.keyCode = code
            } else {
                throw ParseError(description: "unknown key \"\(token)\" in hotkey \"\(text)\"")
            }
        }
        spec.description = tokens.joined(separator: "+")
        return spec
    }

    /// True when exactly this hotkey's modifiers are down and no others.
    func modifiersMatch(_ flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        var relevant = HotkeySpec.modifierMask
        // Function and arrow keys report fn as set, so only compare it when it is part of the hotkey.
        if !isModifierOnly && requiredModifiers & HotkeySpec.fn == 0 { relevant &= ~HotkeySpec.fn }
        return raw & requiredBits == requiredBits && raw & relevant == requiredModifiers
    }
}

/// Watches the keyboard with a session event tap and reports hotkey transitions.
/// Needs the Accessibility permission; `start()` returns false until it is granted.
final class HotkeyMonitor {
    /// Marks events this process posts, so the tap can ignore its own ⌘V.
    static let syntheticEventTag: Int64 = 0x7961_7021

    var spec: HotkeySpec
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// A different key was pressed while a modifier-only hotkey was held.
    var onOtherKey: (() -> Void)?
    /// Escape was pressed. Return true to swallow it.
    var onEscape: (() -> Bool)?
    /// Space was pressed while a modifier-only hotkey was held. Return true to swallow it
    /// (Yap uses it to lock into hands-free mode) instead of treating it as another key.
    var onSpaceWhileHeld: (() -> Bool)?

    private var tap: CFMachPort?
    private var isDown = false
    private var swallowSpaceUp = false

    init(spec: HotkeySpec) {
        self.spec = spec
    }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// Returns true when the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == HotkeyMonitor.syntheticEventTag { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .flagsChanged:
            guard spec.isModifierOnly else { return false }
            let matches = spec.modifiersMatch(event.flags)
            if matches && !isDown {
                isDown = true
                onDown?()
            } else if !matches && isDown {
                isDown = false
                onUp?()
            }
            return false

        case .keyDown:
            if keyCode == 53, onEscape?() == true { return true }
            if let hotkey = spec.keyCode {
                guard keyCode == hotkey else { return false }
                if isDown { return true }  // key repeat while held
                guard spec.modifiersMatch(event.flags) else { return false }
                isDown = true
                onDown?()
                return true
            }
            if isDown, keyCode == 49, onSpaceWhileHeld?() == true {
                swallowSpaceUp = true
                return true
            }
            if isDown { onOtherKey?() }
            return false

        case .keyUp:
            if keyCode == 49, swallowSpaceUp {
                swallowSpaceUp = false
                return true
            }
            guard let hotkey = spec.keyCode, keyCode == hotkey, isDown else { return false }
            isDown = false
            onUp?()
            return true

        default:
            return false
        }
    }
}
