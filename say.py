#!/usr/bin/env python3
"""Hear how a word or sentence will sound, using the same voice and pronunciations.txt as audiobook.py.

    python say.py "the teacher of Enoch"
    python say.py "Kether" "Malkuth" "Tiphareth"       # several, one after another
    python say.py "Enoch" --raw                        # ignore pronunciations.txt, to compare
    python say.py "Enoch" --voice bm_george

Plays the result and saves it to voice_samples/say.wav. It also prints the phonemes, which you can
paste into pronunciations.txt as  Word = /phonemes/  to fine-tune a sound.
"""
import argparse
import os
import subprocess
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

from audiobook import PROJECT, SAMPLE_RATE, apply_pronunciations, load_pronunciations


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("text", nargs="+", help="word(s) or sentence(s) to speak")
    ap.add_argument("--voice", default="af_alloy")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--raw", action="store_true", help="ignore pronunciations.txt")
    ap.add_argument("--book", help="also apply pronunciations/<book>.txt (the PDF/EPUB file name without extension)")
    ap.add_argument("--no-play", action="store_true", help="only save the file")
    args = ap.parse_args()

    import numpy as np
    import soundfile as sf
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
