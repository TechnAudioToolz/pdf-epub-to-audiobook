#!/usr/bin/env python3
"""Turn an existing MP3 (or any audio) audiobook into a chaptered M4B, fully offline.

Step 1 - find chapters (pauses + local Whisper listening for "Chapter N ..."):
    python audio2m4b.py detect book.mp3 [--toc book.pdf]
  writes work/<book>/chapters.tsv: one "HH:MM:SS.mmm<TAB>Title" per line. Edit it if needed.
  --toc takes chapter titles from a PDF/EPUB's bookmarks, so names are spelled correctly.

Step 2 - build:
    python audio2m4b.py build book.mp3 [--cover cover.jpg] [--title ..] [--author ..] [--narrator ..]
  writes output/<Author> - <Title>.m4b with chapter markers and cover art.

A folder of MP3s (one per chapter or part) instead:
    python audio2m4b.py join "My Audiobook/" [--check] [--cover cover.jpg] [--title ..] [--author ..]
  joins the files in name order into one M4B, one chapter per file, named from the files' tags or names.
  The cover is --cover, else a picture inside the MP3s, else cover.jpg/folder.jpg in the folder, else generated.
"""
import argparse
import re
import subprocess
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

PROJECT = Path(__file__).resolve().parent  # all output stays inside the project folder
HEADING = re.compile(
    r"^\W*(?:part\s+\w+[.,]?\s+)?(chapter\s+\w+|part\s+\w+|foreword|preface|introduction|prologue|"
    r"epilogue|afterword|appendix|editorial|acknowledg|author'?s note|this concludes)",
    re.I,
)
NUMBER_WORDS = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen "
    "sixteen seventeen eighteen nineteen twenty".split())}


def ffprobe_tags(src):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration:format_tags",
                          "-of", "default=nw=1", str(src)], capture_output=True, text=True).stdout
    tags = dict(re.findall(r"^TAG:(\w+)=(.*)$", out, re.M))
    tags["duration"] = float(re.search(r"duration=([\d.]+)", out).group(1))
    return {k.lower(): v for k, v in tags.items()}


def fmt(t):
    h, rem = divmod(t, 3600)
    m, s = divmod(rem, 60)
    return f"{int(h):02d}:{int(m):02d}:{s:06.3f}"


def parse_time(s):
    parts = [float(p) for p in s.split(":")]
    return sum(p * 60 ** i for i, p in enumerate(reversed(parts)))


SKIP_TOC = re.compile(r"^(cover|copyright|contents|table of contents|index|diagram.*|back ?cover|part\s+\w+|"
                      r"about the (author|publisher)|title page|dedication)$", re.I)
STOP = set("the of and a an in on to upon with by for".split())
ROMAN = {"i": 1, "v": 5, "x": 10, "l": 50, "c": 100}


def toc_entries(path):
    """Spoken sections from a PDF/EPUB's bookmarks, in book order (skips cover, index, diagrams...)."""
    if path.suffix.lower() == ".pdf":
        from audiobook import import_pymupdf
        pymupdf = import_pymupdf()
        raw = [t for _, t, _ in pymupdf.open(str(path)).get_toc()]
    else:
        from ebooklib import epub
        raw = []

        def walk(items):
            for e in items:
                if isinstance(e, tuple):
                    raw.append(e[0].title)
                    walk(e[1])
                else:
                    raw.append(e.title)

        walk(epub.read_epub(str(path)).toc)
    out = []
    for t in raw:
        t = t.strip()
        if not t or SKIP_TOC.match(t):
            continue
        m = re.match(r"^\s*(?:chapter\s+)?(\d+)[.:)]?\s+(.*)$", t, re.I)
        out.append((int(m.group(1)) if m else None, t))
    return out


def roman(s):
    s = s.lower()
    if not s or any(ch not in ROMAN for ch in s):
        return None
    total = 0
    for a, b in zip(s, s[1:] + " "):
        v = ROMAN[a]
        total += -v if b in ROMAN and ROMAN[b] > v else v
    return total


def chapter_number(text):
    m = re.search(r"chapter\s+([a-z0-9]+)", text, re.I)
    if not m:
        return None
    w = m.group(1).lower()
    return int(w) if w.isdigit() else NUMBER_WORDS.get(w) or roman(w)


def words(t):
    return re.findall(r"[a-z]+", t.lower())


def title_similarity(title, heard):
    """How well the opening words heard after a pause match a TOC title, tolerant of Whisper's
    spelling of unusual names ("Kether" heard as "chatter")."""
    from difflib import SequenceMatcher
    want = [w for w in words(re.sub(r"^\s*\d+[.:)]?\s*", "", title)) if w not in STOP]
    got = [w for w in words(heard)[:18] if w not in STOP and w not in ("chapter", "part")]
    if not want or not got:
        return 0.0
    return sum(max(SequenceMatcher(None, w, g).ratio() for g in got) for w in want) / len(want)


def align(toc, cands):
    """Monotonic alignment of TOC entries to candidate pauses (both in order), maximising match
    score. A match needs a plausible title or chapter-number hit; long pauses get a bonus."""
    def score(entry, cand):
        n, title = entry
        sim = title_similarity(title, cand["text"])
        num = n is not None and chapter_number(cand["text"]) == n
        if sim < 0.6 and not num:
            return None
        return sim + (1.0 if num else 0) + (0.3 if cand["gap"] >= 2.6 else 0)

    T, C = len(toc), len(cands)
    best = [[0.0] * (C + 1) for _ in range(T + 1)]
    move = [[None] * (C + 1) for _ in range(T + 1)]
    for i in range(T - 1, -1, -1):
        for j in range(C - 1, -1, -1):
            options = [(best[i + 1][j], "skip_toc"), (best[i][j + 1], "skip_cand")]
            sc = score(toc[i], cands[j])
            if sc is not None:
                options.append((sc + best[i + 1][j + 1], "match"))
            best[i][j], move[i][j] = max(options)
    i = j = 0
    pairs = []
    while i < T and j < C:
        m = move[i][j]
        if m == "match":
            pairs.append((toc[i], cands[j]))
            i, j = i + 1, j + 1
        elif m == "skip_toc":
            i += 1
        else:
            j += 1
    return pairs, [e for e in toc if e not in [p[0] for p in pairs]]


def heading_title(text):
    t = re.split(r"(?<=[a-z])[.!?]\s|\s\d+[.]?\s", text, maxsplit=1)[0]
    return t[:80].strip(" .")


def detect(args):
    import json
    import numpy as np

    src = args.input
    work = PROJECT / "work" / src.stem
    work.mkdir(parents=True, exist_ok=True)
    cache = work / "pauses.json"
    if cache.exists() and not args.rescan:
        cands = json.loads(cache.read_text())
        print(f"Using cached pause transcripts from {cache} (--rescan to redo)")
    else:
        from audiobook import quiet_onnxruntime, stay_offline_if_downloaded

        stay_offline_if_downloaded(f"Systran/faster-whisper-{args.model}", ["model.bin"])
        quiet_onnxruntime()
        from faster_whisper import WhisperModel

        print("Scanning for pauses (a few minutes for a long book)...", flush=True)
        log = subprocess.run(["ffmpeg", "-nostats", "-hide_banner", "-i", str(src), "-map", "0:a",
                              "-af", f"silencedetect=noise={args.noise}dB:d={args.min_gap}", "-f", "null", "-"],
                             capture_output=True, text=True).stderr
        gaps = [(float(e), float(d)) for e, d in re.findall(r"silence_end: ([\d.]+) \| silence_duration: ([\d.]+)", log)]
        print(f"{len(gaps)} pauses >= {args.min_gap}s; listening to each with Whisper...", flush=True)
        model = WhisperModel(args.model, device="cpu", compute_type="int8")
        cands = []
        for t, d in [(0.0, 0.0)] + gaps:
            pcm = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-t", "12", "-i", str(src),
                                  "-ac", "1", "-ar", "16000", "-f", "s16le", "-"], capture_output=True).stdout
            segs, _ = model.transcribe(np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768,
                                       language="en", beam_size=1)
            cands.append({"t": t, "gap": d, "text": " ".join(s.text.strip() for s in segs).strip()})
            print(f"  {fmt(t)}  {cands[-1]['text'][:90]}", flush=True)
        cache.write_text(json.dumps(cands, indent=1))

    found = [(0.0, "Opening Credits")]
    body = cands[1:]
    if args.toc:
        pairs, missing = align(toc_entries(args.toc), body)
        for (n, title), c in pairs:
            part = re.match(r"^\W*part\s+(\w+)", c["text"], re.I)
            found.append((c["t"], f"Part {part.group(1).title()}: {title}" if part else title))
        if missing:
            print("Not found in the audio (check chapters.tsv):", ", ".join(t for _, t in missing))
    else:
        seen = set()
        for c in body:
            if not HEADING.match(c["text"]):
                continue
            n = chapter_number(c["text"])
            key = n if n is not None else c["text"][:20].lower()
            if key not in seen:
                seen.add(key)
                found.append((c["t"], heading_title(c["text"])))
    for c in body:
        if re.match(r"^\W*this concludes", c["text"], re.I):
            found.append((c["t"], "End Credits"))
            break
    found.sort()
    for t, title in found:
        print(f"  {fmt(t)}  {title}")

    tsv = work / "chapters.tsv"
    tsv.write_text("".join(f"{fmt(t)}\t{title}\n" for t, title in found))
    print(f"\n{len(found)} chapters -> {tsv}")
    print("Edit the .tsv if anything is off, then run: python audio2m4b.py build", src)


def build(args):
    src = args.input
    work = PROJECT / "work" / src.stem
    tsv = args.chapters or work / "chapters.tsv"
    if not tsv.exists():
        sys.exit(f"No chapter list at {tsv}. Run 'detect' first (or pass --chapters).")
    tags = ffprobe_tags(src)
    chapters = []
    for line in tsv.read_text().splitlines():
        if line.strip():
            t, _, title = line.partition("\t")
            chapters.append((parse_time(t), title.strip()))
    chapters.sort()
    title = args.title or tags.get("album") or tags.get("title") or src.stem
    author = args.author or tags.get("artist") or ""

    esc = lambda s: re.sub(r"([=;#\\\n])", r"\\\1", s)
    meta = [";FFMETADATA1", f"title={esc(title)}", f"album={esc(title)}", f"artist={esc(author)}",
            f"album_artist={esc(author)}", "genre=Audiobook"]
    if args.narrator:
        meta.append(f"composer={esc(args.narrator)}")  # where Apple Books and most players show the narrator
    ends = [t for t, _ in chapters[1:]] + [tags["duration"]]
    for (start, name), end in zip(chapters, ends):
        meta += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={int(start * 1000)}", f"END={int(end * 1000)}",
                 f"title={esc(name)}"]
    (work / "ffmetadata.txt").write_text("\n".join(meta) + "\n")

    name = f"{author} - {title}" if author else title
    out = args.output or PROJECT / "output" / (re.sub(r'[/:\\*?"<>|]+', "", name).strip() + ".m4b")
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["ffmpeg", "-y", "-v", "error", "-stats", "-i", str(src.resolve()), "-i", "ffmetadata.txt"]
    if args.cover:
        cmd += ["-i", str(args.cover.resolve()), "-map", "0:a", "-map", "2:v",
                "-c:v", "mjpeg", "-disposition:v", "attached_pic"]
    else:
        cmd += ["-map", "0:a"]
    cmd += ["-map_metadata", "1", "-map_chapters", "1", "-c:a", "aac", "-b:a", args.bitrate,
            "-movflags", "+faststart", "-f", "mp4", str(out.resolve())]
    print(f"Encoding {tags['duration'] / 3600:.1f} h of audio with {len(chapters)} chapters...", flush=True)
    # Run inside the work dir with relative names: ffmpeg misparses absolute paths containing "#"
    # in some inputs, and the metadata file is referenced relatively.
    subprocess.run(cmd, check=True, cwd=work)
    print(f"\nWrote {out}  ({out.stat().st_size / 1e6:.0f} MB)")


AUDIO_TYPES = (".mp3", ".m4a", ".m4b", ".aac", ".ogg", ".opus", ".flac", ".wav", ".wma")
FOLDER_COVERS = ("cover", "folder", "_folder", "front", "albumart")


def natural_key(path):
    """'Part 2' before 'Part 10'."""
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", str(path))]


def audio_files(inputs):
    """Audio files from files and folders (folders searched all the way down, e.g. Disc 1/, Disc 2/), in name order."""
    found = []
    for p in inputs:
        if p.is_dir():
            found += sorted((f for f in p.rglob("*") if f.suffix.lower() in AUDIO_TYPES and not f.name.startswith(".")),
                            key=lambda f: natural_key(f.relative_to(p)))
        elif p.suffix.lower() in AUDIO_TYPES:
            found.append(p)
    return found


def probe(src):
    """Duration, tags and whether there's a cover picture, from ffmpeg's own report (no ffprobe needed)."""
    from audiobook import ffmpeg_exe

    err = subprocess.run([ffmpeg_exe(), "-hide_banner", "-i", src.name], capture_output=True, text=True,
                         cwd=src.parent).stderr
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", err)
    info = {"duration": int(m[1]) * 3600 + int(m[2]) * 60 + float(m[3]) if m else 0.0,
            "picture": bool(re.search(r"Stream #\S+.*Video:", err))}
    head = err.split("Stream #", 1)[0]  # the file's own tags come before its streams
    for key, value in re.findall(r"^\s{4}(\w+)\s*: (.*)$", head, re.M):
        info.setdefault(key.lower(), value.strip())
    return info


def chapter_names(files, infos):
    """Each file's title tag if they're all different, else its file name without the leading track number."""
    titles = [i.get("title", "").strip() for i in infos]
    if all(titles) and len(set(titles)) == len(titles):
        return titles
    names = []
    for n, f in enumerate(files, 1):
        name = re.sub(r"^[\s\d._-]*(track|part|chapter)?[\s\d._-]+(?=\D)", "", f.stem, flags=re.I).strip(" -_.")
        names.append(name.replace("_", " ") or f"Part {n}")
    return names


def join_plan(args):
    """What join will make: files, chapter names, title, author and cover."""
    from audiobook import generated_cover, title_and_author

    files = audio_files(args.inputs)
    if not files:
        sys.exit("No audio files found (MP3, M4A, AAC, OGG, FLAC, WAV).")
    infos = [probe(f) for f in files]
    for i in infos:  # one book split over discs: "Title (Disc 6)", "Title CD 2" -> "Title"
        if i.get("album"):
            i["album"] = re.sub(r"[\s,:_-]*[(\[]?\b(disc|disk|cd|part)\s*\d+\s*(of\s*\d+)?[)\]]?\s*$", "", i["album"], flags=re.I).strip()
    common = lambda key: max(({i.get(key) for i in infos} - {None, ""}), key=lambda v: sum(i.get(key) == v for i in infos), default="")
    folder = args.inputs[0] if args.inputs[0].is_dir() else files[0].parent
    title, author = title_and_author(common("album"), common("album_artist") or common("artist"), Path(folder.name))
    plan = dict(files=files, infos=infos, names=chapter_names(files, infos),
                title=args.title or title, author=args.author or author)
    # named after the source (not the title), so editing the title keeps the converted files
    work = PROJECT / "work" / ("mp3-" + re.sub(r'[/:\\*?"<>|#]+', "", folder.name if args.inputs[0].is_dir() else files[0].stem).strip())
    work.mkdir(parents=True, exist_ok=True)
    plan["work"] = work
    cover = work / "cover.jpg"
    if args.cover:
        cover.write_bytes(args.cover.read_bytes())
        note = f"your image, {args.cover.name}"
    elif any(i["picture"] for i in infos):
        f = next(f for f, i in zip(files, infos) if i["picture"])
        from audiobook import ffmpeg_exe

        subprocess.run([ffmpeg_exe(), "-y", "-v", "error", "-i", str(f.resolve()), "-map", "0:v:0", "-frames:v", "1",
                        str(cover)], check=True)
        note = f"the picture inside {f.name}"
    else:
        pictures = sorted((p for p in folder.rglob("*") if p.suffix.lower() in (".jpg", ".jpeg", ".png")
                           and p.stem.lower() in FOLDER_COVERS), key=lambda p: (len(p.parts), natural_key(p)))
        found = pictures[0] if pictures else None  # also inside Disc 1/, Disc 2/...
        if found:
            cover.write_bytes(found.read_bytes())
            note = f"found {found.name}"
        else:
            cover.write_bytes(generated_cover(plan["title"], plan["author"]))
            note = "generated from the title"
    plan["cover"], plan["cover_note"] = cover, note
    return plan


def join(args):
    """A folder of MP3s (or other audio) -> one M4B, one chapter per file."""
    import time

    from audiobook import GITHUB, ffmpeg_exe

    plan = join_plan(args)
    files, infos, names, work = plan["files"], plan["infos"], plan["names"], plan["work"]
    total = sum(i["duration"] for i in infos)
    print(f"{plan['title']} — {plan['author'] or 'unknown author'}")
    print(f"{len(files)} files, {total / 3600:.1f} h of audio")
    for n, (name, info) in enumerate(zip(names, infos), 1):
        print(f"  {n:3d}. {name}\t{fmt(info['duration'])[:8]}")
    print(f"Cover: {plan['cover_note']}")
    print(f"Cover image: {plan['cover']}")
    if args.check:
        return

    # Encode each file to AAC once (cached, so a stopped job resumes), then join without re-encoding.
    parts, start, done = [], time.time(), 0.0
    for n, (f, info) in enumerate(zip(files, infos), 1):
        stat = f.stat()
        part = work / f"part-{n:04d}-{stat.st_size}-{int(stat.st_mtime)}.m4a"
        if part.exists():
            print(f"[{n}/{len(files)}] {names[n - 1]}: cached")
        else:
            print(f"[{n}/{len(files)}] {names[n - 1]}", flush=True)
            tmp = part.with_suffix(".tmp.m4a")
            subprocess.run([ffmpeg_exe(), "-y", "-v", "error", "-i", str(f.resolve()), "-vn", "-ac", "1", "-ar", "44100",
                            "-c:a", "aac", "-b:a", args.bitrate, str(tmp)], check=True)
            tmp.rename(part)
            done += info["duration"]
            el = time.time() - start
            left = el / done * sum(i["duration"] for i in infos[n:])  # seconds of encoding still to do
            print(f"    done; elapsed {el / 60:.1f} min, ~{left / 60:.0f} min left", flush=True)
        parts.append(part)

    esc = lambda s: re.sub(r"([=;#\\\n])", r"\\\1", s)
    meta = [";FFMETADATA1", f"title={esc(plan['title'])}", f"album={esc(plan['title'])}",
            f"artist={esc(plan['author'])}", f"album_artist={esc(plan['author'])}", "genre=Audiobook",
            f"comment={esc('Joined from ' + str(len(files)) + ' audio files with Audiobook Maker (free and open source): ' + GITHUB)}"]
    if args.narrator:
        meta.append(f"composer={esc(args.narrator)}")
    t = 0
    for part, name in zip(parts, names):
        d = int(probe(part)["duration"] * 1000)
        meta += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={t}", f"END={t + d}", f"title={esc(name)}"]
        t += d
    (work / "ffmetadata.txt").write_text("\n".join(meta) + "\n")
    (work / "concat.txt").write_text("".join(f"file '{p.name}'\n" for p in parts))

    name = re.sub(r'[/:\\*?"<>|]+', "", f"{plan['author']} - {plan['title']}" if plan["author"] else plan["title"]).strip()
    out = (args.output or (args.output_dir or PROJECT / "output") / f"{name}.m4b").resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    print(f"Joining {len(parts)} chapters into one M4B...", flush=True)
    # Inside the work dir with relative names: ffmpeg misparses some absolute paths containing "#".
    subprocess.run([ffmpeg_exe(), "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", "concat.txt",
                    "-i", "ffmetadata.txt", "-i", "cover.jpg", "-map", "0:a", "-map", "2:v", "-c:a", "copy",
                    "-c:v", "mjpeg", "-disposition:v", "attached_pic", "-map_metadata", "1", "-map_chapters", "1",
                    "-movflags", "+faststart", "-f", "mp4", str(out)], check=True, cwd=work)
    print(f"\nWrote {out}  ({t / 3_600_000:.1f} h, {len(parts)} chapters, {out.stat().st_size / 1e6:.0f} MB)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("detect", help="find chapter starts and write chapters.tsv")
    d.add_argument("input", type=Path)
    d.add_argument("--toc", type=Path, help="PDF/EPUB whose bookmarks give the chapter titles")
    d.add_argument("--min-gap", type=float, default=2.0, help="shortest pause (s) that can start a chapter")
    d.add_argument("--noise", type=int, default=-40, help="silence threshold in dB")
    d.add_argument("--model", default="base.en", help="Whisper model: tiny.en, base.en, small.en")
    d.add_argument("--rescan", action="store_true", help="ignore cached pause transcripts")
    b = sub.add_parser("build", help="encode the M4B from chapters.tsv")
    b.add_argument("input", type=Path)
    b.add_argument("--chapters", type=Path, help="chapter list (default: work/<book>/chapters.tsv)")
    b.add_argument("--cover", type=Path)
    b.add_argument("--title")
    b.add_argument("--author")
    b.add_argument("--narrator")
    b.add_argument("--bitrate", default="64k")
    b.add_argument("-o", "--output", type=Path)
    j = sub.add_parser("join", help="join a folder of MP3s into one M4B, one chapter per file")
    j.add_argument("inputs", nargs="+", type=Path, help="audio files and/or folders of them")
    j.add_argument("--check", action="store_true", help="list the chapters, title and cover, then stop")
    j.add_argument("--cover", type=Path)
    j.add_argument("--title")
    j.add_argument("--author")
    j.add_argument("--narrator")
    j.add_argument("--bitrate", default="64k")
    j.add_argument("--output-dir", type=Path, help="folder for the M4B (default: output/ in the project)")
    j.add_argument("-o", "--output", type=Path)
    args = ap.parse_args()
    {"detect": detect, "build": build, "join": join}[args.cmd](args)


if __name__ == "__main__":
    main()
