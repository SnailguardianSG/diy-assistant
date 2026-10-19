"""Turn a voice note or a recording into text, on the work server.

    bash transcribe.sh <audio file>

Whisper large-v3-turbo int8, downloaded once by the installer to
/opt/assistant/models (or $WHISPER_MODEL). Audio is decoded with PyAV, since
faster_whisper can't open files with PyAV 19. Language: English or Chinese as
detected; anything else is taken as English, because Singlish can be misheard
as Malay and written out in Malay.

A path as the bot stores it (/data/feedback/...) is mapped to ./data/feedback
here. Prints one header line, then timestamped segments.
"""
import os
import sys

import av
import numpy as np
from faster_whisper import WhisperModel

MODEL = os.environ.get("WHISPER_MODEL", "/opt/assistant/models/faster-whisper-large-v3-turbo")
ENGINE = "faster-whisper large-v3-turbo int8"


def samples(path: str) -> np.ndarray:
    c = av.open(path)
    r = av.AudioResampler(format="s16", layout="mono", rate=16000)
    out = [o.to_ndarray().reshape(-1) for f in c.decode(audio=0) for o in r.resample(f)]
    out += [o.to_ndarray().reshape(-1) for o in r.resample(None)]
    return np.concatenate(out).astype(np.float32) / 32768.0


def main() -> None:
    path = sys.argv[1]
    if path.startswith("/data/feedback/"):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", path[len("/data/"):])
    threads = int(sys.argv[sys.argv.index("--threads") + 1]) if "--threads" in sys.argv else 1
    audio = samples(path)
    m = WhisperModel(MODEL, device="cpu", compute_type="int8", cpu_threads=threads, num_workers=1)
    lang, prob, _ = m.detect_language(audio)
    use = lang if lang in ("en", "zh") else "en"
    print(f"seconds {len(audio) / 16000:.1f} | heard {lang} {prob:.2f} | written as {use} | {ENGINE}", flush=True)
    segs, _ = m.transcribe(audio, language=use, beam_size=5, vad_filter=True)
    for s in segs:
        print(f"[{int(s.start // 60):02d}:{int(s.start % 60):02d}] {s.text.strip()}", flush=True)


if __name__ == "__main__":
    main()
