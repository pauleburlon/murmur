#!/usr/bin/env python3
"""
Murmur backend — receives START/STOP on stdin, records audio,
transcribes with Whisper (local or Groq), and prints the result to stdout.
Settings are read from config.json next to this script.
"""

import io
import json
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path

import numpy as np
import sounddevice as sd

# config.json sits next to the .app bundle when running inside a bundle,
# or next to this script when running directly from the project folder.
_here = Path(__file__).resolve().parent
if _here.parent.name == "Contents":
    CONFIG_PATH = _here.parents[2] / "config.json"
else:
    CONFIG_PATH = _here / "config.json"

DEFAULTS = {
    "model_size": "base",
    "language": "",
    "vad_filter": True,
    "beam_size": 5,
    "use_groq": False,
    "groq_api_key": "",
    "streaming_mode": False,
    "use_claude_fixup": False,
    "claude_api_key": "",
}


def _load_config() -> dict:
    try:
        return {**DEFAULTS, **json.loads(CONFIG_PATH.read_text())}
    except Exception as e:
        print(f"Warning: could not load config ({e}), using defaults.", file=sys.stderr, flush=True)
        return DEFAULTS.copy()


cfg = _load_config()
SAMPLE_RATE = 16000

# Streaming VAD constants
_FRAME_LEN = int(SAMPLE_RATE * 0.04)        # 40 ms energy frame
_SILENCE_THRESH = 0.015                     # RMS below this = silence
_PAUSE_FRAMES = 15                          # ~0.6 s of silence = sentence boundary
_MIN_SPEECH = int(SAMPLE_RATE * 0.3)        # ignore segments shorter than 300 ms

if cfg.get("use_groq"):
    model = None
    print("Groq mode active.", flush=True)
    print("Model ready.", flush=True)
else:
    from faster_whisper import WhisperModel
    print(f"Loading Whisper model '{cfg['model_size']}'...", flush=True)
    model = WhisperModel(cfg["model_size"], device="cpu", compute_type="int8")
    print("Model ready.", flush=True)

_recording = threading.Event()
_frames: list[np.ndarray] = []
_frames_lock = threading.Lock()
_transcription_lock = threading.Lock()
_audio_stream: sd.InputStream | None = None

# Streaming state
_stream_results: list[str] = []
_stream_offset: int = 0
_stream_lock = threading.Lock()


def _beep(sound: str) -> None:
    subprocess.Popen(
        ["afplay", f"/System/Library/Sounds/{sound}.aiff"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _audio_callback(indata: np.ndarray, _frame_count: int, _time_info, status) -> None:
    if status:
        print(f"Warning: audio callback status: {status}", file=sys.stderr, flush=True)
    if _recording.is_set():
        with _frames_lock:
            _frames.append(indata.copy())


def _transcribe_groq(audio: np.ndarray, c: dict) -> str:
    from groq import Groq
    client = Groq(api_key=c["groq_api_key"])

    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes((audio * 32767).astype(np.int16).tobytes())
    buf.seek(0)

    result = client.audio.transcriptions.create(
        file=("audio.wav", buf, "audio/wav"),
        model="whisper-large-v3",
        language=c.get("language") or None,
    )
    return result.text.strip()


def _claude_fixup(text: str, c: dict) -> str:
    if not c.get("use_claude_fixup") or not c.get("claude_api_key"):
        return text
    try:
        import anthropic
        client = anthropic.Anthropic(api_key=c["claude_api_key"])
        msg = client.messages.create(
            model="claude-haiku-4-5",
            max_tokens=1024,
            messages=[{
                "role": "user",
                "content": (
                    "Fix any transcription errors, punctuation, and capitalization in the following text. "
                    "Return only the corrected text with no explanation or extra commentary.\n\n"
                    f"{text}"
                ),
            }],
        )
        return msg.content[0].text.strip()
    except Exception as e:
        print(f"Claude fixup error: {e}", file=sys.stderr, flush=True)
        return text


def _do_transcribe(audio: np.ndarray, c: dict) -> str:
    if c.get("use_groq"):
        if not c.get("groq_api_key"):
            return ""
        return _transcribe_groq(audio, c)
    segments, _ = model.transcribe(
        audio,
        beam_size=c["beam_size"],
        language=c["language"] or None,
        vad_filter=c["vad_filter"],
    )
    return " ".join(seg.text.strip() for seg in segments).strip()


def _find_last_pause(audio: np.ndarray) -> tuple[int, int] | None:
    n = len(audio) // _FRAME_LEN
    if n == 0:
        return None
    frames   = audio[:n * _FRAME_LEN].reshape(n, _FRAME_LEN)
    energies = np.sqrt(np.mean(frames ** 2, axis=1))
    silent   = energies < _SILENCE_THRESH

    # Find silence-run boundaries without a Python loop
    padded  = np.concatenate(([False], silent, [False]))
    changes = np.diff(padded.view(np.uint8))
    starts  = np.where(changes == 1)[0]   # frame index where silence begins
    ends    = np.where(changes == 255)[0] # frame index where silence ends (uint8 wrap of -1)

    if len(starts) == 0:
        return None

    valid = (ends - starts >= _PAUSE_FRAMES) & (starts * _FRAME_LEN >= _MIN_SPEECH)
    if not valid.any():
        return None

    last = np.where(valid)[0][-1]
    return (int(starts[last]) * _FRAME_LEN, int(ends[last]) * _FRAME_LEN)


def _streaming_loop(c: dict) -> None:
    global _stream_offset
    with _stream_lock:
        _stream_results.clear()
        _stream_offset = 0

    # Build audio incrementally — avoids re-concatenating all frames every tick
    audio_buffer:   np.ndarray = np.empty(0, dtype=np.float32)
    last_frame_cnt: int        = 0
    local_offset:   int        = 0  # mirrors _stream_offset, local for clarity

    while _recording.is_set():
        time.sleep(0.1)

        with _frames_lock:
            new_frames     = _frames[last_frame_cnt:]
            last_frame_cnt = len(_frames)

        if new_frames:
            audio_buffer = np.concatenate(
                [audio_buffer] + [f.flatten().astype(np.float32) for f in new_frames]
            )

        chunk = audio_buffer[local_offset:]
        pause = _find_last_pause(chunk)
        if pause is None:
            continue

        pause_start, pause_end = pause
        segment = chunk[:pause_start]

        with _transcription_lock:
            text = _do_transcribe(segment, c)

        with _stream_lock:
            if text:
                _stream_results.append(text)
                print(f"◐ {' '.join(_stream_results)}", flush=True)
            local_offset   += pause_end
            _stream_offset  = local_offset


def _transcribe_and_inject() -> None:
    with _frames_lock:
        frames = list(_frames)

    if not frames:
        print("No audio captured.", flush=True)
        return

    all_audio = np.concatenate(frames, axis=0).flatten().astype(np.float32)
    c = _load_config()

    with _transcription_lock:
        with _stream_lock:
            has_streaming = c.get("streaming_mode") and bool(_stream_results)
            stream_snapshot = list(_stream_results)
            offset_snapshot = _stream_offset
        if has_streaming:
            remaining = all_audio[offset_snapshot:]
            if len(remaining) >= _MIN_SPEECH:
                tail = _do_transcribe(remaining, c)
                if tail:
                    stream_snapshot.append(tail)
            final_text = " ".join(stream_snapshot).strip()
        else:
            duration = len(all_audio) / SAMPLE_RATE
            print(f"Transcribing {duration:.1f}s of audio...", flush=True)
            if c.get("use_groq") and not c.get("groq_api_key"):
                print("ERROR: Groq API key not set.", flush=True)
                _beep("Basso")
                return
            final_text = _do_transcribe(all_audio, c)

    if not final_text:
        print("(no speech detected)", flush=True)
        _beep("Basso")
        return

    if c.get("use_claude_fixup") and c.get("claude_api_key"):
        print("Fixing with Claude…", flush=True)
        final_text = _claude_fixup(final_text, c)

    print(f"→ {final_text}", flush=True)


def _start() -> None:
    global _audio_stream
    if not _recording.is_set():
        with _frames_lock:
            _frames.clear()
        _recording.set()
        _audio_stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=1,
            dtype="float32",
            callback=_audio_callback,
            blocksize=1024,
        )
        _audio_stream.start()
        _beep("Tink")
        print("● Recording…", flush=True)

        c = _load_config()
        if c.get("streaming_mode"):
            threading.Thread(target=_streaming_loop, args=(c,), daemon=True).start()


def _stop() -> None:
    global _audio_stream
    if _recording.is_set():
        _recording.clear()
        if _audio_stream is not None:
            _audio_stream.stop()
            _audio_stream.close()
            _audio_stream = None
        _beep("Pop")
        print("■ Stopped.", flush=True)
        threading.Thread(target=_transcribe_and_inject, daemon=True).start()


def main() -> None:
    print("Murmur ready.", flush=True)

    try:
        for line in sys.stdin:
            cmd = line.strip()
            if cmd == "START":
                _start()
            elif cmd == "STOP":
                _stop()
    except KeyboardInterrupt:
        print("\nBye.")
        sys.exit(0)


if __name__ == "__main__":
    main()
