import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts transcribed text where the user is typing, or on the clipboard when they are not.
enum Inserter {
    enum Focus: String {
        /// A text input has keyboard focus.
        case text
        /// Something that is clearly not a text input has focus.
        case none
        /// The app does not say. Common in Electron apps and some terminals.
        case unknown
    }

    enum Delivery: String {
        /// Pasted into the focused input; the previous clipboard was put back.
        case pasted
        /// Pasted, and the text was left on the clipboard in case the paste went nowhere.
        case pastedAndCopied = "pasted+copied"
        /// Only copied to the clipboard.
        case copied
    }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// Roles that can host an editable region the accessibility tree does not describe.
    private static let ambiguousRoles: Set<String> = [
        "AXWebArea", kAXGroupRole, kAXScrollAreaRole, kAXWindowRole, kAXApplicationRole,
        kAXUnknownRole, kAXLayoutAreaRole, kAXSplitGroupRole, "",
    ]

    static func focus() -> Focus {
        guard let element = focusedElement() else { return .unknown }
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        if textRoles.contains(role) { return .text }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
            settable.boolValue
        {
            return .text
        }
        return ambiguousRoles.contains(role) ? .unknown : .none
    }

    /// Pastes or copies `text`. With `pressReturn`, a pasted message is also sent.
    static func deliver(_ text: String, config: Config, pressReturn: Bool = false) -> Delivery {
        let pasteboard = NSPasteboard.general
        let trusted = AXIsProcessTrusted()

        let focus: Focus
        switch config.paste {
        case .clipboard: focus = .none
        case .always: focus = .text
        case .auto: focus = trusted ? self.focus() : .none
        }

        guard trusted, focus != .none else {
            write(text, to: pasteboard, transient: false)
            return .copied
        }

        let restore = focus == .text && config.restoreClipboard
        let snapshot = restore ? PasteboardSnapshot(pasteboard) : nil
        // A trailing space only helps when you keep typing, not when the message is sent.
        let pasted = config.trailingSpace && !pressReturn ? text + " " : text
        write(pasted, to: pasteboard, transient: restore)
        let changeCount = pasteboard.changeCount
        postKey(keyCodeForV(), flags: .maskCommand)
        if pressReturn {
            // Give the app time to insert the paste; Electron apps handle it asynchronously.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                postKey(CGKeyCode(kVK_Return), flags: [])
            }
        }

        if let snapshot {
            // The target app reads the pasteboard asynchronously, so wait before restoring.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard pasteboard.changeCount == changeCount else { return }
                snapshot.restore(to: pasteboard)
            }
            return .pasted
        }
        return .pastedAndCopied
    }

    // MARK: - Accessibility

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        // Do not let a hung app hold up the paste.
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        if let element = elementAttribute(systemWide, kAXFocusedUIElementAttribute) { return element }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        return elementAttribute(appElement, kAXFocusedUIElementAttribute)
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Pasteboard

    private static func write(_ text: String, to pasteboard: NSPasteboard, transient: Bool) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if transient {
            // nspasteboard.org marker: clipboard managers skip entries that are about to be replaced.
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                var contents: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { contents[type] = data }
                }
                return contents
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restored = items.map { contents -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }

    // MARK: - Synthetic keys

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                continue
            }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    /// The key that produces "v" with ⌘ held in the current layout, so paste works on Dvorak,
    /// AZERTY and layouts like "Dvorak – QWERTY ⌘" that remap only while ⌘ is down.
    private static func keyCodeForV() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { bytes -> CGKeyCode in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return fallback
            }
            for code in 0..<UInt16(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), commandState, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
                if status == noErr, length == 1, characters[0] == UniChar(ascii: "v") { return code }
            }
            return fallback
        }
    }
}

extension UniChar {
    fileprivate init(ascii character: Character) {
        self = UniChar(character.asciiValue ?? 0)
    }
}
