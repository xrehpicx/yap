# Choosing a speech model

Yap needs a model that is accurate on everyday and technical English, runs on the Mac, and returns text fast enough that dictation feels instant. That rules out anything that needs a server or a large GPU.

## What was compared

All measurements are on an M4 Max with 36 GB of memory, running macOS 27. The model was already loaded, and each time is the median of six runs. The clips are three synthetic sentences and three real recordings of someone dictating to a coding agent.

| Clip | Parakeet v2 | Parakeet Ultra | Apple SpeechAnalyzer |
| --- | --- | --- | --- |
| 5 s | 45 ms | 51 ms | 100 ms |
| 14 s | 65 ms | 75 ms | 277 ms |
| 17–21 s, real voice | 79–85 ms | 105–113 ms | 199–313 ms |
| 29 s | 100 ms | 151 ms | 450 ms |

Accuracy on the technical terms in the clips:

| | Parakeet v2 | Parakeet Ultra | Apple SpeechAnalyzer |
| --- | --- | --- | --- |
| Redis | ✓ | "redisc" | ✓ |
| Kubernetes | ✓ | ✓ | "Cubernates" |
| PostgreSQL | ✓ | ✓ | "post-GerSQL" |
| TypeScript | ✓ | ✓ | "type script" |

Published benchmarks point the same way. On LibriSpeech, Parakeet v2 scores 2.0% WER on clean speech and 3.4% on noisy speech. Apple's SpeechAnalyzer scores 2.1% and 4.6%, and Whisper Small 3.7% and 8.0% ([Lyonesse](https://lyonesse.app/blog/parakeet-moss-apple-speech-benchmark.html)).

## Why not Whisper

Whisper covers 99 languages, but on Apple Silicon it is slower and less accurate on English than Parakeet. Whisper large-v3 averages 7.4% WER against Parakeet's 6.3% on the Open ASR Leaderboard, at roughly a twentieth of the throughput ([LocalAimaster](https://localaimaster.com/blog/best-local-speech-to-text-models)). For dictation, where every take is short and waited on, that gap is the whole experience.

## Neural Engine or GPU

FluidAudio's own notes found the GPU slightly faster for Parakeet v3 on an M4 Pro. On an M4 Max the Neural Engine won for every model:

- About 4× faster for Parakeet Ultra's int8 encoder.
- About 25% faster for v2.

Yap uses the Neural Engine. To compare on your own Mac: `yap transcribe <file> --runs 5 --compute gpu` against `--compute ane`.

## The options in Yap

| Model | Languages | Download | Pick it when |
| --- | --- | --- | --- |
| `parakeet-v2` | English | 450 MB | You dictate in English (default) |
| `parakeet-ultra` | 25 European languages | 630 MB | You dictate in another European language |
| `parakeet-v3` | 25 European languages | 480 MB | You want the original multilingual release |
| `parakeet-unified` | English | 600 MB | You want to try NVIDIA's newer unified model |

None of them cover Hindi, Chinese, Japanese or Korean. Parakeet models are licensed CC-BY-4.0 by NVIDIA; Ultra is a post-training by Moondream under the same license.
