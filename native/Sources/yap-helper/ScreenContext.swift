import AppKit
import ApplicationServices

/// Reads the text visible in the frontmost window through the Accessibility API, so the words
/// on screen can guide transcription. Text stays in memory and is never logged or stored.
enum ScreenContext {
    private static let textRoles: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField", "AXHeading",
        "AXLink", kAXCellRole,
    ]

    /// Electron apps build their accessibility tree only when asked to, once per process.
    private static var enabledElectronApps: Set<pid_t> = []
    private static let lock = NSLock()

    /// Visible text of the frontmost window, gathered within `budget` seconds. Safe to call off
    /// the main thread.
    static func visibleText(budget: TimeInterval = 0.12, maxCharacters: Int = 40_000) -> [String] {
        let deadline = Date().addingTimeInterval(budget)
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return [] }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        enableElectronAccessibility(app, element: appElement)

        guard let window = element(appElement, kAXFocusedWindowAttribute) ?? element(appElement, kAXMainWindowAttribute)
        else { return [] }

        var texts: [String] = []
        var characters = 0
        if let title = string(window, kAXTitleAttribute) { texts.append(title) }

        // Breadth first, so a deep tree cannot use up the budget before the visible content.
        var queue = [window]
        var index = 0
        while index < queue.count, index < 3000, characters < maxCharacters, Date() < deadline {
            let current = queue[index]
            index += 1
            let values = attributes(current, [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXChildrenAttribute])
            let role = values[0] as? String ?? ""

            if textRoles.contains(role) {
                if let text = visibleString(current, role: role) ?? values[1] as? String ?? values[2] as? String,
                    !text.isEmpty
                {
                    let clipped = String(text.prefix(maxCharacters - characters))
                    texts.append(clipped)
                    characters += clipped.count
                }
            }
            if let children = values[3] as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return texts
    }

    /// Only the visible part of a long text area, such as a code editor, rather than the whole document.
    private static func visibleString(_ element: AXUIElement, role: String) -> String? {
        guard role == kAXTextAreaRole else { return nil }
        var rangeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue
        else { return nil }
        var text: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &text) == .success
        else { return nil }
        return text as? String
    }

    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL else { return false }
        let framework = bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    private static func enableElectronAccessibility(_ app: NSRunningApplication, element: AXUIElement) {
        lock.lock()
        defer { lock.unlock() }
        guard !enabledElectronApps.contains(app.processIdentifier), isElectron(app) else { return }
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        enabledElectronApps.insert(app.processIdentifier)
    }

    // MARK: - Accessibility helpers

    /// Several attributes in one round trip to the other app.
    private static func attributes(_ element: AXUIElement, _ names: [String]) -> [Any?] {
        var values: CFArray?
        guard
            AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
                == .success,
            let array = values as? [Any]
        else { return Array(repeating: nil, count: names.count) }
        // Missing attributes come back as AXValue errors; treat them as absent.
        return array.map { value in
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() { return nil }
            return value
        }
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
