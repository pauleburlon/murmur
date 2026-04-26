# Murmur

Murmur is a macOS dictation app that lives quietly in your menu bar. Hold a hotkey, speak, release — your words are transcribed and instantly pasted into whatever app you're using.

## Download

**[Download Murmur for Mac →](https://github.com/pauleburlon/murmur/releases/latest/download/Murmur.dmg)**

Requires macOS 13 or later.

> **First launch:** macOS may show a security warning. Go to **System Settings → Privacy & Security** → scroll down → click **"Open Anyway"**.

---

## How it works

1. Hold your hotkey (default: **Right ⌥**)
2. Speak
3. Release — text is transcribed and pasted automatically

That's it. Murmur runs in the background, out of your way.

---

## Features

- **Menu bar app** — no Dock icon, always available
- **On-device transcription** via [Whisper](https://github.com/openai/whisper) — works fully offline, audio never leaves your Mac
- **Groq cloud mode** — faster transcription via Groq's API
- **Streaming mode** — text is pasted incrementally as you pause mid-sentence
- **Claude fixup** — optional clean-up of punctuation and errors via Claude Haiku
- **Custom hotkey** — set any key or modifier as your trigger
- **Launch at Login** — starts automatically when you log in
- **5 Whisper models** — from `tiny` (instant) to `large-v3` (most accurate)

---

## Setup

1. Open `Murmur.dmg` and launch the app
2. Grant **Accessibility** permission when prompted — needed for the global hotkey and auto-paste
3. Grant **Microphone** permission
4. Murmur is ready — hold **Right ⌥** to start dictating

---

## Settings

Click the **waveform icon** in your menu bar → **Show Window** to open settings.

### Engine tab
Choose between local Whisper (offline) or Groq (cloud). Select your model size and language.

### Output tab
Enable streaming mode or Claude fixup.

### Hotkey tab
Click **Change** and press any key to set a new hotkey. Modifier keys (⌥ ⌘ ⌃ ⇧) use hold-to-record behavior. Enable **Launch at Login** here.

### Appearance tab
Choose from preset themes or pick a custom accent color.

---

## Configuration file

For advanced settings, `config.json` lives next to `Murmur.app`. Changes take effect on the next recording — no restart needed, except for `model_size` and `use_groq`.

| Key | Default | Description |
|-----|---------|-------------|
| `model_size` | `"base"` | `tiny`, `base`, `small`, `medium`, `large-v3` |
| `language` | `""` | Force a language (`"en"`, `"de"`, `"nl"`) or leave empty for auto-detect |
| `vad_filter` | `true` | Skip silent segments |
| `beam_size` | `5` | Higher = more accurate but slower |
| `use_groq` | `false` | Use Groq cloud API instead of local Whisper |
| `groq_api_key` | `""` | Your [Groq API key](https://console.groq.com) |
| `streaming_mode` | `false` | Paste text as you pause mid-sentence |
| `use_claude_fixup` | `false` | Fix punctuation with Claude Haiku |
| `claude_api_key` | `""` | Your [Anthropic API key](https://console.anthropic.com) |

---

## Build from source

```bash
# One-time setup
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/pip install pyinstaller

# Build app + DMG
./build.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`).

---

## License

MIT
