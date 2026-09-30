import AppKit
import FluidAudio

// yap-helper is the native half of the `yap` npm package. With no arguments it runs as the
// menu bar dictation daemon; the subcommands below back the CLI and print JSON.

let arguments = Array(CommandLine.arguments.dropFirst())

func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func printJSON(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("yap-helper: \(message)\n".utf8))
    exit(1)
}

func runAsync(_ work: @escaping () async throws -> Void) -> Never {
    Task {
        do {
            try await work()
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }
    dispatchMain()
}

func resolveModel(_ arguments: [String]) -> ModelID {
    let name = value(of: "--model", in: arguments) ?? Config.load().model
    guard let model = ModelID(rawValue: name) else {
        fail("unknown model \"\(name)\". Available: \(ModelID.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return model
}

switch arguments.first {
case "transcribe":
    // transcribe <audio-file> [--model id] [--compute ane|gpu] [--runs n] [--raw] [--vocab "a,b,c"]
    let rest = Array(arguments.dropFirst())
    guard let path = rest.first, !path.hasPrefix("--") else { fail("usage: transcribe <audio-file>") }
    let model = resolveModel(rest)
    let compute = value(of: "--compute", in: rest).flatMap(ComputeUnits.init(rawValue:)) ?? .ane
    let runs = max(1, value(of: "--runs", in: rest).flatMap { Int($0) } ?? 1)
    runAsync {
        let samples = try AudioConverter().resampleAudioFile(path: path)
        let transcriber = Transcriber(model: model, compute: compute)
        let loadStarted = Date()
        try await transcriber.load { message in Log.info(message) }
        let loadMs = Date().timeIntervalSince(loadStarted) * 1000

        let format = !rest.contains("--raw") && Config.load().format
        let terms = (value(of: "--vocab", in: rest) ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        var plan: VocabularyPlan?
        var vocabularyMs = 0.0
        if !terms.isEmpty {
            try await transcriber.loadVocabularySupport()
            let started = Date()
            plan = await transcriber.prepareVocabulary(terms)
            vocabularyMs = (Date().timeIntervalSince(started) * 10_000).rounded() / 10
        }
        var raw = ""
        var text = ""
        var fixes = 0
        var timings: [Double] = []
        for _ in 0..<runs {
            let started = Date()
            let transcript = try await transcriber.transcribe(samples, plan: plan)
            raw = transcript.text
            fixes = transcript.fixes
            text = format ? Formatter.format(raw) : raw
            timings.append((Date().timeIntervalSince(started) * 10_000).rounded() / 10)
        }
        printJSON([
            "text": text,
            "raw": raw,
            "model": model.rawValue,
            "compute": compute.rawValue,
            "audioSeconds": Double(samples.count) / Recorder.targetSampleRate,
            "loadMs": loadMs.rounded(),
            "vocabularyTerms": terms.count,
            "vocabularyFixes": fixes,
            "vocabularyPrepareMs": vocabularyMs,
            "transcribeMs": timings,
        ])
    }

case "download":
    let model = resolveModel(Array(arguments.dropFirst()))
    runAsync {
        try await Transcriber(model: model).load { message in Log.info(message) }
        printJSON(["model": model.rawValue, "ready": true])
    }

case "models":
    printJSON(ModelID.allCases.map { ["id": $0.rawValue, "summary": $0.summary] })

case "check-hotkey":
    do {
        let spec = try HotkeySpec.parse(arguments.dropFirst().first ?? "")
        printJSON(["hotkey": spec.description, "modifierOnly": spec.isModifierOnly])
    } catch {
        fail("\(error)")
    }

case nil, "daemon":
    Paths.ensureDirectories()
    Log.writesToFile = true
    if let bundleID = Bundle.main.bundleIdentifier {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            Log.info("yap is already running (pid \(others[0].processIdentifier))")
            exit(0)
        }
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()

default:
    fail("unknown command \"\(arguments[0])\"")
}
