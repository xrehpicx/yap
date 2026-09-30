# Contributing to Yap

Thanks for helping. Bug reports, fixes, and ideas are all welcome.

## Set up

You need macOS 14 or later on Apple Silicon, Node.js 20.11 or later, and the Xcode Command Line Tools.

```sh
git clone https://github.com/xrehpicx/yap.git
cd yap
npm install        # builds dist/Yap.app
node bin/yap.js start
```

After changing anything in `native/`, rebuild and restart:

```sh
npm run build
node bin/yap.js restart
```

`node bin/yap.js run` runs the app in the foreground with its log on your terminal. Permissions then belong to your terminal rather than to Yap, so you may be asked for them again.

## Signing

macOS ties the Microphone and Accessibility grants to the app's code signature. `npm run build` signs with the first **Developer ID Application** or **Apple Development** identity in your keychain, which keeps the grants across rebuilds. With neither, it falls back to an ad-hoc signature, and macOS asks again after every build. To choose an identity:

```sh
YAP_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" npm run build
```

## Tests

```sh
npm test
```

This runs the Swift tests in `native/Tests`: the formatter, hotkey parsing, and a render of every pill state. Formatter tests use real Parakeet transcripts as inputs. When you change a rule, add the transcript that motivated it.

To see how a change affects real speech without dictating:

```sh
say -o /tmp/test.wav --data-format=LEI16@16000 "First, refactor. Second, migrate."
node bin/yap.js transcribe /tmp/test.wav
```

`--raw` skips formatting, and `--runs 5` repeats the transcription to measure speed.

## Images

Everything in `docs/images` is generated from code, so it stays in sync with the app:

```sh
swift scripts/make-icon.swift                                 # native/Resources/AppIcon.icns
swift scripts/make-icon.swift --preview docs/images/icon.png  # the README icon
YAP_DOCS_DIR="$PWD/docs/images" swift test --package-path native --filter DocsImagesTests
```

The last command renders the pill animation, the pill states, the menu bar glyphs, and the README artwork.

## Guidelines

- **Keep dictation instant.** Anything on the path from releasing the key to pasting must add no noticeable time. Measure with `yap logs`, which prints how long each take took to transcribe.
- **Match the design.** Visuals use paper, ink, and the orange caret (`#FF5A1F`).
- **Stay local.** No network calls beyond the model download, and no telemetry.
- **Write plainly.** Code comments, docs and interface text should be short and concrete.

## Pull requests

- Keep each pull request to one change, and say what it fixes and how you tested it.
- Run `npm test` before opening it.
- By contributing, you agree that your contribution is licensed under the Apache License 2.0.
