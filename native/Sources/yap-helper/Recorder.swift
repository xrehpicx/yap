import AVFoundation
import CoreAudio
import FluidAudio

/// Captures the default input device and hands back 16 kHz mono samples.
///
/// The next take's engine is built and prepared ahead of time, which roughly halves the time from
/// pressing the hotkey to capturing audio (~40 ms instead of ~100 ms). A prepared engine does
/// not run the microphone; only `start()` does.
final class Recorder {
    enum RecorderError: LocalizedError {
        case noInputDevice
        var errorDescription: String? { "No microphone input is available." }
    }

    static let targetSampleRate = 16_000.0

    private var engine: AVAudioEngine?
    private var prepared: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 48_000.0
    private var currentLevel: Float = 0

    init() {
        // A prepared engine is bound to the input device it was built for.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) {
            [weak self] _, _ in
            guard let self else { return }
            self.discardPrepared()
            self.prepare()
        }
    }

    /// Recent input loudness, 0...1. Safe to read from any thread.
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    var isRecording: Bool { engine != nil }

    /// Gets the next take's engine ready. Call from the main thread when nothing is waiting on it:
    /// building an engine takes a few tens of milliseconds.
    func prepare() {
        guard engine == nil, prepared == nil else { return }
        do {
            prepared = try makeEngine()
        } catch {
            Log.info("recorder: could not prepare the microphone: \(error.localizedDescription)")
        }
    }

    func start() throws {
        var engine = try prepared ?? makeEngine()
        prepared = nil
        do {
            try begin(engine)
        } catch {
            // The prepared engine may have gone stale (sleep, device reconfigured); retry fresh.
            engine.inputNode.removeTap(onBus: 0)
            engine = try makeEngine()
            try begin(engine)
        }
        self.engine = engine
    }

    /// Stops capturing and returns what was recorded, resampled to 16 kHz mono.
    func stop() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        lock.lock()
        let captured = samples
        let rate = sampleRate
        samples.removeAll(keepingCapacity: true)
        currentLevel = 0
        lock.unlock()

        guard !captured.isEmpty else { return [] }
        if rate == Recorder.targetSampleRate { return captured }
        do {
            return try AudioConverter().resample(captured, from: rate)
        } catch {
            Log.info("recorder: resample failed: \(error.localizedDescription)")
            return []
        }
    }

    private func makeEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        return engine
    }

    private func begin(_ engine: AVAudioEngine) throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        sampleRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        currentLevel = 0
        lock.unlock()
        try engine.start()
    }

    private func discardPrepared() {
        prepared?.inputNode.removeTap(onBus: 0)
        prepared = nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0 else { return }

        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for i in 0..<frames { mono[i] += data[i] }
        }
        var sumOfSquares: Float = 0
        let scale = 1 / Float(channelCount)
        for i in 0..<frames {
            mono[i] *= scale
            sumOfSquares += mono[i] * mono[i]
        }
        let rms = (sumOfSquares / Float(frames)).squareRoot()

        lock.lock()
        samples.append(contentsOf: mono)
        // Speech sits around 0.02–0.2 RMS; map that onto a usable 0...1 meter.
        currentLevel = min(1, rms * 8)
        lock.unlock()
    }
}
