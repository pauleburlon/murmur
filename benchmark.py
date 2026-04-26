#!/usr/bin/env python3
"""
Benchmark all Whisper models on a short recording.
Prints structured output for the app to parse.
"""
import json
import time

import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel

SAMPLE_RATE = 16000
DURATION    = 6
MODELS      = ["tiny", "base", "small", "medium", "large-v3"]


def record_audio(duration: int) -> np.ndarray:
    frames = []

    def callback(indata, _frame_count, _time_info, status):
        frames.append(indata.copy())

    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32", callback=callback):
        for i in range(duration, 0, -1):
            print(f"COUNTDOWN {i}", flush=True)
            time.sleep(1)

    return np.concatenate(frames).flatten().astype(np.float32)


def main():
    print("BENCHMARK_START", flush=True)

    audio = record_audio(DURATION)

    for model_name in MODELS:
        print(f"BENCHMARK_MODEL {model_name}", flush=True)

        model = WhisperModel(model_name, device="cpu", compute_type="int8")

        t0 = time.time()
        segments, _ = model.transcribe(audio, language=None, vad_filter=True, beam_size=5)
        text = " ".join(seg.text.strip() for seg in segments).strip()
        elapsed = time.time() - t0

        print(f"BENCHMARK_RESULT {json.dumps({'model': model_name, 'seconds': round(elapsed, 2), 'text': text})}", flush=True)

        del model

    print("BENCHMARK_DONE", flush=True)


if __name__ == "__main__":
    main()
