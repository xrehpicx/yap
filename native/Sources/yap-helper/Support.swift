import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let config = home.appendingPathComponent(".config/yap/config.json")
    static let support = home.appendingPathComponent("Library/Application Support/yap", isDirectory: true)
    static let state = support.appendingPathComponent("state.json")
    static let history = support.appendingPathComponent("history.jsonl")
    static let log = home.appendingPathComponent("Library/Logs/yap/yap.log")

    static func ensureDirectories() {
        for url in [support, log.deletingLastPathComponent(), config.deletingLastPathComponent()] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "yap.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// When true, lines are appended to `Paths.log` as well as stderr.
    static var writesToFile = false

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            guard writesToFile else { return }
            if let handle = try? FileHandle(forWritingTo: Paths.log) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: Paths.log)
            }
        }
    }
}

struct Config: Codable {
    enum Mode: String, Codable { case hold, toggle }
    enum Paste: String, Codable { case auto, always, clipboard }

    var hotkey = "fn"
    var mode = Mode.hold
    var model = ModelID.v2.rawValue
    var paste = Paste.auto
    var format = true
    var restoreClipboard = true
    var trailingSpace = true
    var sounds = true
    var hud = true
    var history = true
    /// Bundle identifiers of apps where Yap presses Return after pasting; "*" means every app.
    var sendApps: [String] = []
    /// Read the words on screen and listen for them, so names and jargon come out right.
    var screenContext = true
    /// Words to always listen for, in addition to those on screen.
    var vocabulary: [String] = []
    /// Log extra detail, including the words picked from the screen. Off by default.
    var debug = false
    var replacements: [String: String] = [:]

    init() {}

    // Every key is optional on disk so a partial config file still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? hotkey
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? mode
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        paste = try c.decodeIfPresent(Paste.self, forKey: .paste) ?? paste
        format = try c.decodeIfPresent(Bool.self, forKey: .format) ?? format
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? restoreClipboard
        trailingSpace = try c.decodeIfPresent(Bool.self, forKey: .trailingSpace) ?? trailingSpace
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? sounds
        hud = try c.decodeIfPresent(Bool.self, forKey: .hud) ?? hud
        history = try c.decodeIfPresent(Bool.self, forKey: .history) ?? history
        sendApps = try c.decodeIfPresent([String].self, forKey: .sendApps) ?? sendApps
        screenContext = try c.decodeIfPresent(Bool.self, forKey: .screenContext) ?? screenContext
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? vocabulary
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? debug
        replacements = try c.decodeIfPresent([String: String].self, forKey: .replacements) ?? replacements
    }

    var usesVocabulary: Bool { screenContext || !vocabulary.isEmpty }

    func sendsReturn(in bundleID: String?) -> Bool {
        sendApps.contains("*") || bundleID.map(sendApps.contains) == true
    }

    /// Updates one key in the config file, keeping everything else as the user wrote it.
    static func persist(_ key: String, _ value: Any) {
        let existing = (try? Data(contentsOf: Paths.config)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        var object = existing as? [String: Any] ?? [:]
        object[key] = value
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        data.append(0x0A)
        try? data.write(to: Paths.config, options: .atomic)
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.info("config: could not parse \(Paths.config.path) (\(error.localizedDescription)); using defaults")
            return Config()
        }
    }
}

/// Snapshot of the daemon that the `yap` CLI reads for `status` and `doctor`.
struct DaemonState: Codable {
    var pid = ProcessInfo.processInfo.processIdentifier
    var phase = "starting"
    var model = ""
    var modelReady = false
    var hotkey = ""
    var hotkeyActive = false
    var accessibility = false
    var microphone = "unknown"
    var error: String?

    func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Paths.state, options: .atomic)
    }
}

enum History {
    /// The most recent dictations, newest first.
    static func recent(_ limit: Int) -> [String] {
        guard let contents = try? String(contentsOf: Paths.history, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").suffix(limit).reversed().compactMap { line in
            let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return entry?["text"] as? String
        }
    }

    /// `raw` is the model's output, recorded only when formatting changed it.
    static func append(text: String, raw: String?, audioSeconds: Double, transcribeMs: Double, delivery: String) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "text": text,
            "audioSeconds": (audioSeconds * 100).rounded() / 100,
            "transcribeMs": transcribeMs.rounded(),
            "delivery": delivery,
        ]
        if let raw, raw != text { entry["raw"] = raw }
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: Paths.history) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Paths.history)
        }
    }
}
