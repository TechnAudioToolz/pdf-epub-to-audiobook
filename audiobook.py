#!/usr/bin/env python3
"""Turn a PDF or EPUB into a chaptered M4B audiobook using Kokoro TTS, fully offline.

    python audiobook.py book.pdf                      # -> book.m4b
    python audiobook.py book.epub --voice bm_george   # British male narrator
    python audiobook.py paper.pdf --dry-run           # inspect chapters + cleaned text, no audio

Synthesis is resumable: finished chapters are cached in <book>.work/ and skipped on rerun.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import warnings
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

warnings.filterwarnings("ignore")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

SAMPLE_RATE = 24000
PROJECT = Path(__file__).resolve().parent  # all output stays inside the project folder

# Sections that are noise when listening to non-fiction / academic material.
SKIP_SECTIONS = re.compile(
    r"^\s*(references|bibliography|works cited|literature cited|index|notes|endnotes|"
    r"table of contents|contents|list of (figures|tables|abbreviations)|copyright|"
    r"acknowledg(e)?ments|appendix [a-z0-9]+|appendices|about the (author|publisher)|about .*publications?|"
    r"also by .*|further reading|title page|cover( page)?|colophon|half title)\s*$",
    re.I,
)


@dataclass
class Chapter:
    title: str
    paragraphs: list = field(default_factory=list)

    @property
    def text(self):
        return "\n\n".join(self.paragraphs)


@dataclass
class Book:
    title: str
    author: str
    chapters: list
    cover: bytes | None = None


# --------------------------------------------------------------------------- text cleanup

ABBREVIATIONS = [
    (r"\be\.g\.?,?(?=\s)", "for example,"),
    (r"\bi\.e\.?,?(?=\s)", "that is,"),
    (r"\bet al\.", "and colleagues"),
    (r"\betc\.", "et cetera."),
    (r"\bcf\.", "compare"),
    (r"\bvs\.", "versus"),
    (r"\bviz\.", "namely"),
    (r"\bFigs?\.\s*", "Figure "),
    (r"\bEqs?\.\s*", "Equation "),
    (r"\bSec\.\s*", "Section "),
    (r"\bCh\.\s*", "Chapter "),
    (r"\bpp?\.\s*(?=\d)", "page "),
    (r"\bapprox\.", "approximately"),
    (r"\bNo\.\s*(?=\d)", "number "),
]


def clean_paragraph(t: str, academic: bool) -> str:
    t = unicodedata.normalize("NFKC", t)  # also expands ligatures like ﬁ ﬂ
    t = t.replace("­", "")  # soft hyphen
    t = re.sub(r"(\w)-\s*\n\s*(\w)", r"\1\2", t)  # de-hyphenate line breaks
    t = re.sub(r"\s*\n\s*", " ", t)
    t = t.replace("`", "‘")  # OCR-era backtick quotes
    t = re.sub(r"https?://\S+|www\.\S+", "", t)
    t = re.sub(r"\S+@\S+\.\w+", "", t)  # emails
    # Footnote markers glued to punctuation or words: 'fact.4', 'Italia.“4', 'word¹'
    t = re.sub(r"([.,;:!?“”’\"')\]])\d{1,3}(?=\s|$)", r"\1", t)
    t = re.sub(r"[¹²³⁰-₟]+", "", t)
    if academic:
        t = re.sub(r"\s*\[(\d+([,–\-]\s*\d+)*)\]", "", t)  # [3], [1, 4-6]
        # (Smith, 2020), (Smith & Lee, 2019; Doe et al., 2021a), (see Smith 2020, p. 4)
        t = re.sub(
            r"\s*\((?:see |e\.g\.,? |cf\. )?[A-Z][^()]{0,120}?\b(1[89]|20)\d{2}[a-z]?(,? ?pp?\. ?\d+(–|-)?\d*)?"
            r"(;[^()]{0,120}?\b(1[89]|20)\d{2}[a-z]?)*\)",
            "",
            t,
        )
        for pat, rep in ABBREVIATIONS:
            t = re.sub(pat, rep, t)
    t = re.sub(r"\s+([.,;:!?])", r"\1", t)
    t = re.sub(r"\s{2,}", " ", t)
    return t.strip()


def is_noise_line(t: str) -> bool:
    s = t.strip()
    if not s:
        return True
    if re.fullmatch(r"[\divxlcdmIVXLCDM]{1,6}", s):  # page numbers, bare roman numerals
        return True
    if re.fullmatch(r"[\W_]+", s):  # ****, ----, scene-break glyphs
        return True
    return False


def is_scene_break(t: str) -> bool:
    s = t.strip()
    return bool(s) and bool(re.fullmatch(r"[\W_]{3,}", s))


# --------------------------------------------------------------------------- EPUB

def load_epub(path: Path, academic: bool) -> Book:
    import ebooklib
    from bs4 import BeautifulSoup
    from ebooklib import epub

    book = epub.read_epub(str(path), options={"ignore_ncx": False})
    meta = lambda k: (book.get_metadata("DC", k) or [("", {})])[0][0]
    title, author = meta("title"), meta("creator")

    cover = None
    for item in book.get_items():
        if item.get_type() == ebooklib.ITEM_COVER or (
            item.get_type() == ebooklib.ITEM_IMAGE and "cover" in item.get_name().lower()
        ):
            cover = item.get_content()
            break

    # Flatten the spine into a stream of (kind, text) where kind is 'h', 'p' or 'break'.
    stream = []
    for idref, _ in book.spine:
        item = book.get_item_with_id(idref)
        if item is None or item.get_type() != ebooklib.ITEM_DOCUMENT:
            continue
        soup = BeautifulSoup(item.get_content(), "html.parser")
        for tag in soup(["script", "style", "sup", "nav"]):
            tag.decompose()
        stream.append(("doc", ""))
        for el in soup.find_all(["h1", "h2", "h3", "p", "div", "li", "blockquote", "hr"]):
            if el.name == "hr":
                stream.append(("break", ""))
                continue
            if el.name in ("div", "li", "blockquote") and el.find(["p", "div", "h1", "h2", "h3"]):
                continue  # container; its children are visited separately
            txt = el.get_text(" ", strip=True)
            if not txt:
                continue
            if el.name in ("h1", "h2", "h3"):
                stream.append(("h", txt))
            elif is_scene_break(txt):
                stream.append(("break", txt))
            else:
                stream.append(("p", txt))

    chapters = split_stream(stream, toc_titles=epub_toc_titles(book, stream))
    return Book(title or path.stem, author, finalize(chapters, academic), cover)


def epub_toc_titles(book, stream):
    """Chapter titles from the EPUB's nav, or else from a printed 'Table of Contents' page."""
    titles = []

    def walk(entries):
        for e in entries:
            if isinstance(e, tuple):
                titles.append(e[0].title)
                walk(e[1])
            else:
                titles.append(e.title)

    walk(book.toc)
    if len(titles) >= 3:
        return titles
    # Fall back to a printed contents page: "I Blood Lust 1 II The Return of the Ritual 22 ..."
    for i, (kind, txt) in enumerate(stream):
        if re.fullmatch(r"(table of )?contents", txt.strip(), re.I):
            body = " ".join(t for k, t in stream[i + 1 : i + 80] if k in ("p", "h"))
            parts = re.split(r"\s+(?:[ivxlcdm]+|\d+)\s+(?=[A-Z])", " " + body, flags=re.I)
            found = [re.sub(r"^\s*(?:[IVXLCDM]+\s+)?", "", p).strip() for p in parts]
            found = [re.sub(r"\s+[\divxlcdm]+$", "", f, flags=re.I) for f in found if 2 < len(f) < 80]
            if len(found) >= 3:
                return found
    return []


STANDARD_HEADINGS = re.compile(
    r"^(preface|foreword|introduction|prologue|epilogue|afterword|conclusion|postscript|"
    r"author.s note|editor.s (preface|note)|chapter [\divxlc]+|part [\divxlc]+)$",
    re.I,
)


def norm_title(t):
    return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()


def looks_like_title(txt):
    s = txt.strip()
    return (
        0 < len(s) <= 70
        and not re.search(r"[.,;:!?“”\"]$", s)
        and not s[0] in "“\"'‘("
        and sum(w[:1].isupper() for w in s.split()) >= max(1, len(s.split()) // 2)
    )


def split_stream(stream, toc_titles):
    toc = {norm_title(t) for t in toc_titles if norm_title(t)}
    chapters, cur = [], Chapter("Opening")
    after_break = True
    for kind, txt in stream:
        if kind in ("doc", "break"):
            after_break = True
            continue
        n = norm_title(txt)
        is_heading = (
            kind == "h"
            or (n in toc and looks_like_title(txt))
            or bool(STANDARD_HEADINGS.match(txt.strip()))
            or (after_break and kind == "p" and looks_like_title(txt) and not toc)
        )
        if is_heading and n and not is_noise_line(txt):
            # Running headers repeat the current title; don't start a new chapter for those.
            if norm_title(cur.title) == n or (n in norm_title(cur.title) and len(cur.paragraphs) < 3):
                after_break = False
                continue
            if cur.paragraphs or chapters:
                chapters.append(cur)
            cur = Chapter(txt.strip())
        elif not is_noise_line(txt):
            if norm_title(txt) == norm_title(cur.title):
                continue  # running header inside the chapter body
            cur.paragraphs.append(txt)
        after_break = False
    chapters.append(cur)
    return chapters


# --------------------------------------------------------------------------- PDF

def load_pdf(path: Path, academic: bool) -> Book:
    import pymupdf

    doc = pymupdf.open(str(path))
    title = (doc.metadata or {}).get("title") or path.stem
    author = (doc.metadata or {}).get("author") or ""

    pages = [extract_page_lines(p) for p in doc]
    empty = sum(1 for p in pages if not p)
    if empty > len(pages) * 0.5:
        sys.exit(
            f"{empty}/{len(pages)} pages have no text layer (scanned PDF). OCR it first:\n"
            f"  brew install ocrmypdf && ocrmypdf --skip-text '{path}' ocr.pdf"
        )

    body_size = body_font_size(pages)
    repeated = repeated_margin_text(pages)

    # Build a paragraph stream per page, dropping headers/footers/footnotes/tables.
    stream = []  # (page_no, kind, text)
    for pno, lines in enumerate(pages):
        para, last = [], None
        for ln in lines:
            if ln["margin"] and (margin_key(ln["text"]) in repeated or is_noise_line(ln["text"])):
                continue
            if ln["in_table"]:
                continue
            if academic and ln["bottom"] and ln["size"] < body_size * 0.88:
                continue  # footnote area
            if academic and re.match(r"^(Figure|Fig\.|Table|Chart|Source:)\s*\d*", ln["text"]) and ln["size"] <= body_size:
                continue  # captions
            heading = ln["size"] >= body_size * 1.15 or (ln["bold"] and len(ln["text"]) < 80 and ln["block_lines"] <= 2)
            new_para = (
                last is None
                or heading != last["heading"]
                or ln["block"] != last["block"]
                or ln["y0"] - last["y1"] > ln["height"] * 0.9
            )
            if new_para and para:
                stream.append((pno, "h" if last["heading"] else "p", "\n".join(para)))
                para = []
            para.append(ln["text"])
            ln["heading"] = heading
            last = ln
        if para:
            stream.append((pno, "h" if last["heading"] else "p", "\n".join(para)))

    stream = join_cross_page_paragraphs(stream)
    toc = [(lvl, t, pg - 1) for lvl, t, pg in doc.get_toc() if pg >= 1]
    chapters = split_pdf_by_toc(stream, toc) if len(toc) >= 2 else split_pdf_by_headings(stream, pages, body_size)
    return Book(title, author, finalize(chapters, academic), pdf_cover(doc))


def extract_page_lines(page):
    import pymupdf

    h, w = page.rect.height, page.rect.width
    table_boxes = []
    try:
        table_boxes = [pymupdf.Rect(t.bbox) for t in page.find_tables().tables]
    except Exception:
        pass
    blocks = [b for b in page.get_text("dict")["blocks"] if b.get("type") == 0]
    blocks = order_columns(blocks, w)
    out = []
    for bi, b in enumerate(blocks):
        blines = [l for l in b["lines"] if "".join(s["text"] for s in l["spans"]).strip()]
        for l in blines:
            spans = [s for s in l["spans"] if s["text"].strip() and not (s["flags"] & 1)]  # flag 1 = superscript
            if not spans:
                continue
            text = "".join(s["text"] for s in l["spans"] if not (s["flags"] & 1)).strip()
            # Drop caps and shadowed titles draw the same text twice at one position ("Blood Lust" + "lood Lust").
            if out and abs(out[-1]["y0"] - l["bbox"][1]) < 2 and text in out[-1]["text"]:
                continue
            chars = sum(len(s["text"]) for s in spans)
            size = sum(s["size"] * len(s["text"]) for s in spans) / max(chars, 1)
            x0, y0, x1, y1 = l["bbox"]
            out.append(
                dict(
                    text=text,
                    size=round(size, 1),
                    bold=all(s["flags"] & 16 or "Bold" in s["font"] for s in spans),
                    y0=y0, y1=y1, height=max(y1 - y0, 1),
                    block=bi, block_lines=len(blines),
                    margin=y1 < h * 0.08 or y0 > h * 0.92,
                    bottom=y0 > h * 0.6,
                    in_table=any(r.contains(pymupdf.Point((x0 + x1) / 2, (y0 + y1) / 2)) for r in table_boxes),
                )
            )
    return out


def order_columns(blocks, width):
    """Reading order for 1- or 2-column layouts: full-width blocks split the page into bands,
    and within each band the left column is read before the right."""
    mid = width / 2
    left = [b for b in blocks if b["bbox"][2] <= mid + 10]
    right = [b for b in blocks if b["bbox"][0] >= mid - 10]
    if len(left) < 2 or len(right) < 2:
        return sorted(blocks, key=lambda b: (round(b["bbox"][1]), b["bbox"][0]))
    out, band = [], []
    for b in sorted(blocks, key=lambda b: b["bbox"][1]):
        if b in left or b in right:
            band.append(b)
        else:
            out += sorted(band, key=lambda b: (b["bbox"][0] >= mid - 10, b["bbox"][1]))
            out.append(b)
            band = []
    return out + sorted(band, key=lambda b: (b["bbox"][0] >= mid - 10, b["bbox"][1]))


def body_font_size(pages):
    c = Counter()
    for lines in pages:
        for ln in lines:
            c[ln["size"]] += len(ln["text"])
    return c.most_common(1)[0][0] if c else 10


def margin_key(t):
    return re.sub(r"\d+", "#", t.strip().lower())


def repeated_margin_text(pages):
    c = Counter()
    for lines in pages:
        c.update({margin_key(l["text"]) for l in lines if l["margin"]})
    # Running headers often change per chapter (the story title), so any margin text seen on
    # 3+ pages counts, not just text repeated across the whole book.
    return {k for k, n in c.items() if n >= 3}


def join_cross_page_paragraphs(stream):
    out = []
    for pno, kind, txt in stream:
        if (
            out
            and kind == "p"
            and out[-1][1] == "p"
            and out[-1][0] == pno - 1
            and not re.search(r"[.!?:”\"]\s*$", out[-1][2])
            and txt[:1].islower()
        ):
            out[-1] = (out[-1][0], "p", out[-1][2] + "\n" + txt)
        else:
            out.append((pno, kind, txt))
    return out


def split_pdf_by_toc(stream, toc):
    top = min(l for l, _, _ in toc)
    entries = [(t, p) for l, t, p in toc if l == top]
    if len(entries) < 3:  # e.g. a single top-level "Book title" entry; use the next level instead
        entries = [(t, p) for l, t, p in toc if l <= top + 1]
    chapters = [Chapter("Front matter")]
    idx = 0
    for pno, kind, txt in stream:
        # Start the next TOC chapter at its heading on its page (or at the first paragraph after that page).
        while idx < len(entries) and (
            pno > entries[idx][1]
            or (pno == entries[idx][1] and (kind == "h" or norm_title(entries[idx][0])[:25] in norm_title(txt)))
        ):
            chapters.append(Chapter(entries[idx][0]))
            idx += 1
            if norm_title(txt).replace(" ", "") == norm_title(chapters[-1].title).replace(" ", ""):
                txt = None  # the heading itself; the chapter title is already spoken
        if txt and not is_noise_line(txt):
            chapters[-1].paragraphs.append(txt)
    return chapters


def split_pdf_by_headings(stream, pages, body_size):
    heads = Counter(txt for _, k, txt in stream if k == "h")
    chapters, cur = [], Chapter("Opening")
    for _, kind, txt in stream:
        if kind == "h" and len(txt) < 120 and heads[txt] < 3 and not is_noise_line(txt):
            if cur.paragraphs:
                chapters.append(cur)
                cur = Chapter(txt.replace("\n", " "))
            else:
                cur.title = (cur.title + " " if cur.title != "Opening" else "") + txt.replace("\n", " ")
        elif not is_noise_line(txt):
            cur.paragraphs.append(txt)
    chapters.append(cur)
    return chapters


def pdf_cover(doc):
    try:
        return doc[0].get_pixmap(dpi=100).tobytes("jpg")
    except Exception:
        return None


# --------------------------------------------------------------------------- shared

def finalize(chapters, academic):
    out = []
    for ch in chapters:
        if SKIP_SECTIONS.match(ch.title) or re.match(r"^\s*(\d+\.?\s*)?references\s*$", ch.title, re.I):
            continue
        paras = []
        for p in ch.paragraphs:
            if academic and SKIP_SECTIONS.match(p.split("\n")[0]):
                break  # e.g. a "References" heading inside the last chapter
            c = clean_paragraph(p, academic)
            if c and not is_noise_line(c):
                paras.append(c)
        if sum(len(p) for p in paras) >= 200:
            out.append(Chapter(ch.title, paras))
        elif paras and out:
            out[-1].paragraphs += paras  # tiny fragment: fold into previous chapter
        # a tiny leading fragment (title page, dedication) is dropped
    return out


def load_book(path: Path, academic: bool) -> Book:
    ext = path.suffix.lower()
    if ext == ".pdf":
        return load_pdf(path, academic)
    if ext == ".epub":
        return load_epub(path, academic)
    if ext in (".txt", ".md"):
        text = path.read_text(errors="ignore")
        paras = [p for p in re.split(r"\n\s*\n", text) if p.strip()]
        return Book(path.stem, "", finalize(split_stream([("p", p) for p in paras], []), academic))
    sys.exit(f"Unsupported file type: {ext}")


# --------------------------------------------------------------------------- pronunciation

PRONUNCIATIONS = PROJECT / "pronunciations.txt"


def load_pronunciations(path=PRONUNCIATIONS):
    """'Word = Sound-alike spelling' or 'Word = /phonemes/' per line; '#' starts a comment."""
    rules = []
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                word, say = (x.strip() for x in line.split("=", 1))
                if word and say:
                    rules.append((re.compile(rf"\b{re.escape(word)}\b", re.I), word, say))
    return rules


def apply_pronunciations(text, rules):
    for pat, word, say in rules:
        if say.startswith("/") and say.endswith("/"):
            text = pat.sub(lambda m: f"[{m.group(0)}]({say})", text)  # Kokoro's inline phoneme syntax
        else:
            text = pat.sub(say, text)
    return text


def spoken_chapter(ch, rules):
    title = re.sub(r"^\s*([\d.]+|[IVXLC]+\.)\s+", "", ch.title)  # "2.1 Methods", "IV. Hod" -> title only
    return apply_pronunciations(title, rules), [apply_pronunciations(p, rules) for p in ch.paragraphs]


def chapter_wav(work, i, ch, rules):
    """Cache file named by a hash of the exact spoken text, so changing a pronunciation
    re-renders only the chapters that contain that word."""
    import hashlib

    title, paras = spoken_chapter(ch, rules)
    digest = hashlib.sha1("\n".join([title, *paras]).encode()).hexdigest()[:10]
    return work / f"{i:03d}_{digest}.wav"


def list_unknown_words(book, rules, lang):
    """Words missing from Kokoro's dictionary. They're guessed by a fallback and are the likeliest
    to sound wrong, so they're the first candidates for pronunciations.txt."""
    from misaki import en

    g2p = en.G2P(trf=False, british=(lang == "b"), fallback=None)
    known = {w.lower() for _, w, _ in rules}
    counts = Counter(w for c in book.chapters for p in [c.title, *c.paragraphs]
                     for w in re.findall(r"[A-Za-z][A-Za-z'’-]*[A-Za-z]", p))
    unknown = Counter()
    for w, n in counts.items():
        if w.lower() in known:
            continue
        phonemes, _ = g2p(w)
        if "❓" in phonemes:  # misaki marks words it can't find with a question-mark emoji
            unknown[w] += n
    return unknown


# --------------------------------------------------------------------------- audio

def synthesize(book: Book, work: Path, voice: str, speed: float, lang: str, only: set | None, rules):
    import numpy as np
    import soundfile as sf
    from kokoro import KPipeline

    pipe = KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M", device="cpu")
    para_gap = np.zeros(int(SAMPLE_RATE * 0.45), dtype=np.float32)
    title_gap = np.zeros(int(SAMPLE_RATE * 1.2), dtype=np.float32)
    total_chars = sum(len(c.text) for i, c in enumerate(book.chapters) if not only or i + 1 in only)
    done_chars, start = 0, time.time()

    for i, ch in enumerate(book.chapters, 1):
        if only and i not in only:
            continue
        wav = chapter_wav(work, i, ch, rules)
        if wav.exists():
            print(f"[{i}/{len(book.chapters)}] {ch.title}: cached")
            done_chars += len(ch.text)
            continue
        print(f"[{i}/{len(book.chapters)}] {ch.title} ({len(ch.text):,} chars)", flush=True)
        pieces = []
        spoken_title, spoken_paras = spoken_chapter(ch, rules)
        for r in pipe(spoken_title, voice=voice, speed=speed):
            pieces.append(r.audio.numpy())
        pieces.append(title_gap)
        for p in spoken_paras:
            for r in pipe(p, voice=voice, speed=speed, split_pattern=r"\n+"):
                if r.audio is not None:
                    pieces.append(r.audio.numpy())
            pieces.append(para_gap)
        pieces.append(title_gap)
        tmp = wav.with_suffix(".part.wav")
        sf.write(tmp, np.concatenate(pieces), SAMPLE_RATE)
        tmp.rename(wav)  # atomic: an interrupted chapter is redone, never half-used
        done_chars += len(ch.text)
        el = time.time() - start
        eta = el / max(done_chars, 1) * (total_chars - done_chars)
        print(f"    done; elapsed {el/60:.1f} min, ~{eta/60:.0f} min left", flush=True)


def wav_duration(path):
    import soundfile as sf

    return sf.info(str(path)).duration


def package_m4b(book: Book, work: Path, out: Path, bitrate: str, only: set | None, rules):
    wavs = [(i, chapter_wav(work, i, ch, rules)) for i, ch in enumerate(book.chapters, 1) if not only or i in only]
    wavs = [(i, w) for i, w in wavs if w.exists()]
    if not wavs:
        sys.exit("No audio was generated.")

    concat = work / "concat.txt"
    concat.write_text("".join(f"file '{w.name}'\n" for _, w in wavs))

    esc = lambda s: re.sub(r"([=;#\\\n])", r"\\\1", s)
    meta = [";FFMETADATA1", f"title={esc(book.title)}", f"artist={esc(book.author)}",
            f"album={esc(book.title)}", "genre=Audiobook"]
    t = 0
    for i, w in wavs:
        d = int(wav_duration(w) * 1000)
        meta += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={t}", f"END={t + d}",
                 f"title={esc(book.chapters[i - 1].title)}"]
        t += d
    (work / "chapters.txt").write_text("\n".join(meta) + "\n")

    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-stats",
           "-f", "concat", "-safe", "0", "-i", concat.name,
           "-i", "chapters.txt"]
    cover = work / "cover.jpg"
    if book.cover:
        cover.write_bytes(book.cover)
        cmd += ["-i", cover.name, "-map", "0:a", "-map", "2:v",
                "-c:v", "mjpeg", "-disposition:v", "attached_pic"]
    else:
        cmd += ["-map", "0:a"]
    cmd += ["-map_metadata", "1", "-map_chapters", "1",
            "-c:a", "aac", "-b:a", bitrate, "-ac", "1", "-movflags", "+faststart",
            "-f", "mp4", str(out)]
    # Run inside the work dir with relative names: ffmpeg misparses absolute paths containing "#".
    subprocess.run(cmd, check=True, cwd=work)
    hrs = t / 3_600_000
    print(f"\nWrote {out}  ({hrs:.1f} h, {len(wavs)} chapters, {out.stat().st_size/1e6:.0f} MB)")


# --------------------------------------------------------------------------- CLI

def parse_range(s):
    if not s:
        return None
    out = set()
    for part in s.split(","):
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", type=Path, help="PDF, EPUB or TXT file")
    ap.add_argument("-o", "--output", type=Path, help="output .m4b (default: output/<Author> - <Title>.m4b in the project)")
    ap.add_argument("--voice", default="af_alloy",
                    help="Kokoro voice (default af_alloy): af_heart, af_bella, am_michael, bf_emma, bm_george, bm_lewis, ... "
                         "(blend with 'af_heart,bm_george')")
    ap.add_argument("--speed", type=float, default=1.0, help="speaking rate, e.g. 0.9 or 1.15")
    ap.add_argument("--lang", choices=["a", "b"], help="a = American, b = British (default: from voice)")
    ap.add_argument("--chapters", help="only these chapters, e.g. '1-3,7' (handy for previews)")
    ap.add_argument("--fiction", action="store_true",
                    help="skip academic cleanup (citations, abbreviations, footnotes, captions)")
    ap.add_argument("--cover", type=Path, help="cover image (jpg/png/webp); default: the book's own cover")
    ap.add_argument("--title", help="override book title")
    ap.add_argument("--author", help="override author")
    ap.add_argument("--bitrate", default="64k", help="AAC bitrate (64k is plenty for mono speech)")
    ap.add_argument("--dry-run", action="store_true", help="list chapters and write cleaned text, no audio")
    ap.add_argument("--list-unknown", action="store_true",
                    help="list words Kokoro doesn't know (likely mispronounced), then stop")
    args = ap.parse_args()

    if not args.input.exists():
        sys.exit(f"Not found: {args.input}")
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg is required: brew install ffmpeg")

    book = load_book(args.input, academic=not args.fiction)
    book.title = args.title or book.title
    book.author = args.author or book.author
    if args.cover:
        book.cover = args.cover.read_bytes()
    work = PROJECT / "work" / args.input.stem
    work.mkdir(parents=True, exist_ok=True)

    (work / "cleaned.txt").write_text(
        "\n\n".join(f"### {i}. {c.title}\n\n{c.text}" for i, c in enumerate(book.chapters, 1))
    )
    words = sum(len(c.text.split()) for c in book.chapters)
    print(f"{book.title} — {book.author or 'unknown author'}")
    print(f"{len(book.chapters)} chapters, {words:,} words, ~{words / 155 / 60 / args.speed:.1f} h of audio")
    for i, c in enumerate(book.chapters, 1):
        print(f"  {i:3d}. {c.title[:60]:60s} {len(c.text.split()):>7,} words")
    print(f"Cleaned text: {work / 'cleaned.txt'}")
    rules = load_pronunciations()
    lang = args.lang or args.voice.strip()[0]
    if rules:
        hits = sum(len(pat.findall(c.text)) for pat, _, _ in rules for c in book.chapters)
        print(f"Pronunciations: {len(rules)} rules from {PRONUNCIATIONS.name}, {hits} uses in this book")
    if args.list_unknown:
        unknown = list_unknown_words(book, rules, lang)
        (work / "unknown_words.txt").write_text("".join(f"{w}\t{n}\n" for w, n in unknown.most_common()))
        print(f"\n{len(unknown)} words Kokoro will have to guess (most frequent first):")
        print("  " + ", ".join(f"{w} ({n})" for w, n in unknown.most_common(60)))
        print(f"Full list: {work / 'unknown_words.txt'}")
        print('Hear one with: .venv/bin/python say.py "word"')
        return
    if args.dry_run:
        return

    only = parse_range(args.chapters)
    # Cache audio per voice+speed so switching voices never reuses another voice's chapters.
    audio = work / f"audio_{args.voice.replace(',', '+')}_{args.speed:g}"
    audio.mkdir(exist_ok=True)
    synthesize(book, audio, args.voice, args.speed, lang, only, rules)
    name = f"{book.author} - {book.title}" if book.author else book.title
    out = args.output or PROJECT / "output" / (re.sub(r'[/:\\*?"<>|]+', "", name).strip() + ".m4b")
    out = out.resolve()  # ffmpeg runs inside the work dir, so a relative -o would land there
    out.parent.mkdir(parents=True, exist_ok=True)
    if only:
        out = out.with_name(out.stem + ".preview.m4b")
    package_m4b(book, audio, out, args.bitrate, only, rules)


if __name__ == "__main__":
    main()
