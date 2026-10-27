#!/usr/bin/env python3
"""Hear how a word or sentence will sound, using the same voice and pronunciations.txt as audiobook.py.

    python say.py "the teacher of Enoch"
    python say.py "Kether" "Malkuth" "Tiphareth"       # several, one after another
    python say.py "Enoch" --raw                        # ignore pronunciations.txt, to compare
    python say.py "Enoch" --voice bm_george

Plays the result and saves it to voice_samples/say.wav. It also prints the phonemes, which you can
paste into pronunciations.txt as  Word = /phonemes/  to fine-tune a sound.

    python say.py --serve      # stay running: load the voice model once, then speak each JSON line
                               # read from stdin: {"text": "...", "voice": "af_alloy", "speed": 1.0, "book": "..."}

The Mac app uses --serve so Listen answers in about a second instead of reloading the model each time.
"""
import argparse
import json
import os
import subprocess
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

from audiobook import (PROJECT, SAMPLE_RATE, apply_pronunciations, fix_espeak_data_path, load_pronunciations,
                       stay_offline_if_downloaded)


def serve():
    """Load the model once, then speak each request from stdin. A new request interrupts the one
    still playing. Ends when stdin closes (the app quit)."""
    stay_offline_if_downloaded("hexgrad/Kokoro-82M",
                               ["config.json", "kokoro-v1_0.pth", "voices/af_alloy.pt", "voices/bm_george.pt"])
    import numpy as np
    import soundfile as sf

    fix_espeak_data_path()
    from kokoro import KPipeline

    pipes = {}

    def pipeline(voice):
        lang = voice[0]
        if lang not in pipes:
            pipes[lang] = KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M", device="cpu")
        return pipes[lang]

    for voice in ("af_alloy", "bm_george"):  # warm up American and British, so the first Listen is quick too
        for _ in pipeline(voice)("Ready.", voice=voice):
            pass
    out = PROJECT / "voice_samples" / "listen.wav"
    out.parent.mkdir(exist_ok=True)
    player = None
    print("READY", flush=True)
    for line in sys.stdin:
        try:
            req = json.loads(line)
            if player and player.poll() is None:
                player.terminate()
            voice = req.get("voice") or "af_alloy"
            spoken = apply_pronunciations(req["text"], load_pronunciations(book=req.get("book")))
            audio = [r.audio.numpy() for r in pipeline(voice)(spoken, voice=voice, speed=float(req.get("speed", 1.0)))]
            sf.write(out, np.concatenate(audio), SAMPLE_RATE)
            player = subprocess.Popen(["afplay", str(out)])
            print("OK", flush=True)
        except Exception as e:  # one bad request shouldn't stop the helper
            print(f"ERROR {type(e).__name__}: {e}", flush=True)
    if player and player.poll() is None:
        player.terminate()


def main():
    if "--serve" in sys.argv:
        return serve()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("text", nargs="+", help="word(s) or sentence(s) to speak")
    ap.add_argument("--voice", default="af_alloy")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--raw", action="store_true", help="ignore pronunciations.txt")
    ap.add_argument("--book", help="also apply pronunciations/<book>.txt (the PDF/EPUB file name without extension)")
    ap.add_argument("--no-play", action="store_true", help="only save the file")
    args = ap.parse_args()

    stay_offline_if_downloaded("hexgrad/Kokoro-82M", ["config.json", "kokoro-v1_0.pth", f"voices/{args.voice}.pt"])
    import numpy as np
    import soundfile as sf

    fix_espeak_data_path()
    from kokoro import KPipeline

    rules = [] if args.raw else load_pronunciations(book=args.book)
    pipe = KPipeline(lang_code=args.voice[0], repo_id="hexgrad/Kokoro-82M", device="cpu")
    gap = np.zeros(int(SAMPLE_RATE * 0.7), dtype=np.float32)
    pieces = []
    for t in args.text:
        spoken = apply_pronunciations(t, rules)
        for r in pipe(spoken, voice=args.voice, speed=args.speed):
            pieces.append(r.audio.numpy())
            print(f"{t!r:30s} -> /{r.phonemes}/" + (f"   (said as {spoken!r})" if spoken != t else ""))
        pieces.append(gap)

    out = PROJECT / "voice_samples" / "say.wav"
    out.parent.mkdir(exist_ok=True)
    sf.write(out, np.concatenate(pieces), SAMPLE_RATE)
    print(f"Saved {out}")
    if not args.no_play:
        subprocess.run(["afplay", str(out)])


if __name__ == "__main__":
    main()
