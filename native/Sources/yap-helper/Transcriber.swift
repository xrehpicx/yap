import CoreML
import FluidAudio
import Foundation

enum ModelID: String, CaseIterable {
    case v2 = "parakeet-v2"
    case v3 = "parakeet-v3"
    case ultra = "parakeet-ultra"
    case unified = "parakeet-unified"

    var displayName: String {
        switch self {
        case .v2: return "Parakeet v2"
        case .v3: return "Parakeet v3"
        case .ultra: return "Parakeet Ultra"
        case .unified: return "Parakeet Unified"
        }
    }

    var summary: String {
        switch self {
        case .v2: return "English only. Most accurate and fastest for English"
        case .v3: return "25 European languages"
        case .ultra: return "25 European languages. Post-trained v3, more accurate at the same speed"
        case .unified: return "English only, FastConformer-RNNT with punctuation and capitalization"
        }
    }

    fileprivate var tdtVersion: AsrModelVersion? {
        switch self {
        case .v2: return .v2
        case .v3: return .v3
        case .ultra: return .ultra
        case .unified: return nil
        }
    }
}

enum ComputeUnits: String {
    case ane, gpu

    var coreML: MLComputeUnits {
        switch self {
        case .ane: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        }
    }
}

/// Loads one Parakeet model through FluidAudio and keeps it warm for repeated short takes.
actor Transcriber {
    /// Parakeet rejects clips shorter than 300 ms; pad short takes up to this many samples.
    private static let minimumSamples = 16_000

    let model: ModelID
    private let compute: ComputeUnits
    private var tdt: AsrManager?
    private var unified: UnifiedAsrManager?

    // On an M4 Max the Neural Engine beat the GPU for every model here: ~4× for Ultra's int8 encoder,
    // ~25% for v2. FluidAudio's own notes found the GPU slightly faster for v3 on an M4 Pro.
    init(model: ModelID, compute: ComputeUnits = .ane) {
        self.model = model
        self.compute = compute
    }

    /// Downloads the model on first use (a few hundred MB), then loads and warms it.
    func load(progress: (@Sendable (String) -> Void)? = nil) async throws {
        // FluidAudio reports progress even when everything is cached; only relay it for real downloads.
        let cached: Bool
        if let version = model.tdtVersion {
            cached = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
        } else {
            let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetUnified)
            cached = FileManager.default.fileExists(atPath: directory.path)
        }
        let filter = ProgressFilter()
        let handler: ProgressHandler = { update in
            guard !cached else { return }
            let message: String
            switch update.phase {
            case .listing: message = "preparing download"
            case .downloading: message = "downloading model \(Int(update.fractionCompleted * 100))%"
            case .compiling: message = "optimizing model"
            }
            if filter.isNew(message) { progress?(message) }
        }

        if let version = model.tdtVersion {
            let models = try await AsrModels.downloadAndLoad(
                version: version, encoderComputeUnits: compute.coreML, progressHandler: handler)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            tdt = manager
        } else {
            let manager = UnifiedAsrManager()
            try await manager.loadModels(progressHandler: handler)
            unified = manager
        }

        // The first prediction pays for Core ML specialization; spend it here, not on a real take.
        _ = try? await transcribe([Float](repeating: 0, count: Transcriber.minimumSamples))
    }

    /// Runs a throwaway inference. The Neural Engine and CPU clock down after a few idle
    /// seconds, which makes the next transcription ~20–30 ms slower; calling this while the
    /// microphone is still catching the end of a take wakes them in time.
    func prewarm() async {
        guard tdt != nil || unified != nil else { return }
        _ = try? await transcribe([Float](repeating: 0, count: Transcriber.minimumSamples))
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        var samples = samples
        if samples.count < Transcriber.minimumSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: Transcriber.minimumSamples - samples.count))
        }

        let text: String
        if let tdt {
            var state = TdtDecoderState.make(decoderLayers: await tdt.decoderLayerCount)
            text = try await tdt.transcribe(samples, decoderState: &state).text
        } else if let unified {
            text = try await unified.transcribe(samples)
        } else {
            throw ASRError.notInitialized
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Drops repeats so callers only hear about progress that changed.
private final class ProgressFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func isNew(_ message: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard message != last else { return false }
        last = message
        return true
    }
}
