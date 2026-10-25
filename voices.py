#!/usr/bin/env python3
"""Render every English Kokoro voice reading the same test passage, so you can pick one.

    python voices.py                       # all 28 English voices
    python voices.py --text "Your own sentence."
    python voices.py --voices bm_george,bf_emma --speed 0.95

Writes voice_samples/<voice>.mp3, voice_samples/index.html (click to play each)
and voice_samples/all_voices.m4b (one chapter per voice; skip chapters to toggle voices).
"""
import argparse
import html
import os
import subprocess
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

VOICES = {
    "af": ("American", "female", "alloy aoede bella heart jessica kore nicole nova river sarah sky"),
    "am": ("American", "male", "adam echo eric fenrir liam michael onyx puck santa"),
    "bf": ("British", "female", "alice emma isabella lily"),
    "bm": ("British", "male", "daniel fable george lewis"),
}
DEFAULT_TEXT = (
    "These stories may be looked at from two standpoints. Are they fiction masquerading as fact, "
    "or fact masquerading as fiction? Recent studies suggest that memory consolidation during sleep "
    "depends on the coordination of hippocampal ripples and cortical spindles."
)
SR = 24000


def all_voices():
    return [f"{p}_{n}" for p, (_, _, names) in VOICES.items() for n in names.split()]


def describe(v):
    accent, gender, _ = VOICES[v[:2]]
    return f"{accent} {gender}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--text", default=DEFAULT_TEXT)
    ap.add_argument("--voices", help="comma-separated subset, e.g. bm_george,bf_emma")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "voice_samples")
    args = ap.parse_args()

    import numpy as np
    import soundfile as sf
    from kokoro import KPipeline

    voices = args.voices.split(",") if args.voices else all_voices()
    args.out.mkdir(exist_ok=True)
    pipes = {}
    gap = np.zeros(int(SR * 0.6), dtype=np.float32)
    wavs = []
    for i, v in enumerate(voices, 1):
        lang = v[0]
        pipes.setdefault(lang, KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M", device="cpu"))
        name = v.split("_", 1)[1].title()
        print(f"[{i}/{len(voices)}] {v}", flush=True)
        pieces = []
        for text in (f"This is {name}.", args.text):
            pieces += [r.audio.numpy() for r in pipes[lang](text, voice=v, speed=args.speed)]
            pieces.append(gap)
        wav = args.out / f"{v}.wav"
        sf.write(wav, np.concatenate(pieces), SR)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-b:a", "96k",
                        str(args.out / f"{v}.mp3")], check=True)
        wavs.append((v, wav))

    # One M4B with a chapter per voice: skip forward/back in any audiobook app to compare.
    (args.out / "concat.txt").write_text("".join(f"file '{w.name}'\n" for _, w in wavs))
    meta, t = [";FFMETADATA1", "title=Kokoro voice samples", "artist=Kokoro"], 0
    for v, w in wavs:
        d = int(sf.info(str(w)).duration * 1000)
        meta += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={t}", f"END={t + d}", f"title={v} ({describe(v)})"]
        t += d
    (args.out / "chapters.txt").write_text("\n".join(meta) + "\n")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0",
                    "-i", str(args.out / "concat.txt"), "-i", str(args.out / "chapters.txt"),
                    "-map_metadata", "1", "-map_chapters", "1", "-c:a", "aac", "-b:a", "64k",
                    "-ac", "1", "-f", "mp4", str(args.out / "all_voices.m4b")], check=True)
    for _, w in wavs:
        w.unlink()
    for f in ("concat.txt", "chapters.txt"):
        (args.out / f).unlink()

    rows = "\n".join(
        f'<tr><td><b>{v}</b></td><td>{describe(v)}</td>'
        f'<td><audio controls preload="none" src="{v}.mp3"></audio></td>'
        f'<td><code>--voice {v}</code></td></tr>'
        for v, _ in wavs
    )
    (args.out / "index.html").write_text(f"""<!doctype html><meta charset="utf-8">
<title>Kokoro voice samples</title>
<style>body{{font:15px -apple-system,sans-serif;max-width:900px;margin:24px auto;padding:0 16px}}
td{{padding:6px 10px;border-bottom:1px solid #ddd}} code{{background:#f3f3f3;padding:2px 6px}}</style>
<h2>Kokoro voice samples</h2><p>{html.escape(args.text)}</p>
<p>Tip: blend two voices with <code>--voice bm_george,bf_emma</code>.</p>
<table>{rows}</table>
<script>document.querySelectorAll('audio').forEach(a=>a.addEventListener('play',()=>
document.querySelectorAll('audio').forEach(o=>o!==a&&o.pause())))</script>
""")
    print(f"\nOpen {args.out / 'index.html'} or {args.out / 'all_voices.m4b'}")


if __name__ == "__main__":
    main()
