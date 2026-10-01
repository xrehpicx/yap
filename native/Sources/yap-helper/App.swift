import AVFoundation
import AppKit
import ApplicationServices

/// Ties the pieces together: hotkey → record → transcribe → insert.
/// Everything here runs on the main thread, which is what makes the `Sendable` claim hold.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @unchecked Sendable {
    private enum Phase {
        case idle
        /// Hands-free takes keep recording after the hotkey is released.
        case recording(since: Date, handsFree: Bool)
        case transcribing
    }

    /// Takes shorter than this are treated as an accidental tap of the hotkey.
    private static let minimumHold: TimeInterval = 0.25
    /// A modifier-only hotkey toggles when it is pressed and released within this window.
    private static let tapWindow: TimeInterval = 0.5
    /// Keep the microphone open this long after release so the last word is not clipped.
    private static let tail: TimeInterval = 0.15
    /// A forgotten hands-free take stops on its own after this long.
    private static let handsFreeLimit: TimeInterval = 10 * 60

    private var config = Config.load()
    private var state = DaemonState()
    private let recorder = Recorder()
    private let hud = HUD()
    private var transcriber: Transcriber!
    private var loadTask: Task<Void, Error>?
    private var hotkey: HotkeyMonitor!
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    private var configError: String?
    private var phase = Phase.idle
    private var hotkeyDownAt = Date.distantPast
    private var isCleanTap = false
    private var handsFreeLimitWork: DispatchWorkItem?
    /// Counts takes, so a vocabulary prepared for an old take is not used for a new one.
    private var take = 0
    private var screenVocabulary: ScreenVocabulary?
    private weak var statusMenuItem: NSMenuItem?
    private weak var hintMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("yap-helper starting (pid \(state.pid))")
        installSignalHandlers()

        let spec: HotkeySpec
        do {
            spec = try HotkeySpec.parse(config.hotkey)
        } catch {
            Log.info("config: \(error); falling back to fn")
            configError = "\(error)"
            state.error = configError
            spec = try! HotkeySpec.parse("fn")
        }
        state.hotkey = spec.description
        hotkey = HotkeyMonitor(spec: spec)
        // These fire inside the event tap, which macOS disables if it is slow to return,
        // so the real work is deferred. Escape has to answer synchronously to be swallowed.
        hotkey.onDown = { [weak self] in DispatchQueue.main.async { self?.hotkeyDown() } }
        hotkey.onUp = { [weak self] in DispatchQueue.main.async { self?.hotkeyUp() } }
        hotkey.onOtherKey = { [weak self] in DispatchQueue.main.async { self?.otherKeyPressed() } }
        hotkey.onEscape = { [weak self] in self?.escapePressed() ?? false }
        hotkey.onSpaceWhileHeld = { [weak self] in self?.spaceWhileHeld() ?? false }

        let model = ModelID(rawValue: config.model) ?? .v2
        if model.rawValue != config.model {
            Log.info("config: unknown model \"\(config.model)\"; using \(model.rawValue)")
        }
        state.model = model.rawValue
        transcriber = Transcriber(model: model)
        hud.levelProvider = { [weak self] in self?.recorder.level ?? 0 }
        hud.onStop = { [weak self] in self?.stopButtonClicked() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "Yap"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        state.paused = config.paused
        recorder.keepsPrepared = !config.paused
        loadModel()
        requestMicrophone()
        startHotkey()
        // Browsers and Electron apps build their accessibility tree lazily; wake it when an app
        // comes to the front, so screen context is ready for the first dictation there.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard self?.config.screenContext == true, self?.config.paused == false,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            DispatchQueue.global(qos: .utility).async { ScreenContext.warmUp(app) }
        }
        refresh()
    }

    // MARK: - Setup

    private func loadModel() {
        state.phase = "loading model"
        state.modelReady = false
        let transcriber = self.transcriber!
        let task = Task {
            try await transcriber.load { message in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.state.modelReady else { return }
                    self.state.phase = message
                    self.refresh()
                }
            }
        }
        loadTask = task
        Task { @MainActor in
            let started = Date()
            do {
                try await task.value
                Log.info("model \(self.state.model) ready in \(Self.milliseconds(since: started)) ms")
                self.state.modelReady = true
                self.state.phase = "ready"
                self.state.error = self.configError
                self.loadVocabularySupport()
            } catch {
                Log.info("model load failed: \(error.localizedDescription)")
                self.state.phase = "model failed to load"
                self.state.error = error.localizedDescription
                self.loadTask = nil
            }
            self.refresh()
        }
    }

    /// The small model that checks screen words against the audio. Loaded after the main model,
    /// so it never delays being ready to dictate.
    private func loadVocabularySupport() {
        guard config.usesVocabulary else { return }
        let transcriber = self.transcriber!
        // Not .utility: macOS throttles Core ML's model compiler at that priority (31 s instead of ~0.5 s).
        Task.detached(priority: .userInitiated) {
            Vocabulary.warmUp()
            let started = Date()
            do {
                try await transcriber.loadVocabularySupport()
                Log.info("vocabulary model ready in \(Self.milliseconds(since: started)) ms")
            } catch {
                Log.info("vocabulary model failed to load: \(error.localizedDescription)")
            }
        }
    }

    /// Reads the screen and prepares its words while the user talks, off the main thread.
    private func prepareVocabulary() {
        take += 1
        screenVocabulary = nil
        guard config.usesVocabulary else { return }
        let thisTake = take
        let (readScreen, always, debug) = (config.screenContext, config.vocabulary, config.debug)
        let transcriber = self.transcriber!
        Task.detached(priority: .userInitiated) {
            let started = Date()
            let texts = readScreen ? ScreenContext.visibleText() : []
            let readMs = Self.milliseconds(since: started)
            var vocabulary = ScreenVocabulary(
                terms: Vocabulary.terms(in: texts, always: always), identifiers: Vocabulary.identifiers(in: texts),
                phrases: Vocabulary.phraseIndex(from: texts + always))
            if await transcriber.supportsVocabulary {
                vocabulary.plan = await transcriber.prepareVocabulary(vocabulary.terms)
            }
            let totalMs = Self.milliseconds(since: started)
            let ready = vocabulary
            await MainActor.run {
                guard self.take == thisTake else { return }
                self.screenVocabulary = ready
                let characters = texts.reduce(0) { $0 + $1.count }
                Log.info(
                    "vocabulary: \(ready.terms.count) terms, \(ready.identifiers.count) identifiers, "
                        + "\(ready.phrases.count) phrases from "
                        + "\(characters) characters (screen read in \(readMs) ms, ready in \(totalMs) ms)")
                if debug {
                    Log.info("vocabulary terms: \(ready.terms.joined(separator: ", "))")
                    Log.info("vocabulary identifiers: \(ready.identifiers.joined(separator: ", "))")
                }
            }
        }
    }

    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            state.microphone = "granted"
            recorder.prepare()
        case .notDetermined:
            state.microphone = "not requested"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.state.microphone = granted ? "granted" : "denied"
                    if granted { self?.recorder.prepare() }
                    self?.refresh()
                }
            }
        default:
            state.microphone = "denied"
        }
    }

    private func startHotkey() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        state.accessibility = AXIsProcessTrustedWithOptions(prompt)
        // Switched off, Yap installs no event tap at all; switching on starts it.
        if state.accessibility, config.paused || hotkey.start() {
            state.hotkeyActive = !config.paused
            return
        }

        Log.info("waiting for the Accessibility permission")
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.config.paused || self.hotkey.start() else { return }
            timer.invalidate()
            Log.info("Accessibility granted; " + (self.config.paused ? "Yap is off" : "hotkey \(self.state.hotkey) is active"))
            self.state.accessibility = true
            self.state.hotkeyActive = !self.config.paused
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                try? FileManager.default.removeItem(at: Paths.state)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        // `yap off` and `yap on`.
        for (number, paused) in [(SIGUSR1, true), (SIGUSR2, false)] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.setPaused(paused) }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - On/off

    /// The menu's switch, `yap off` and `yap on`. Off removes the event tap, so the hotkey goes
    /// back to macOS, and stops reading the screen and holding the microphone engine. The model
    /// stays loaded, so switching back on is instant.
    private func setPaused(_ paused: Bool) {
        guard paused != config.paused else { return }
        config.paused = paused
        Config.persist("paused", paused)
        state.paused = paused
        if paused {
            if case .recording = phase { cancelRecording() }
            hotkey.stop()
            state.hotkeyActive = false
            recorder.keepsPrepared = false
        } else {
            recorder.keepsPrepared = true
            if state.microphone == "granted" { recorder.prepare() }
            state.accessibility = AXIsProcessTrusted()
            state.hotkeyActive = state.accessibility && hotkey.start()
        }
        Log.info("switched \(paused ? "off" : "on")")
        refresh()
        updateStatusItems()
    }

    // MARK: - Hotkey

    private func hotkeyDown() {
        hotkeyDownAt = Date()
        isCleanTap = true
        // Tapping the hotkey again ends a hands-free take.
        if case .recording(_, handsFree: true) = phase {
            finishRecording()
            return
        }
        switch config.mode {
        case .hold:
            if case .idle = phase { beginRecording() }
        case .toggle:
            if !hotkey.spec.isModifierOnly { toggleRecording() }
        }
    }

    private func hotkeyUp() {
        switch config.mode {
        case .hold:
            guard case .recording(let since, handsFree: false) = phase else { return }
            if Date().timeIntervalSince(since) < Self.minimumHold {
                cancelRecording()
            } else {
                finishRecording()
            }
        case .toggle:
            // A modifier on its own toggles on a clean tap, so fn+arrow and ⌥-shortcuts still work.
            let held = Date().timeIntervalSince(hotkeyDownAt)
            if hotkey.spec.isModifierOnly, isCleanTap, held < Self.tapWindow { toggleRecording() }
        }
    }

    private func otherKeyPressed() {
        isCleanTap = false
        // The modifier was the start of an ordinary shortcut, not a dictation.
        if config.mode == .hold, case .recording(_, handsFree: false) = phase { cancelRecording() }
    }

    /// Space while holding the hotkey locks the take into hands-free mode.
    private func spaceWhileHeld() -> Bool {
        guard config.mode == .hold, case .recording(let since, let handsFree) = phase else { return false }
        guard !handsFree else { return true }  // key repeat
        phase = .recording(since: since, handsFree: true)
        Log.info("hands-free on")
        playSound("Tink")
        if config.hud { hud.show(.listening(handsFree: true)) }
        let limit = DispatchWorkItem { [weak self] in
            guard let self, case .recording(_, handsFree: true) = self.phase else { return }
            Log.info("hands-free take hit the \(Int(Self.handsFreeLimit / 60)) minute limit")
            self.finishRecording()
        }
        handsFreeLimitWork = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handsFreeLimit, execute: limit)
        return true
    }

    private func stopButtonClicked() {
        guard case .recording = phase else { return }
        finishRecording()
    }

    private func escapePressed() -> Bool {
        guard case .recording = phase else { return false }
        cancelRecording()
        return true
    }

    private func toggleRecording() {
        switch phase {
        case .idle: beginRecording()
        case .recording: finishRecording()
        case .transcribing: break
        }
    }

    // MARK: - Dictation

    private func beginRecording() {
        guard state.microphone == "granted" else {
            Log.info("hotkey pressed but microphone access is \(state.microphone)")
            hud.flash(symbol: "mic.slash.fill", "Microphone access needed")
            return
        }
        let started = Date()
        do {
            try recorder.start()
        } catch {
            Log.info("recorder: \(error.localizedDescription)")
            hud.flash(symbol: "mic.slash.fill", "No microphone found")
            return
        }
        Log.info("recording (microphone opened in \(Self.milliseconds(since: started)) ms)")
        // Toggle mode is hands-free by nature, so it gets the stop button too.
        let handsFree = config.mode == .toggle
        phase = .recording(since: Date(), handsFree: handsFree)
        playSound("Tink")
        if config.hud { hud.show(.listening(handsFree: handsFree)) }
        refresh()
        prepareVocabulary()
    }

    private func cancelRecording() {
        handsFreeLimitWork?.cancel()
        _ = recorder.stop()
        phase = .idle
        hud.hide()
        refresh()
        recorder.prepare()
    }

    private func finishRecording() {
        handsFreeLimitWork?.cancel()
        phase = .transcribing
        if config.hud { hud.show(.transcribing) }
        refresh()
        let transcriber = self.transcriber!
        Task(priority: .userInitiated) { await transcriber.prewarm() }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tail) { [self] in
            let samples = recorder.stop()
            playSound("Pop")
            let audioSeconds = Double(samples.count) / Recorder.targetSampleRate
            if loadTask == nil { loadModel() }
            let loadTask = self.loadTask
            // Whatever vocabulary is ready now; a take never waits for the screen to be read.
            let screen = screenVocabulary
            screenVocabulary = nil

            Task { @MainActor in
                do {
                    try await loadTask?.value
                    let started = Date()
                    let transcript = try await transcriber.transcribe(samples, plan: screen?.plan)
                    let raw = transcript.text
                    var text = self.config.format ? Formatter.format(raw) : raw
                    if let screen {
                        text = Vocabulary.snap(text, to: screen.identifiers + screen.terms)
                        text = Vocabulary.soundAlike(text, phrases: screen.phrases)
                    }
                    let elapsed = Self.milliseconds(since: started)
                    if transcript.checkedVocabulary {
                        Log.info("vocabulary: checked the audio, fixed \(transcript.fixes) word(s)")
                    }
                    self.deliver(text, raw: raw, audioSeconds: audioSeconds, transcribeMs: elapsed)
                } catch {
                    Log.info("transcription failed: \(error.localizedDescription)")
                    self.hud.flash(symbol: "exclamationmark.triangle.fill", "Couldn’t transcribe")
                }
                self.phase = .idle
                self.refresh()
                // Only now, with the text delivered, spend main-thread time on the next take.
                self.recorder.prepare()
            }
        }
    }

    private func deliver(_ formatted: String, raw: String, audioSeconds: Double, transcribeMs: Int) {
        let text = applyReplacements(to: formatted)
        guard !text.isEmpty else {
            Log.info(String(format: "no speech in %.1f s of audio (%d ms)", audioSeconds, transcribeMs))
            hud.flash(symbol: "waveform.slash", "Didn’t catch that")
            return
        }

        let app = NSWorkspace.shared.frontmostApplication
        let send = config.sendsReturn(in: app?.bundleIdentifier)
        let delivery = Inserter.deliver(text, config: config, pressReturn: send)
        let sent = send && delivery != .copied
        Log.info(
            String(
                format: "%d chars from %.1f s of audio in %d ms → %@%@", text.count, audioSeconds, transcribeMs,
                delivery.rawValue, sent ? ", sent" : ""))
        if config.history {
            History.append(
                text: text, raw: raw, audioSeconds: audioSeconds, transcribeMs: Double(transcribeMs),
                delivery: delivery.rawValue)
        }
        if delivery == .copied {
            hud.flash(symbol: "doc.on.clipboard.fill", "Copied", detail: "⌘V to paste")
        } else {
            hud.hide()
        }
    }

    private func applyReplacements(to text: String) -> String {
        var text = text
        for (phrase, replacement) in config.replacements where !phrase.isEmpty {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return text
    }

    private func playSound(_ name: String) {
        guard config.sounds else { return }
        NSSound(named: name)?.play()
    }

    private static func milliseconds(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }

    // MARK: - Status

    private var isReady: Bool {
        state.hotkeyActive && state.modelReady && state.microphone != "denied"
    }

    /// Publishes the current state to the menu bar icon and to `state.json` for the CLI.
    /// The menu itself is built when it opens.
    private func refresh() {
        state.write()
        let icon: MenuBarIcon.State
        switch phase {
        case .recording: icon = .recording
        case .transcribing: icon = .transcribing
        case .idle: icon = config.paused ? .off : isReady ? .idle : .attention
        }
        statusItem.button?.image = MenuBarIcon.image(for: icon)
    }

    private func statusLine() -> (String, NSColor) {
        switch phase {
        case .recording: return ("Listening…", .systemRed)
        case .transcribing: return ("Transcribing…", .systemBlue)
        case .idle: break
        }
        if config.paused { return ("Off", .systemGray) }
        if state.error != nil && !state.modelReady { return ("Model failed to load", .systemRed) }
        if !state.modelReady { return (state.phase.prefix(1).uppercased() + state.phase.dropFirst(), .systemOrange) }
        if !state.accessibility { return ("Needs Accessibility access", .systemOrange) }
        if state.microphone == "denied" { return ("Needs microphone access", .systemOrange) }
        return ("Ready", .systemGreen)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem()
        toggle.view = MenuSwitchRow(title: "Yap", isOn: !config.paused) { [weak self] isOn in
            self?.setPaused(!isOn)
        }
        menu.addItem(toggle)

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(status)
        statusMenuItem = status
        if #available(macOS 14.4, *) {
            hintMenuItem = nil
        } else {
            let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            menu.addItem(hint)
            hintMenuItem = hint
        }
        updateStatusItems()
        menu.addItem(.separator())

        let recent = History.recent(5)
        if !recent.isEmpty {
            let submenu = NSMenu()
            for text in recent {
                let item = menuItem(Self.truncated(text, to: 52), action: #selector(copyDictation(_:)))
                item.representedObject = text
                item.toolTip = text
                submenu.addItem(item)
            }
            let item = menuItem("Recent Dictations", symbol: "clock.arrow.circlepath")
            item.submenu = submenu
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let format = menuItem("Format Text", symbol: "text.badge.checkmark", action: #selector(toggleFormat))
        format.state = config.format ? .on : .off
        format.toolTip = "Remove filler words, handle “new line” and “scratch that”, and turn spoken lists into numbered lists"
        menu.addItem(format)
        menu.addItem(autoSendItem())
        let context = menuItem("Use Screen Context", symbol: "text.viewfinder", action: #selector(toggleScreenContext))
        context.state = config.screenContext ? .on : .off
        context.toolTip = "Listen for names and terms visible on screen, so they come out spelled right"
        menu.addItem(context)
        let sounds = menuItem("Sounds", symbol: "speaker.wave.2", action: #selector(toggleSounds))
        sounds.state = config.sounds ? .on : .off
        menu.addItem(sounds)
        menu.addItem(.separator())

        if !state.accessibility {
            menu.addItem(menuItem("Allow Accessibility Access…", symbol: "hand.raised", action: #selector(openAccessibilitySettings)))
        }
        if state.microphone == "denied" {
            menu.addItem(menuItem("Allow Microphone Access…", symbol: "mic.slash", action: #selector(openMicrophoneSettings)))
        }
        menu.addItem(menuItem("Edit Config…", symbol: "slider.horizontal.3", action: #selector(openConfig)))
        let quit = menuItem("Quit Yap", symbol: "power", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// Fills in the status line, also while the menu is open (the switch changes it in place).
    private func updateStatusItems() {
        guard let status = statusMenuItem else { return }
        let (title, color) = statusLine()
        status.title = title
        // The dot goes where checkmarks go, so the status lines up with the items below it.
        status.state = .on
        status.onStateImage = StatusDot.image(color)
        let key = hotkey.spec.displayName
        let model = ModelID(rawValue: state.model)?.displayName ?? state.model
        // One line, so the dot stays level with the status.
        let hint =
            config.paused
            ? "\(key) works as usual until Yap is back on"
            : config.mode == .hold && hotkey.spec.isModifierOnly
                ? "Hold \(key) to dictate · Space for hands-free"
                : "\(config.mode == .hold ? "Hold" : "Press") \(key) to dictate"
        status.toolTip = "Model: \(model)"
        if #available(macOS 14.4, *) {
            status.subtitle = hint
        } else {
            hintMenuItem?.title = hint
        }
    }

    private func menuItem(_ title: String, symbol: String? = nil, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private static func truncated(_ text: String, to length: Int) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count <= length ? line : line.prefix(length - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    @objc private func copyDictation(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hud.flash(symbol: "doc.on.clipboard.fill", "Copied")
    }

    @objc private func toggleFormat() {
        config.format.toggle()
        Config.persist("format", config.format)
    }

    /// "Auto-Send" ▸ "In <front app>" / "In Every App". Auto-send presses Return after pasting.
    /// Clicking the menu bar does not activate Yap, so the front app is the one being dictated into.
    private func autoSendItem() -> NSMenuItem {
        let everywhere = config.sendApps.contains("*")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let front = NSWorkspace.shared.frontmostApplication
        if let front, let bundleID = front.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier {
            let item = menuItem("In \(front.localizedName ?? bundleID)", action: #selector(toggleSendForApp(_:)))
            item.representedObject = bundleID
            item.image = front.icon.map { icon in
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                return small
            }
            item.state = config.sendApps.contains(bundleID) || everywhere ? .on : .off
            item.isEnabled = !everywhere
            submenu.addItem(item)
        }
        let all = menuItem("In Every App", action: #selector(toggleSendEverywhere))
        all.state = everywhere ? .on : .off
        submenu.addItem(all)

        let item = menuItem("Auto-Send", symbol: "paperplane")
        item.toolTip = "Press Return after pasting, so what you say is sent"
        item.submenu = submenu
        item.state = config.sendsReturn(in: front?.bundleIdentifier) ? .on : .off
        return item
    }

    @objc private func toggleSendForApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if let index = config.sendApps.firstIndex(of: bundleID) {
            config.sendApps.remove(at: index)
        } else {
            config.sendApps.append(bundleID)
        }
        Config.persist("sendApps", config.sendApps)
        Log.info("auto-send \(config.sendApps.contains(bundleID) ? "on" : "off") for \(bundleID)")
    }

    @objc private func toggleSendEverywhere() {
        if let index = config.sendApps.firstIndex(of: "*") {
            config.sendApps.remove(at: index)
        } else {
            config.sendApps.append("*")
        }
        Config.persist("sendApps", config.sendApps)
        Log.info("auto-send in every app \(config.sendApps.contains("*") ? "on" : "off")")
    }

    @objc private func toggleScreenContext() {
        config.screenContext.toggle()
        Config.persist("screenContext", config.screenContext)
        loadVocabularySupport()
    }

    @objc private func toggleSounds() {
        config.sounds.toggle()
        Config.persist("sounds", config.sounds)
    }

    @objc private func openAccessibilitySettings() {
        openSettings("Privacy_Accessibility")
    }

    @objc private func openMicrophoneSettings() {
        openSettings("Privacy_Microphone")
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Paths.config.path) {
            try? Data("{}\n".utf8).write(to: Paths.config)
        }
        NSWorkspace.shared.open(Paths.config)
    }

    @objc private func quit() {
        try? FileManager.default.removeItem(at: Paths.state)
        NSApp.terminate(nil)
    }
}

/// What was read from the screen for one take.
private struct ScreenVocabulary: Sendable {
    /// Unusual words, checked against the audio when the transcript has a near miss.
    var terms: [String]
    /// Keys such as RE-727, matched by their letters and digits.
    var identifiers: [String]
    /// Every short phrase on screen by sound, so "Yeah, plugs" can become "yap logs".
    var phrases: Vocabulary.PhraseIndex
    var plan: VocabularyPlan?
}

/// A menu row with a title and a switch, like the Wi-Fi and Bluetooth menus. Flipping it leaves
/// the menu open, so the status line below can be seen changing.
final class MenuSwitchRow: NSView {
    private let toggle = NSSwitch()
    private let onChange: (Bool) -> Void

    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        autoresizingMask = [.width]
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.setAccessibilityLabel(title)
        for view in [label, toggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            // Lines up with the key equivalents and submenu arrows below.
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed() { onChange(toggle.state == .on) }
}
