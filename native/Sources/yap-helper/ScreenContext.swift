import AppKit
import ApplicationServices

/// Reads the text visible in the frontmost window through the Accessibility API, so the words
/// on screen can guide transcription. Text stays in memory and is never logged or stored.
enum ScreenContext {
    private static let textRoles: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField", "AXHeading",
        "AXLink", kAXCellRole,
    ]
    /// No single element may crowd out the rest of the screen.
    private static let maxElementCharacters = 4_000
    /// A whole web page or chat, read in one call; chats keep their newest text at the end.
    private static let maxWebAreaCharacters = 16_000

    /// Electron apps build their accessibility tree only when asked to, once per process.
    private static var enabledElectronApps: Set<pid_t> = []
    private static let lock = NSLock()

    /// Visible text of the frontmost window, gathered within `budget` seconds: first the element
    /// being typed into, then everything on screen in the window, skipping content scrolled out
    /// of view. Safe to call off the main thread.
    static func visibleText(
        of target: NSRunningApplication? = nil, budget: TimeInterval = 0.15, maxCharacters: Int = 40_000
    ) -> [String] {
        let deadline = Date().addingTimeInterval(budget)
        guard let app = target ?? NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return [] }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        enableElectronAccessibility(app, element: appElement)

        var texts: [String] = []
        var characters = 0
        func add(_ text: String?) {
            guard let text, !text.isEmpty, characters < maxCharacters else { return }
            let clipped = String(text.prefix(maxCharacters - characters))
            texts.append(clipped)
            characters += clipped.count
        }

        // What the user is typing into, and what surrounds the cursor, matters most.
        if let focused = element(appElement, kAXFocusedUIElementAttribute) {
            add(text(of: focused, role: string(focused, kAXRoleAttribute) ?? "", value: string(focused, kAXValueAttribute)))
        }

        guard let window = element(appElement, kAXFocusedWindowAttribute) ?? element(appElement, kAXMainWindowAttribute)
        else { return texts }
        add(string(window, kAXTitleAttribute))
        let bounds = frame(position: attribute(window, kAXPositionAttribute), size: attribute(window, kAXSizeAttribute))

        // Breadth first, so a deep tree cannot use up the budget before the visible content.
        var queue = [window]
        var index = 0
        while index < queue.count, index < 4000, characters < maxCharacters, Date() < deadline {
            let current = queue[index]
            index += 1
            let values = attributes(
                current,
                [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXChildrenAttribute, kAXPositionAttribute,
                    kAXSizeAttribute])
            // Content scrolled out of view (older messages, the rest of a long page) is skipped
            // along with everything inside it.
            if let bounds, let rect = frame(position: values[4], size: values[5]), !rect.isEmpty,
                !rect.intersects(bounds)
            {
                continue
            }
            let role = values[0] as? String ?? ""
            // Browsers, Electron apps and web views can hand over a whole page in one call,
            // which is far faster than visiting its hundreds of elements one by one.
            if role == "AXWebArea", let page = pageText(current) {
                add(page)
                continue
            }
            if textRoles.contains(role) {
                add(text(of: current, role: role, value: values[1] as? String) ?? values[2] as? String)
            }
            if let children = values[3] as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return texts
    }

    /// Wakes the accessibility tree of an app that just came to the front, so its text is ready
    /// by the time the user dictates. Browsers and Electron apps build the tree lazily.
    static func warmUp(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        enableElectronAccessibility(app, element: appElement)
        if let window = element(appElement, kAXFocusedWindowAttribute) {
            _ = attribute(window, kAXChildrenAttribute)
        }
    }

    /// The text of one element. For long text such as a code editor or terminal, only the part
    /// on screen: the visible range when the app reports it, otherwise the end, where terminals
    /// and chats keep their newest text.
    private static func text(of element: AXUIElement, role: String, value: String?) -> String? {
        if role == kAXTextAreaRole, let visible = visibleString(element) { return visible }
        guard let value else { return nil }
        guard value.count > maxElementCharacters else { return value }
        return role == kAXTextAreaRole
            ? String(value.suffix(maxElementCharacters)) : String(value.prefix(maxElementCharacters))
    }

    private static func pageText(_ webArea: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                webArea, "AXTextMarkerRangeForUIElement" as CFString, webArea, &range) == .success,
            let range
        else { return nil }
        var text: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(webArea, "AXStringForTextMarkerRange" as CFString, range, &text)
                == .success,
            let page = text as? String, !page.isEmpty
        else { return nil }
        return String(page.suffix(maxWebAreaCharacters))
    }

    private static func visibleString(_ element: AXUIElement) -> String? {
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
        return (text as? String).map { String($0.suffix(maxElementCharacters)) }
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

    /// Several attributes in one round trip to the other app. Missing ones are nil.
    private static func attributes(_ element: AXUIElement, _ names: [String]) -> [Any?] {
        var values: CFArray?
        guard
            AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
                == .success,
            let array = values as? [Any]
        else { return Array(repeating: nil, count: names.count) }
        return array.map { value in
            // Missing attributes come back as AXValues holding an error.
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                return nil
            }
            return value
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    /// Screen rectangle from AX position and size values.
    private static func frame(position: Any?, size: Any?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
            CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
