# Changelog

## Unreleased

- An on/off switch at the top of the menu turns Yap off without quitting: the hotkey goes back to macOS, the screen is not read, and the microphone is released. The model stays loaded, so switching back on is instant. Also `yap on` and `yap off`; `yap status` and `yap doctor` show it. The setting survives restarts.
- The menu's status line lines up with the items below it.

## 0.1.0

First release.

- Hold-to-talk dictation with NVIDIA Parakeet on the Neural Engine, about 50 ms from release to text.
- Pastes into the focused text field, or copies when nothing editable has focus.
- Formatting: filler words, stutters, spoken and natural lists, numbers said in pieces ("seven two seven" → 727), "new line", "new paragraph", "scratch that", spoken punctuation.
- Screen context: names and jargon visible on screen are checked against the audio and spelled right, with no added delay unless a correction is made. Identifiers such as RE-727 or python3 are matched exactly.
- Hands-free mode (hold fn, tap Space) with a stop button.
- Auto-send: press Return after pasting, per app or everywhere.
- Menu bar app with status, recent dictations, and quick settings.
- `yap` CLI: start, stop, doctor, hotkey, model, config, send, transcribe, history, logs, login item.
