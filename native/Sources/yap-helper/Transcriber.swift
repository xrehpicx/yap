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
    /// Parakeet CTC 110M, used to check vocabulary terms against the audio.
    private var ctcModels: CtcModels?
    private var ctcTokenizer: CtcTokenizer?

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

    // MARK: - Vocabulary

    var supportsVocabulary: Bool { ctcModels != nil }

    /// Loads the small CTC model that vocabulary boosting needs (106 MB, downloaded once).
    func loadVocabularySupport() async throws {
        guard ctcModels == nil else { return }
        let models = try await CtcModels.downloadAndLoad()
        ctcTokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: models.variant))
        ctcModels = models
    }

    /// Prepares words to listen for, such as names and terms on screen. Takes 10–20 ms, so
    /// call it while the user is still talking.
    func prepareVocabulary(_ terms: [String]) async -> VocabularyPlan? {
        guard let ctcModels, let ctcTokenizer, !terms.isEmpty else { return nil }
        let context = CustomVocabularyContext(
            terms: terms.compactMap { term in
                let ids = ctcTokenizer.encode(term)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
            })
        guard !context.terms.isEmpty else { return nil }
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
        guard
            let rescorer = try? await VocabularyRescorer.create(
                spotter: spotter, vocabulary: context, config: .default,
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant))
        else { return nil }
        return VocabularyPlan(
            terms: context.terms.map(\.text), context: context, spotter: spotter, rescorer: rescorer,
            sizeConfig: ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count))
    }

    // MARK: - Transcription

    struct Transcript: Sendable {
        var text: String
        /// Words replaced by vocabulary terms.
        var fixes = 0
        /// Whether the transcript looked like it missed a term, so the audio check was waited for.
        var checkedVocabulary = false
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(samples, plan: nil).text
    }

    /// Transcribes 16 kHz mono audio. With a vocabulary plan, words that look like a misheard
    /// term are checked against the audio and replaced when it agrees.
    func transcribe(_ samples: [Float], plan: VocabularyPlan?) async throws -> Transcript {
        var samples = samples
        if samples.count < Transcriber.minimumSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: Transcriber.minimumSamples - samples.count))
        }

        var transcript = Transcript(text: "")
        if let tdt {
            // The audio check takes ~150 ms, longer than transcription itself. Start it now,
            // alongside the main model, and only wait for it when the transcript needs it.
            let audio = samples
            let spotting = plan.map { plan in
                Task.detached(priority: .background) {
                    try? await plan.spotter.spotKeywordsWithLogProbs(audioSamples: audio, customVocabulary: plan.context)
                }
            }
            var state = TdtDecoderState.make(decoderLayers: await tdt.decoderLayerCount)
            let result = try await tdt.transcribe(samples, decoderState: &state)
            transcript.text = result.text

            if let plan, let spotting, let timings = result.tokenTimings,
                !Vocabulary.nearMisses(in: result.text, terms: plan.terms).isEmpty
            {
                transcript.checkedVocabulary = true
                if let spot = await spotting.value, !spot.logProbs.isEmpty {
                    let output = plan.rescorer.ctcTokenRescore(
                        transcript: result.text, tokenTimings: timings, logProbs: spot.logProbs,
                        frameDuration: spot.frameDuration, cbw: plan.sizeConfig.cbw, marginSeconds: 0.5,
                        minSimilarity: max(plan.sizeConfig.minSimilarity, plan.context.minSimilarity))
                    // Apply the suggestions ourselves: only those that pass Yap's stricter rules,
                    // and on the original text, which keeps its punctuation.
                    // The rescorer copies the heard word's capitalisation ("Shadcn"); use the
                    // spelling from the screen instead ("shadcn").
                    let suggestions = output.replacements.compactMap { result -> (heard: String, term: String)? in
                        guard result.shouldReplace, let word = result.replacementWord else { return nil }
                        let canonical = plan.terms.first { $0.lowercased() == word.lowercased() } ?? word
                        return (result.originalWord, canonical)
                    }
                    let applied = Vocabulary.apply(suggestions, to: result.text)
                    transcript.text = applied.text
                    transcript.fixes = applied.count
                }
            } else {
                spotting?.cancel()
            }
        } else if let unified {
            transcript.text = try await unified.transcribe(samples)
        } else {
            throw ASRError.notInitialized
        }
        transcript.text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript
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

/// Words to listen for during one take, prepared while the user talks.
struct VocabularyPlan: Sendable {
    let terms: [String]
    let context: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let sizeConfig: ContextBiasingConstants.VocabSizeConfig
}
