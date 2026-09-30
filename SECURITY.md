# Security and privacy

## What Yap can access

Yap needs two macOS permissions:

- **Microphone.** Audio is captured only while you hold the hotkey or during a hands-free take. It is transcribed in memory and never written to disk.
- **Accessibility.** Used for four things:
  - Watching for the hotkey with an event tap. Yap only reacts to its hotkey, Space while the hotkey is held, and Esc while recording, and does not record other keys.
  - Asking which element has focus, to decide between pasting and copying.
  - Reading the text visible in the front window when you start dictating, to pick out names and terms to listen for (screen context). The text is kept in memory for that one dictation and is never written to disk, logged, or sent anywhere. Turn it off with `yap config set screenContext false`.
  - Sending ⌘V, and Return when auto-send is on.

For Electron apps (Slack, VS Code, Discord…), Yap asks the app to build its accessibility tree so its text can be read; this is the same switch screen readers use.

## What Yap stores

| Path | Contents |
| --- | --- |
| `~/.config/yap/config.json` | Your settings |
| `~/Library/Application Support/yap/history.jsonl` | Transcripts, unless `history` is off |
| `~/Library/Logs/yap/yap.log` | Timings and events, without transcript text |
| `~/Library/Application Support/FluidAudio/Models/` | Downloaded speech models, including the small model used for screen context |

## Network

The only network traffic is the model download from Hugging Face on first use, or after switching models. There is no telemetry, analytics, or update check.

## Reporting a vulnerability

Please report security issues privately via [GitHub's private vulnerability reporting](https://github.com/xrehpicx/yap/security/advisories/new) rather than a public issue. You will get a reply within a week.
