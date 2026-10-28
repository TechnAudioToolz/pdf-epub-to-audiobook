#!/usr/bin/env python3
"""Turn PDFs, EPUBs or TXT files into chaptered M4B audiobooks using Kokoro TTS, fully offline.

    python audiobook.py book.pdf                          # -> output/<Author> - <Title>.m4b
    python audiobook.py book.epub --voice bm_george       # British male narrator
    python audiobook.py paper.pdf --dry-run               # inspect chapters + cleaned text, no audio
    python audiobook.py a.pdf b.epub "My Books/"          # a queue: files and/or whole folders
    python audiobook.py "My Books/" --name-from-file      # outputs named after each file

Queues render one book after another, skip books already in output/, keep going if one fails,
and finish with a summary. Covers are found automatically (see find_cover).
Synthesis is resumable: finished chapters are cached in work/<book>/ and skipped on rerun.
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
PROGRESS = False  # --verbose: also report page-by-page progress while reading a PDF
PROJECT = Path(__file__).resolve().parent  # all output stays inside the project folder


def ffmpeg_exe():
    """ffmpeg from the PATH (Homebrew), else the self-contained copy that ships with imageio-ffmpeg."""
    found = shutil.which("ffmpeg")
    if found:
        return found
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return None


def fix_espeak_data_path():
    """espeak-ng (Kokoro's fallback for unusual words) can't open its data from a folder path longer
    than about 160 characters, and when it fails it quits the whole program without an error. If the
    bundled data sits deep in a long path, use a copy at a short one instead."""
    try:
        import espeakng_loader
        from misaki import espeak  # noqa: F401 -- sets the default path, which we may override below
        from phonemizer.backend.espeak.wrapper import EspeakWrapper
    except Exception:
        return
    data = Path(espeakng_loader.get_data_path())
    if len(str(data)) <= 120:
        return
    short = Path.home() / ".cache" / "audiobook-maker-espeak-ng-data"
    if not (short / "phontab").exists():
        shutil.copytree(data, short, dirs_exist_ok=True)
    EspeakWrapper.set_data_path(str(short))


def import_pymupdf():
    """PyMuPDF 2 loads its AI page-layout add-on on import, which uses Microsoft's onnxruntime. onnxruntime
    reports usage to mobile.events.data.microsoft.com unless told not to, so switch that off first.
    (The add-on itself stays: PyMuPDF reads pages better with it.)"""
    quiet_onnxruntime()
    import pymupdf

    return pymupdf


def quiet_onnxruntime():
    """For tools that do need onnxruntime (Whisper's pause detection): switch off its usage reporting."""
    try:
        import onnxruntime

        onnxruntime.disable_telemetry_events()
    except Exception:
        pass


def stay_offline_if_downloaded(repo, files):
    """The model libraries check huggingface.co for updates every time they start. When the files a
    run needs are already downloaded, tell them to stay offline: nothing about your books is ever
    sent, but there's no reason to call out at all. Missing files (a first run, a new voice) still
    download normally."""
    home = Path(os.environ.get("HF_HOME", Path.home() / ".cache" / "huggingface"))
    snapshots = home / "hub" / ("models--" + repo.replace("/", "--")) / "snapshots"
    if snapshots.is_dir() and any(all((s / f).exists() for f in files) for s in snapshots.iterdir()):
        os.environ["HF_HUB_OFFLINE"] = "1"

# Sections that are noise when listening to non-fiction / academic material.
SKIP_SECTIONS = re.compile(
    r"^\s*((references|bibliography)( and (references|bibliography|notes))?|works cited|literature cited|"
    r"index( [a-z])?|notes|endnotes|published by|.*bookstore|order form|other (books|titles) by .*|"
    r"table of contents|contents|list of (figures|tables|abbreviations)|copyright|"
    r"acknowledg(e)?ments?|appendix [a-z0-9]+|appendices|about the (author|publisher)|about .*publications?|"
    r"also by .*|further reading|the authors?|testimonials|praise for .*|this e-?book is licensed to.*|title page|cover( page)?|colophon|half title)\s*$",
    re.I,
)


# What the cleanup skips by default; --keep reads them anyway (the app's "Also read" checkboxes).
KEEP_CHOICES = {
    "page-numbers": "page numbers",
    "headers": "running headers and footers (the book or chapter title on every page)",
    "footnotes": "footnotes",
    "tables": "tables and chart labels",
    "captions": "figure and table captions",
    "citations": "citations like (Smith, 2020) and [3]",
    "links": "web and email addresses",
    "extras": "front and back matter: copyright, contents, acknowledgments, references, index, about the author, ads",
}


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
    cover_note: str = ""  # where the cover came from, for the summary and the app


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


def clean_paragraph(t: str, academic: bool, keep=frozenset()) -> str:
    t = unicodedata.normalize("NFKC", t)  # also expands ligatures like ﬁ ﬂ
    t = t.replace("­", "")  # soft hyphen
    t = re.sub(r"[\x00-\x09\x0b-\x1f\ufffd]", "", t)  # control chars / broken glyphs from form fields
    t = re.sub(r"(\w)-\s*\n\s*(\w)", r"\1\2", t)  # de-hyphenate line breaks
    t = re.sub(r"\s*\n\s*", " ", t)
    t = t.replace("`", "‘")  # OCR-era backtick quotes
    if "links" not in keep:
        t = re.sub(r"https?://\S+|www\.\S+", "", t)
        t = re.sub(r"\S+@\S+\.\w+", "", t)  # emails
    # Footnote markers glued to punctuation or words: 'fact.4', 'Italia.“4', 'word¹'
    t = re.sub(r"([.,;:!?“”’\"')\]])\d{1,3}(?=\s|$)", r"\1", t)
    t = re.sub(r"[¹²³⁰-₟]+", "", t)
    if academic and "citations" not in keep:
        t = re.sub(r"\s*\[(\d+([,–\-]\s*\d+)*)\]", "", t)  # [3], [1, 4-6]
        # (Smith, 2020), (Smith & Lee, 2019; Doe et al., 2021a), (see Smith 2020, p. 4)
        t = re.sub(
            r"\s*\((?:see |e\.g\.,? |cf\. )?[A-Z][^()]{0,120}?\b(1[89]|20)\d{2}[a-z]?(,? ?pp?\. ?\d+(–|-)?\d*)?"
            r"(;[^()]{0,120}?\b(1[89]|20)\d{2}[a-z]?)*\)",
            "",
            t,
        )
    if academic:
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


def title_and_author(title, author, path):
    """The file's own title and author, unless they're junk (scanners leave things like "1", "Untitled" or
    "Microsoft Word - draft.doc"); then the file name, read as "Author - Title" when it has that shape."""
    def useful(v):
        v = re.sub(r"\s+", " ", v or "").strip()
        junk = re.match(r"(?i)^(untitled|unknown|none|null|title|author|admin(istrator)?|user|owner|microsoft word\b.*|"
                        r"(layout|document|untitled|book|print|pages?|doc)[\s_-]*\d*|.*\.(docx?|pdf|indd|rtf|qxd|p65))$", v)
        return v if len(re.findall(r"[^\W\d_]", v)) >= 3 and not junk else ""

    title, author = useful(title), useful(author)
    if not title:
        stem = re.sub(r"[_]+", " ", path.stem).strip()
        left, sep, right = (part.strip() for part in stem.partition(" - "))
        if not sep:
            return stem, author
        # "Author - Title" is usual, but "Title - Author" is common too: the side that looks like a
        # person's name (2-4 words, no "of", "the", "and"...) is the author.
        name_like = lambda t: 2 <= len(t.split()) <= 4 and not any(w.lower() in SMALL_WORDS for w in t.split())
        if name_like(right) and not name_like(left):
            left, right = right, left
        title, author = right, author or left
    return title, author


# --------------------------------------------------------------------------- EPUB

def load_epub(path: Path, academic: bool, keep=frozenset()) -> Book:
    import ebooklib
    from bs4 import BeautifulSoup
    from ebooklib import epub

    book = epub.read_epub(str(path), options={"ignore_ncx": False})
    meta = lambda k: (book.get_metadata("DC", k) or [("", {})])[0][0]
    title, author = title_and_author(meta("title"), meta("creator"), path)

    cover = epub_cover(book)

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
    return Book(title, author, finalize(chapters, academic, keep), cover, "the EPUB's cover image" if cover else "")


def epub_images(book):
    """The EPUB's pictures in reading order: those its first pages show, then the rest (skipping tiny icons)."""
    import posixpath

    import ebooklib

    images = [i for i in book.get_items() if i.get_type() in (ebooklib.ITEM_IMAGE, ebooklib.ITEM_COVER)]
    by_name = {i.get_name(): i for i in images}
    shown = []
    for idref, _ in book.spine[:4]:
        doc = book.get_item_with_id(idref)
        if doc is None or doc.get_type() != ebooklib.ITEM_DOCUMENT:
            continue
        for src in re.findall(r'<(?:img[^>]+src|image[^>]+href)="([^"]+)"', doc.get_content().decode(errors="ignore")):
            item = by_name.get(posixpath.normpath(posixpath.join(posixpath.dirname(doc.get_name()), src)))
            if item and item not in shown:
                shown.append(item)
    rest = [i for i in images if i not in shown]
    return [i for i in shown + rest if len(i.get_content()) > 10_000]


def epub_cover(book):
    """The cover image: the one the EPUB declares, else one named "cover", else the first picture it shows."""
    import ebooklib

    items = list(book.get_items())
    declared = [i for i in items if i.get_type() == ebooklib.ITEM_COVER]
    declared += [book.get_item_with_id(m[1].get("content")) for m in book.get_metadata("OPF", "cover") if m[1].get("content")]
    declared += [i for i in items if i.get_type() == ebooklib.ITEM_IMAGE and "cover" in i.get_name().lower()]
    for item in declared:
        if item is not None:
            return item.get_content()
    images = epub_images(book)
    return images[0].get_content() if images else None


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

def load_pdf(path: Path, academic: bool, keep=frozenset()) -> Book:
    pymupdf = import_pymupdf()

    doc = pymupdf.open(str(path))
    meta = doc.metadata or {}
    title, author = title_and_author(meta.get("title"), meta.get("author"), path)

    # A scan (pages that are only pictures) is spotted cheaply first, so it goes straight to text recognition
    # instead of the full layout analysis, which takes minutes on hundreds of picture pages.
    empty = sum(1 for p in doc if not p.get_text("text").strip())
    pages = []
    if empty <= len(doc) * 0.5:
        for n, p in enumerate(doc, 1):
            pages.append(extract_page_lines(p))
            if PROGRESS and (n % 10 == 0 or n == len(doc)):
                print(f"Reading page {n}/{len(doc)}", flush=True)  # the app shows this while checking
    if empty > len(doc) * 0.5:
        pages = ocr_pages(path, len(doc))  # a scan: read the page pictures with the Mac's text recognition
        if pages is None:
            sys.exit(
                f"{empty}/{len(pages or doc)} pages have no text layer (scanned PDF), and the text recognition tool "
                f"isn't available here. Build it with: swiftc -O app/ocr.swift -o bin/ocr"
            )

    body_size = body_font_size(pages)
    repeated = repeated_margin_text(pages)

    # Build a paragraph stream per page, dropping headers/footers/footnotes/tables (unless kept).
    stream = []  # (page_no, kind, text)
    for pno, lines in enumerate(pages):
        para, last = [], None
        for ln in lines:
            marker = chapter_marker(ln["text"])
            if marker:
                ln["text"] = marker  # a plain "CHAPTER 4" line is a heading, never page furniture
            elif is_page_furniture(ln, repeated, academic, body_size, keep):
                continue
            # the title in capitals right under it: "MY INTRODUCTION TO HUMANITY"
            # (a long title wraps onto a second line in capitals)
            caps_title = bool(last and (last.get("marker") or last.get("caps")) and ln["text"].isupper()
                              and len(ln["text"].split()) <= 12)
            ln["caps"] = caps_title
            if caps_title:
                ln["text"] = tidy_title(ln["text"], continued=bool(last.get("caps")))
            heading = (bool(marker) or caps_title or ln["size"] >= body_size * 1.15
                       or (ln["bold"] and len(ln["text"]) < 80 and ln["block_lines"] <= 2))
            ln["marker"] = bool(marker)
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
    # Sorted by page: some PDFs list a section after one that starts later in the book.
    toc = sorted(((lvl, t, pg - 1) for lvl, t, pg in doc.get_toc() if pg >= 1), key=lambda e: e[2])
    chapters = split_pdf_by_toc(stream, toc) if len(toc) >= 2 else split_pdf_by_headings(stream, pages, body_size)
    substantial = sum(1 for c in chapters if sum(len(p.split()) for p in c.paragraphs) >= 500)
    if len(toc) < 2 and substantial < 4:
        # Chapter titles drawn as pictures leave no headings in the text; the running header still names the chapter.
        by_header = split_pdf_by_running_headers(stream, pages)
        if len(by_header) >= 4:
            chapters = by_header
    cover, cover_page = pdf_cover(doc)
    note = f"page {cover_page + 1} of the PDF" if cover else ""
    return Book(title, author, finalize(chapters, academic, keep), cover, note)


def chapter_marker(text):
    """A line that is only "CHAPTER 4" (also "CHAPTER4", or an OCR slip like "CHATTER 30") becomes
    "Chapter 4"; anything else gives None."""
    import difflib

    m = re.fullmatch(r"\s*([A-Za-z]{5,9})\s*(\d{1,3}|[IVXLCivxlc]{1,7})\s*[.:]?\s*", text)
    if not m:
        return None
    word = m.group(1).lower()
    if word != "chapter" and difflib.SequenceMatcher(None, word, "chapter").ratio() < 0.8:
        return None
    return f"Chapter {m.group(2).upper() if m.group(2).isalpha() else m.group(2)}"


SMALL_WORDS = set("a an and as at but by for from in into nor of on or the to with".split())


def tidy_title(t, continued=False):
    """ "MY INTRODUCTION TO HUMANITY" -> "My Introduction to Humanity" (Roman numerals stay as they are).
    continued: the second line of a title, so its first word isn't the title's first word."""
    words = re.sub(r"\s+", " ", t).strip().split(" ")
    out = []
    for i, w in enumerate(words):
        bare = w.strip("\"'“”‘’()[]")
        if re.fullmatch(r"[IVXLC]+[.:,]?", bare):
            out.append(w)
        elif (i or continued) and bare.lower() in SMALL_WORDS:
            out.append(w.lower())
        else:  # capitalise the first letter, even after an opening quote: '"FREE' -> '"Free'
            out.append(re.sub(r"[A-Za-z]", lambda m: m.group(0).upper(), w.lower(), count=1))
    return " ".join(out)


def is_page_furniture(ln, repeated, academic, body_size, keep=frozenset()):
    """Page numbers, running headers, table cells, footnotes and captions: not read unless in `keep`."""
    if ln["margin"] and is_noise_line(ln["text"]):
        return "page-numbers" not in keep
    if ln["margin"] and margin_key(ln["text"]) in repeated:
        return "headers" not in keep
    if ln["in_table"]:
        return "tables" not in keep
    if academic and ln["bottom"] and ln["size"] < body_size * 0.88:
        return "footnotes" not in keep  # footnote area
    if academic and re.match(r"^(Figure|Fig\.|Table|Chart|Source:)\s*\d*", ln["text"]) and ln["size"] <= body_size:
        return "captions" not in keep
    return False


def ocr_exe():
    """The text recognition tool: the app's own copy (AUDIOBOOK_OCR), else bin/ocr in the project."""
    for p in (os.environ.get("AUDIOBOOK_OCR"), PROJECT / "bin" / "ocr"):
        if p and Path(p).is_file():
            return str(p)
    return None


def ocr_pages(path, count):
    """Page lines for a scanned PDF, read with the Mac's built-in text recognition (app/ocr.swift).
    The result is saved, so each book is only read once."""
    import json

    exe = ocr_exe()
    if not exe:
        return None
    work = PROJECT / "work" / path.stem
    work.mkdir(parents=True, exist_ok=True)
    st = path.stat()
    cache = work / f"ocr-{st.st_size}-{int(st.st_mtime)}.json"
    if not cache.exists():
        print(f"Scanned PDF: reading its {count} pages with the Mac's text recognition (about 3 pages a second, "
              f"saved for next time)...", flush=True)
        tmp = cache.with_suffix(".tmp")
        proc = subprocess.Popen([exe, str(path.resolve()), str(tmp)], stdout=subprocess.PIPE, text=True)
        for line in proc.stdout:
            n = re.match(r"OCR page (\d+)/(\d+)", line)
            if n and (int(n[1]) % (5 if PROGRESS else 20) == 0 or n[1] == n[2]):
                print(line.rstrip(), flush=True)
        if proc.wait() != 0 or not tmp.exists():
            return None
        tmp.rename(cache)
    return [ocr_page_lines(p) for p in json.loads(cache.read_text())["pages"]]


def ocr_page_lines(page):
    """Recognised text lines in the same shape as extract_page_lines, so the rest of the cleanup and the
    chapter finding work on scans too. Scanned books mark paragraphs with an indent, not a gap."""
    w, h = page["width"] or 1, page["height"] or 1
    # Recognition marks text it is unsure of (diagrams, handwriting, smudges) with low confidence: skip it.
    raw = sorted((l for l in page["lines"] if l.get("conf", 1) > 0.35), key=lambda l: (l["y0"] + l["y1"]) / 2)
    # Recognition sometimes splits one printed line in two: merge pieces that sit side by side.
    rows = []
    for l in raw:
        mid, hgt = (l["y0"] + l["y1"]) / 2, l["y1"] - l["y0"]
        if rows and abs(mid - rows[-1]["mid"]) < 0.4 * max(hgt, rows[-1]["y1"] - rows[-1]["y0"]):
            r = rows[-1]
            parts = sorted([(r["x0"], r["text"]), (l["x0"], l["text"])])
            r.update(text=" ".join(t for _, t in parts), x0=min(r["x0"], l["x0"]), x1=max(r["x1"], l["x1"]),
                     y0=min(r["y0"], l["y0"]), y1=max(r["y1"], l["y1"]))
        else:
            rows.append(dict(l, mid=mid))
    if not rows:
        return []
    long_rows = [r for r in rows if len(r["text"]) > 30] or rows
    # Line heights from recognition vary with the letters in them (tall capitals, low tails), so sizes are
    # relative to the page's typical text line: ordinary text is 10, only clearly bigger lines are more.
    typical = sorted(r["y1"] - r["y0"] for r in long_rows)[len(long_rows) // 2] or 1
    left = min(r["x0"] for r in long_rows)
    right = max(r["x1"] for r in long_rows)
    out, block, prev = [], 0, None
    for r in rows:
        height = max(r["y1"] - r["y0"], 0.5)
        if prev is not None:
            indent = r["x0"] - left > (right - left) * 0.03
            ended = prev["x1"] < right - (right - left) * 0.12 and re.search(r"[.!?:\"”’)]\s*$", prev["text"])
            gap = r["y0"] - prev["y1"] > height * 0.9
            if indent or ended or gap:
                block += 1
        rel = height / typical
        # only heading-shaped lines (short, starting with a capital or number) may be bigger than the text
        title_like = len(r["text"]) <= 70 and len(r["text"].split()) <= 10 and re.match(r"[\"“'(]?[A-Z0-9]", r["text"]) and not r["text"].endswith((",", "-"))
        size = round(rel * 10) if rel >= 1.4 and title_like else 10.0
        out.append(dict(text=r["text"], size=size, bold=False, y0=r["y0"], y1=r["y1"],
                        height=height, block=block, block_lines=0,
                        margin=r["y1"] < h * 0.10 or r["y0"] > h * 0.92, bottom=r["y0"] > h * 0.6, in_table=False))
        prev = r
    sizes = Counter(l["block"] for l in out)
    for l in out:
        l["block_lines"] = sizes[l["block"]]
    return out


def extract_page_lines(page):
    pymupdf = import_pymupdf()

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
                    margin=y1 < h * 0.10 or y0 > h * 0.92,
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


MAJOR_HEADING = re.compile(
    r"^\s*(chapter|section|part|book)\s+[\divxlc]+\b|^\s*(editors?.?s? )?(foreword|preface|introduction|prologue|"
    r"epilogue|afterword|conclusion|appendix|glossary|bibliography|references|index|acknowledg)",
    re.I,
)


def split_pdf_by_headings(stream, pages, body_size):
    heads = Counter(txt for _, k, txt in stream if k == "h")
    # Books with explicit "Chapter N" headings: only those (and front/back-matter headings) start a
    # chapter, so subheadings stay inside their chapter instead of becoming dozens of tiny ones.
    major_only = sum(1 for t in heads if re.match(r"^\s*chapter\s+[\divxlc]+\b", t, re.I)) >= 3
    chapters, cur, part = [], Chapter("Opening"), None
    for _, kind, txt in stream:
        is_head = kind == "h" and len(txt) < 120 and heads[txt] < 3 and not is_noise_line(txt)
        m = re.match(r"(?i)^\s*part\s+([\divxlc]+)\b", txt) if is_head else None
        if m:  # chapter numbers often restart in each part: "Part II, Chapter 1"
            part = f"Part {m.group(1).upper() if m.group(1).isalpha() else m.group(1)}"
            txt = tidy_title(txt) if txt.isupper() else txt
        if is_head and major_only and not MAJOR_HEADING.match(txt):
            # "CHAPTER 1" on one line and "The Problem" on the next: join them into one title
            # (and a title that wraps onto a second heading line: "Ghosts and" + "Poltergeists")
            m = re.fullmatch(r"\s*(?:part\s+[\divxlc]+,\s*)?(chapter|section|part)\s+[\divxlc]+(:.*)?\s*", cur.title, re.I | re.S)
            if not cur.paragraphs and m:
                sep = " " if m.group(2) else ": "
                cur.title = f"{cur.title.strip()}{sep}{txt.replace(chr(10), ' ').strip()}"
                continue
            is_head = False
        if is_head:
            # "Chapter 2" and its title in one block: "Chapter 2: The Greeters"
            title = re.sub(r"^(\s*(?:chapter|section|part)\s+[\divxlc]+)\s*\n", r"\1: ", txt, flags=re.I).replace("\n", " ")
            if part and re.match(r"(?i)^\s*chapter\b", title):
                title = f"{part}, {title.strip()}"
            if cur.paragraphs:
                chapters.append(cur)
                cur = Chapter(title)
            else:
                cur.title = (cur.title + " " if cur.title != "Opening" else "") + title
        elif not is_noise_line(txt):
            cur.paragraphs.append(txt)
    chapters.append(cur)
    return chapters


def split_pdf_by_running_headers(stream, pages):
    """Chapters from the running header at the top of each page ("The Grand Tour" on the pages of that
    chapter), for PDFs whose chapter titles are pictures. A header seen across much of the book is the
    book's own title and is ignored."""
    first, last, title = {}, {}, {}
    for pno, lines in enumerate(pages):
        for ln in lines:
            if not ln["margin"] or ln["bottom"]:
                continue
            key = re.sub(r"[“”]", '"', margin_key(ln["text"])).strip("# ")
            if not re.search(r"[a-z]{3}", key):
                continue  # page numbers
            first.setdefault(key, pno)
            last[key] = pno
            title.setdefault(key, re.sub(r"^\d+\s+|\s+\d+$", "", ln["text"].strip()))
    keys = sorted((k for k in first if first[k] != last[k] and last[k] - first[k] < len(pages) * 0.3), key=first.get)
    if len(keys) < 4:
        return []

    def opening(pno):  # a picture-only title page, or a first line in capitals: "NOT ALL OF MY INFORMATION…"
        lines = pages[pno]
        return not lines or bool(re.match(r"^[A-Z][A-Z’'\-]+( [A-Z’'\-]+){2,}", lines[0]["text"]))

    # A chapter's first page has no header: start at the latest opening page before its first header.
    bounds, prev_end = [], 0
    for k in keys:
        lo = prev_end
        start = next((p for p in range(first[k], lo - 1, -1) if opening(p)), max(first[k] - 1, lo))
        bounds.append((start, title[k]))
        prev_end = last[k] + 1
    chapters = [Chapter("Opening")]
    for pno, kind, txt in stream:
        while bounds and pno >= bounds[0][0]:
            chapters.append(Chapter(bounds.pop(0)[1]))
        if not is_noise_line(txt):
            chapters[-1].paragraphs.append(txt)
    return [c for c in chapters if c.paragraphs]


def page_image(page, max_px=1600, dpi=200):
    """A page as a JPEG, sharp enough for a player's cover art but not huge."""
    dpi = int(min(dpi, max_px * 72 / max(page.rect.height, page.rect.width, 1)))
    return page.get_pixmap(dpi=dpi).tobytes("jpg", jpg_quality=85)


def looks_like_cover(page):
    """Mostly a picture, few words, and real ink on it: a cover, not a blank or a page of text."""
    pymupdf = import_pymupdf()
    area = abs(page.rect) or 1
    pictured = sum(abs(pymupdf.Rect(i["bbox"]) & page.rect) for i in page.get_image_info())
    if pictured / area < 0.45 or len(page.get_text("words")) > 60:
        return False
    small = page.get_pixmap(dpi=20, colorspace=pymupdf.csGRAY)
    ink = sum(1 for b in small.samples if b < 200) / max(len(small.samples), 1)
    return ink >= 0.10  # scanned blank pages are pictures too, but nearly white


def pdf_cover(doc):
    """(JPEG, page index) for the first cover-like page among the first four, else (None, None)."""
    for pno in range(min(4, len(doc))):
        try:
            if looks_like_cover(doc[pno]):
                return page_image(doc[pno]), pno
        except Exception:
            continue
    return None, None


COVER_COLORS = [(0.20, 0.32, 0.55), (0.42, 0.27, 0.62), (0.13, 0.47, 0.38), (0.62, 0.36, 0.20),
                (0.36, 0.40, 0.22), (0.55, 0.20, 0.24), (0.17, 0.17, 0.19), (0.16, 0.38, 0.52)]


def generated_cover(title, author):
    """A plain square cover: the title and author in a serif typeface on a color picked from the title,
    for books without cover art. Square, because that's how audiobook players show covers."""
    import hashlib

    pymupdf = import_pymupdf()
    size = 1400
    color = COVER_COLORS[hashlib.md5(title.encode()).digest()[0] % len(COVER_COLORS)]

    def fit(text, rect, font, largest, smallest):
        """Largest font size at which `text` fits in `rect`, and the height left over."""
        for fs in range(largest, smallest - 1, -4):
            spare = pymupdf.open().new_page(width=size, height=size).insert_textbox(rect, text, fontsize=fs, fontname=font, align=1)
            if spare >= 0:
                return fs, spare
        return smallest, 0

    doc = pymupdf.open()
    page = doc.new_page(width=size, height=size)
    page.draw_rect(page.rect, color=None, fill=color)
    page.draw_rect(pymupdf.Rect(60, 60, size - 60, size - 60), color=(1, 1, 1), width=4, stroke_opacity=0.85)
    box = pymupdf.Rect(150, 250, size - 150, 950)
    fs, spare = fit(title, box, "Times-Bold", 150, 48)
    page.insert_textbox(box + (0, spare / 2, 0, spare / 2), title, fontsize=fs, fontname="Times-Bold",
                        color=(1, 1, 1), align=1)
    if author:
        page.draw_line((size / 2 - 90, 1030), (size / 2 + 90, 1030), color=(1, 1, 1), width=2, stroke_opacity=0.7)
        box = pymupdf.Rect(150, 1070, size - 150, 1230)
        fs, _ = fit(author, box, "Times-Italic", 64, 32)
        page.insert_textbox(box, author, fontsize=fs, fontname="Times-Italic", color=(0.92, 0.92, 0.92), align=1)
    return page.get_pixmap(dpi=72).tobytes("jpg", jpg_quality=90)


def cover_choices(path, book, folder, pages=6, pictures=()):
    """Writes candidate covers for the app's cover picker: the book's first pages (PDF), or its cover and
    pictures (EPUB). The generated cover is made separately, on request (--generate-cover). Returns [(file, label)]."""
    out = []
    if path.suffix.lower() == ".pdf":
        doc = import_pymupdf().open(str(path))
        for pno in range(min(pages, len(doc))):
            f = folder / f"page-{pno + 1:03d}.jpg"
            f.write_bytes(page_image(doc[pno]))
            out.append((f, f"Page {pno + 1}"))
    else:
        others = [p for p in pictures if p != book.cover]
        for n, data in enumerate(([book.cover] if book.cover else []) + others):
            if len(out) == pages:
                break
            f = folder / f"picture-{n + 1:03d}.jpg"
            f.write_bytes(data)  # JPEG or PNG; the app and ffmpeg read either
            out.append((f, "The book's cover" if n == 0 and book.cover else f"Picture {n + 1}"))
    return out


# --------------------------------------------------------------------------- shared

COPYRIGHT_LINE = re.compile(
    r"library of congress|\bisbn\b|all rights reserved|printed in (the )?(usa|u\.s\.a|united states|canada|"
    r"great britain|england)|^\W*(fax|tel|telephone|phone|e-?mail|homepage)\s*:|\bp\.?\s?o\.? box\b|"
    r"^\W*copyright\s*(©|\(c\)|\d{4})", re.I)
QR_PROMPT = re.compile(r"^\W*scan (this|the|here)\b.{0,40}\b(video|qr|code|link)\b", re.I)

FUNCTION_WORDS = set("a an the of in on to for and or but is it if as at by be we he she was with that this from "
                     "not are his her its their our your all any can".split())
OCR_SWAPS = [("nn", "rm"), ("rn", "m"), ("nn", "m"), ("m", "rn"), ("cl", "d"), ("vv", "w"), ("ii", "u"), ("oo", "oa"),
             ("1", "l"), ("0", "o")]
_g2p = None
_known_cache = {}


def known_word(w):
    """True if Kokoro's own word recogniser can pronounce w without guessing. It understands
    endings (becomes, towards, therapists), which a plain word list doesn't."""
    global _g2p
    if w not in _known_cache:
        if _g2p is None:
            from misaki import en
            _g2p = en.G2P(trf=False, british=False, fallback=None)
        phonemes, _ = _g2p(w)
        _known_cache[w] = "\u2753" not in phonemes
    return _known_cache[w]


def ocr_fix_word(w):
    """Repair one word mangled by text recognition, but only when it isn't a real word and a classic
    OCR mistake turns it into one: perfonn -> perform, ofthe -> of the, identifY -> identify."""
    if len(w) < 3 or w.isupper() or known_word(w):
        return w
    name_like = w[0].isupper() and w[1:].islower()  # Bateson, Horney, Ann: never "repair" names
    lower = w[0] + w[1:].lower()
    if lower != w and known_word(lower):
        return lower  # stray capital
    if len(w) < 5 or name_like:
        return w  # short words are often hyphenation fragments ("tion", "impor"); names stay as they are
    if w.islower():
        for i in range(2, len(w) - 1):  # run-together words: "ofthe", "meansthat"
            a, b = w[:i], w[i:]
            ok = ((a in FUNCTION_WORDS and (b in FUNCTION_WORDS or len(b) >= 4))  # of+the, in+depth
                  or (b in FUNCTION_WORDS and len(a) >= 5))                        # means+that, subtle+and
            if ok and known_word(a) and known_word(b):
                return f"{a} {b}"
    for bad, good in OCR_SWAPS:
        start = w.find(bad)
        while start != -1:
            cand = w[:start] + good + w[start + len(bad):]
            if known_word(cand):
                return cand
            start = w.find(bad, start + 1)
    return w


def ocr_repair(text):
    text = re.sub(r"\b(him|his|he)l(her|herself|hers|she)\b", r"\1 or \2", text)  # "himlherself" = him/herself
    # whole words including apostrophes, so "weren't" is checked as one word, not "weren" + "t"
    return re.sub(r"[A-Za-z][A-Za-z0-9'\u2019]*[A-Za-z]", lambda m: ocr_fix_word(m.group(0)), text)


# Per-copy licence watermarks name the buyer; never read them out.
WATERMARK = re.compile(r"\bthis e-?book is licen[cs]ed to\b|\blicen[cs]ed to [^.]{0,80}@", re.I)
FORM_ANSWERS = re.compile(r"^\W*((yes|no|true|false|agree|disagree)\W*)+$", re.I)


def is_table_label(p):
    """Short lines that are mostly numbers: chart axes, table cells ("4 5 6 7", "113 State")."""
    words = p.split()
    return len(words) <= 12 and sum(bool(re.fullmatch(r"[\d.,%:/()-]+", w)) for w in words) >= max(1, len(words) / 2)


def finalize(chapters, academic, keep=frozenset()):
    """Cleans each chapter. `keep` (see KEEP_CHOICES) reads things the cleanup would otherwise skip."""
    extras = "extras" in keep
    out = []
    # Short lines repeated all over the book are page furniture (running headers, table column labels):
    # keep the first one (often a real subheading) and drop the repeats.
    norm = lambda p: re.sub(r"\s+", " ", p).strip().lower()
    repeats = Counter(norm(p) for ch in chapters for p in ch.paragraphs if len(p.split()) <= 8)
    seen_repeat = set()
    for ch in chapters:
        if not extras and (SKIP_SECTIONS.match(ch.title) or re.match(r"^\s*(\d+\.?\s*)?references\s*$", ch.title, re.I)):
            continue
        paras = []
        for p in ch.paragraphs:
            if academic and not extras and SKIP_SECTIONS.match(p.split("\n")[0]):
                break  # e.g. a "References" heading inside the last chapter
            c = clean_paragraph(p, academic, keep)
            if not re.search(r"\w", c):
                continue  # nothing to say: scene-break glyphs, stray symbols
            if is_noise_line(c) and "page-numbers" not in keep:
                continue
            if is_table_label(c) and "tables" not in keep:
                continue
            if not extras and (FORM_ANSWERS.match(c) or WATERMARK.search(p) or COPYRIGHT_LINE.search(c) or QR_PROMPT.match(c)):
                continue
            c = ocr_repair(c)
            k = norm(p)
            if repeats.get(k, 0) >= 4 and "headers" not in keep:
                if k in seen_repeat:
                    continue
                seen_repeat.add(k)
            paras.append(c)
        if sum(len(p) for p in paras) >= 200 or (extras and paras and not out):
            out.append(Chapter(re.sub(r"\s+", " ", ch.title).strip(), paras))  # no stray \r or \n in titles
        elif paras and out:
            out[-1].paragraphs += paras  # tiny fragment: fold into previous chapter
        # a tiny leading fragment (title page, dedication) is dropped
    if not extras and len(out) > 2 and out[0].title in ("Opening", "Front matter") and sum(len(p.split()) for p in out[0].paragraphs) < 300:
        out = out[1:]  # title page / dedication / list of tables before the first real heading
    return out


def load_book(path: Path, academic: bool, keep=frozenset()) -> Book:
    ext = path.suffix.lower()
    if ext == ".pdf":
        return load_pdf(path, academic, keep)
    if ext == ".epub":
        return load_epub(path, academic, keep)
    if ext in (".txt", ".md"):
        text = path.read_text(errors="ignore")
        paras = [p for p in re.split(r"\n\s*\n", text) if p.strip()]
        return Book(path.stem, "", finalize(split_stream([("p", p) for p in paras], []), academic, keep))
    sys.exit(f"Unsupported file type: {ext}")


# --------------------------------------------------------------------------- pronunciation

PRONUNCIATIONS = PROJECT / "pronunciations.txt"


def word_pattern(word):
    """Whole-word match that also works for words with apostrophes (A'N') and keeps a trailing 's.
    Words with two or more capitals (AN, SQL) match only in capitals, so 'AN' never touches 'an'."""
    body = re.sub("['\u2019]", lambda m: "['\u2019]", re.escape(word))  # straight or curly apostrophe
    flags = 0 if sum(ch.isupper() for ch in word) >= 2 else re.I
    return re.compile(rf"(?<![\w'\u2019]){body}(?=(?:['\u2019]s)?(?![\w]))", flags)


def book_pronunciations_path(stem):
    return PROJECT / "pronunciations" / f"{stem}.txt"


def load_pronunciations(path=PRONUNCIATIONS, book=None):
    """'Word = Sound-alike spelling' or 'Word = /phonemes/' per line; '#' starts a comment.
    Book-specific rules in pronunciations/<book>.txt are applied before the global ones."""
    rules = []
    paths = ([book_pronunciations_path(book)] if book else []) + [path]
    for f in paths:
        if not f.exists():
            continue
        for line in f.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                word, say = (x.strip() for x in line.split("=", 1))
                if word and say:
                    rules.append((word_pattern(word), word, say))
    return rules


def apply_pronunciations(text, rules):
    for pat, word, say in rules:
        if say.startswith("/") and say.endswith("/"):
            text = pat.sub(lambda m: f"[{m.group(0)}]({say})", text)  # Kokoro's inline phoneme syntax
        else:
            text = pat.sub(say, text)
    return text


ROMAN = re.compile(r"^M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$")
# Words that take a plain number after them: "Part III" is said "Part three"
NUMBERED_BY = (r"(?i:chapter|part|section|book|volume|vol\.|phase|stage|act|scene|article|appendix|plate|lesson|"
               r"lecture|canto|psalm|level|class|grade|type|step|degree|war|exercise|rule|law|principle|"
               r"category|schedule|tier|division|unit|module|issue|exhibit|table|figure|fig\.|diagram|chart|form)")
# Rulers and popes take an ordinal: "Henry VIII" -> "Henry the Eighth". Any other name or term takes a
# plain number: Bateson's "Learning IV" -> "Learning four", "Consciousness III" -> "Consciousness three".
REGNAL_NAMES = set("""Henry Louis Charles George Edward Elizabeth James William Richard John Paul Pius Leo Gregory
    Innocent Benedict Clement Philip Philippe Frederick Alexander Peter Catherine Napoleon Ramesses Rameses Ramses
    Thutmose Amenhotep Ptolemy Seti Mary Anne Victoria Alfonso Ferdinand Constantine Nicholas Ivan Otto Gustav
    Gustavus Carlos Juan Pedro Henri Urban Boniface Sixtus Julius Felix Martin Eugene Eugenius Stephen Adrian
    Hadrian Celestine Honorius Nicolas Wilhelm Friedrich Karl Ludwig Francis Franz Leopold Rudolf Harold Malcolm
    David Robert Alfred Edmund Canute Cnut Olaf Haakon Christian Sancho Manuel Joseph Jose Isabella Isabel
    Margaret Matilda Darius Cyrus Xerxes Artaxerxes Antiochus Seleucus Herod Amenemhat Senusret Sesostris""".split())


def roman_value(s):
    s = s.upper()
    if not s or not ROMAN.match(s):
        return None
    values = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}
    total = 0
    for a, b in zip(s, s[1:] + " "):
        total += -values[a] if b in values and values[b] > values[a] else values[a]
    return total


def speak_roman_numerals(text):
    """Kokoro reads Roman numerals as letters ("III" as "eye-eye-eye"). Say them as a narrator would:
    a numbered paragraph "III. The ..." -> "Three. The ...", "Part III" -> "Part three",
    "(iii)" -> "three", "Henry VIII" -> "Henry the Eighth". A lone "I" only counts as a number when it
    opens a numbered paragraph, and names only take numerals made of I, V and X ("DC" is left alone)."""
    from num2words import num2words

    # numbered paragraphs use I, V and X only, so lettered lists ("c. ...") stay letters
    m = re.match(r"^\(?([IVXivx]{1,6})[.)]\s+(?=[A-Z\u201c\"'])", text)
    if m and (n := roman_value(m.group(1))):
        text = num2words(n).capitalize() + ". " + text[m.end():]

    def by_keyword(m):
        numeral, after = m.group(2), text[m.end():m.end() + 4]
        if len(numeral) == 1 and numeral not in "IVX":
            return m.group(0)  # "Appendix C" is a letter
        if numeral == "I" and not re.match(r"\s*([^\w\s]|of\b|$)", after):
            return m.group(0)  # "a book I read": the pronoun
        n = roman_value(numeral)
        return f"{m.group(1)} {num2words(n)}" if n else m.group(0)

    text = re.sub(rf"\b({NUMBERED_BY})\s+([IVXLC]{{1,7}})\b(?![\w'])", by_keyword, text)

    def in_parens(m):
        n = roman_value(m.group(1))
        return num2words(n) if n else m.group(0)

    text = re.sub(r"\(([ivx]{1,5}|[IVX]{1,5})\)", in_parens, text)

    def regnal(m):
        n = roman_value(m.group(2))
        if not n:
            return m.group(0)
        if m.group(1) in REGNAL_NAMES:
            return f"{m.group(1)} the {num2words(n, to='ordinal').capitalize()}"
        return f"{m.group(1)} {num2words(n)}"

    return re.sub(r"\b([A-Z][a-z]+)\s+([IVX]{2,6})\b(?![\w'])", regnal, text)


def spoken_chapter(ch, rules):
    title = re.sub(r"^\s*([\d.]+|\d+:|[IVXLC]+\.)\s+", "", ch.title)  # "2.1 Methods", "01: Coaching", "IV. Hod" -> title only
    if title in ("Opening", "Front matter"):
        title = ""  # our own label for text before the first heading, not something the book says
    return (speak_roman_numerals(apply_pronunciations(title, rules)),
            [speak_roman_numerals(apply_pronunciations(p, rules)) for p in ch.paragraphs])


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

_pipelines = {}


def get_pipeline(lang):
    """Load the voice model once per language and reuse it for every book in a queue."""
    if lang not in _pipelines:
        fix_espeak_data_path()
        from kokoro import KPipeline

        _pipelines[lang] = KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M", device="cpu")
    return _pipelines[lang]


def synthesize(book: Book, work: Path, voice: str, speed: float, lang: str, only: set | None, rules, verbose=False):
    import numpy as np
    import soundfile as sf
    from kokoro import KPipeline

    pipe = get_pipeline(lang)
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
        ch_chars, ch_done, last_report = sum(len(p) for p in spoken_paras) or 1, 0, 0.0
        for n, p in enumerate(spoken_paras, 1):
            if verbose and (n == 1 or time.time() - last_report >= 10):
                # every ~10 seconds: "  [p 12/340] 42% of chapter · 18% of book · about 6 h 10 min left"
                last_report = time.time()
                book_done = done_chars + len(ch.text) * ch_done / ch_chars
                pct_book = 100 * book_done / max(total_chars, 1)
                el = time.time() - start
                eta = f" · about {duration_words(el / book_done * (total_chars - book_done))} left" if el > 30 and book_done else ""
                print(f"  [p {n}/{len(spoken_paras)}] {100 * ch_done / ch_chars:.0f}% of chapter · "
                      f"{pct_book:.0f}% of book{eta}", flush=True)
            ch_done += len(p)
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


def duration_words(seconds):
    """3725 -> "1 h 2 min", 300 -> "5 min"."""
    minutes = round(seconds / 60)
    return f"{minutes // 60} h {minutes % 60} min" if minutes >= 60 else f"{max(minutes, 1)} min"


def wav_duration(path):
    import soundfile as sf

    return sf.info(str(path)).duration


GITHUB = "https://github.com/TechnAudioToolz/pdf-epub-to-audiobook"


def made_with(voice, speed):
    """Tag saying how the audio was made, saved in each file's comment."""
    return (f"Read by the Kokoro-82M voice {voice} at {speed:g}x speed. Made with Audiobook Maker "
            f"(free and open source): {GITHUB}")


def package_m4b(book: Book, work: Path, out: Path, bitrate: str, only: set | None, rules, comment="", chapters=True):
    wavs = [(i, chapter_wav(work, i, ch, rules)) for i, ch in enumerate(book.chapters, 1) if not only or i in only]
    wavs = [(i, w) for i, w in wavs if w.exists()]
    if not wavs:
        sys.exit("No audio was generated.")

    concat = work / "concat.txt"
    concat.write_text("".join(f"file '{w.name}'\n" for _, w in wavs))

    esc = lambda s: re.sub(r"([=;#\\\n])", r"\\\1", s)
    meta = [";FFMETADATA1", f"title={esc(book.title)}", f"artist={esc(book.author)}",
            f"album={esc(book.title)}", "genre=Audiobook", f"comment={esc(comment)}"]
    t = 0
    for i, w in wavs:
        d = int(wav_duration(w) * 1000)
        if chapters:
            meta += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={t}", f"END={t + d}",
                     f"title={esc(book.chapters[i - 1].title)}"]
        t += d
    (work / "chapters.txt").write_text("\n".join(meta) + "\n")

    cmd = [ffmpeg_exe(), "-y", "-loglevel", "error", "-stats",
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
    parts = f"{len(wavs)} chapters" if chapters else "one file, no chapter markers"
    print(f"\nWrote {out}  ({hrs:.1f} h, {parts}, {out.stat().st_size/1e6:.0f} MB)")


def package_mp3(book: Book, work: Path, out: Path, bitrate: str, only: set | None, rules, comment="", chapters=True):
    """One MP3 per chapter in the folder `out`, numbered so players keep them in order, with tags and cover."""
    wavs = [(i, chapter_wav(work, i, ch, rules)) for i, ch in enumerate(book.chapters, 1) if not only or i in only]
    wavs = [(i, w) for i, w in wavs if w.exists()]
    if not wavs:
        sys.exit("No audio was generated.")
    if not chapters:
        return package_one_mp3(book, work, out.with_suffix(".mp3"), bitrate, wavs, comment)
    partial = out.with_name(out.name + ".partial")  # an interrupted run never looks finished
    partial.mkdir(parents=True, exist_ok=True)
    cover = work / "cover.jpg"
    if book.cover:
        cover.write_bytes(book.cover)
    digits = max(2, len(str(len(book.chapters))))
    seconds = 0.0
    for n, (i, w) in enumerate(wavs, 1):
        title = book.chapters[i - 1].title
        safe = re.sub(r'[/:\\*?"<>|]+', "", title).strip()[:80]
        name = f"{i:0{digits}d} - {safe}.mp3"
        print(f"  MP3 {n}/{len(wavs)}: {name}", flush=True)
        cmd = [ffmpeg_exe(), "-y", "-loglevel", "error", "-i", w.name]
        if book.cover:
            cmd += ["-i", cover.name, "-map", "0:a", "-map", "1:v", "-c:v", "mjpeg",
                    "-disposition:v", "attached_pic", "-metadata:s:v", "comment=Cover (front)"]
        else:
            cmd += ["-map", "0:a"]
        tags = {"title": title, "artist": book.author, "album_artist": book.author, "album": book.title,
                "track": f"{i}/{len(book.chapters)}", "genre": "Audiobook", "comment": comment,
                "encoded_by": "Audiobook Maker"}
        for k, v in tags.items():
            cmd += ["-metadata", f"{k}={v}"]
        cmd += ["-c:a", "libmp3lame", "-b:a", bitrate, "-ac", "1", "-id3v2_version", "3", str(partial / name)]
        subprocess.run(cmd, check=True, cwd=work)
        seconds += wav_duration(w)
    if out.exists():  # --force: the old folder goes to the Trash, never deleted outright
        trash = Path.home() / ".Trash" / f"{out.name} {time.strftime('%H%M%S')}"
        shutil.move(str(out), str(trash))
    partial.rename(out)
    size = sum(f.stat().st_size for f in out.iterdir())
    print(f"\nWrote {out}  ({seconds / 3600:.1f} h, {len(wavs)} chapters as MP3 files, {size/1e6:.0f} MB)")


def package_one_mp3(book, work, out, bitrate, wavs, comment):
    """The whole book as a single MP3."""
    (work / "concat.txt").write_text("".join(f"file '{w.name}'\n" for _, w in wavs))
    cmd = [ffmpeg_exe(), "-y", "-loglevel", "error", "-stats", "-f", "concat", "-safe", "0", "-i", "concat.txt"]
    if book.cover:
        (work / "cover.jpg").write_bytes(book.cover)
        cmd += ["-i", "cover.jpg", "-map", "0:a", "-map", "1:v", "-c:v", "mjpeg",
                "-disposition:v", "attached_pic", "-metadata:s:v", "comment=Cover (front)"]
    else:
        cmd += ["-map", "0:a"]
    for k, v in {"title": book.title, "artist": book.author, "album_artist": book.author, "album": book.title,
                 "genre": "Audiobook", "comment": comment, "encoded_by": "Audiobook Maker"}.items():
        cmd += ["-metadata", f"{k}={v}"]
    cmd += ["-c:a", "libmp3lame", "-b:a", bitrate, "-ac", "1", "-id3v2_version", "3", str(out)]
    subprocess.run(cmd, check=True, cwd=work)
    hrs = sum(wav_duration(w) for _, w in wavs) / 3600
    print(f"\nWrote {out}  ({hrs:.1f} h, one file, no chapter markers, {out.stat().st_size/1e6:.0f} MB)")


# --------------------------------------------------------------------------- CLI

def parse_range(s):
    if not s:
        return None
    out = set()
    for part in s.split(","):
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out


BOOK_TYPES = (".pdf", ".epub", ".txt")
IMAGE_TYPES = (".jpg", ".jpeg", ".png", ".webp")


def expand_inputs(paths):
    """Files as given; folders become every PDF/EPUB/TXT directly inside them, in name order."""
    books = []
    for p in paths:
        if p.is_dir():
            books += sorted(f for f in p.iterdir() if f.suffix.lower() in BOOK_TYPES and not f.name.startswith("."))
        elif p.exists():
            books.append(p)
        else:
            print(f"Not found, skipping: {p}")
    return books


def find_cover(book_path):
    """covers/<book>.*, then an image next to the book (<book>.jpg, <book>-Cover.jpg; cover.jpg or folder.jpg
    only if the folder holds just this one book)."""
    stem = book_path.stem.strip()
    for ext in IMAGE_TYPES:
        if (PROJECT / "covers" / f"{stem}{ext}").exists():
            return PROJECT / "covers" / f"{stem}{ext}"
    # cover.jpg / folder.jpg belong to a folder, so they only count when the folder holds just this book
    books_here = sum(1 for f in book_path.parent.iterdir() if f.suffix.lower() in BOOK_TYPES and not f.name.startswith("."))
    generic = ("cover", "folder") if books_here <= 1 else ()
    for name in (stem, f"{stem}-Cover", f"{stem} cover") + generic:
        for ext in IMAGE_TYPES:
            for f in (book_path.with_name(name + ext), book_path.with_name(name + ext.upper())):
                if f.exists():
                    return f
    return None


def output_path(args, book, path):
    if args.output:
        out = args.output
    else:
        name = path.stem if args.name_from_file else (f"{book.author} - {book.title}" if book.author else book.title)
        folder = args.output_dir or PROJECT / "output"
        out = folder / (re.sub(r'[/:\\*?"<>|]+', "", name).strip() + ".m4b")
    out = out.resolve()  # ffmpeg runs inside the work dir, so a relative -o would land there
    if args.chapters:
        out = out.with_name(out.stem + ".preview.m4b")
    if args.format == "mp3":
        # a folder of MP3s, one per chapter; or one .mp3 for the whole book
        out = out.with_suffix(".mp3") if args.no_chapters else out.with_suffix("")
    return out


def notify(title, message):
    if sys.platform == "darwin":
        subprocess.run(["osascript", "-e", f"display notification {message!r} with title {title!r}"],
                       capture_output=True)


class Tee:
    """Mirror everything printed for one book into work/<book>/render.log (for status.sh / tail -f)."""

    def __init__(self, stream, path):
        self.stream, self.path, self.file = stream, path, None

    def write(self, data):
        self.stream.write(data)
        if self.file is None:  # opened on first output, so a skipped book keeps its old log
            self.file = open(self.path, "w")
        self.file.write(data)
        self.file.flush()

    def flush(self):
        self.stream.flush()

    def close(self):
        if self.file:
            self.file.close()


def cover_tools(path, args):
    """--cover-choices / --generate-cover for the app's cover picker. Quick: reads only the title, author and
    first pages, never the whole book."""
    folder = PROJECT / "work" / path.stem / "cover-choices"
    folder.mkdir(parents=True, exist_ok=True)
    ext = path.suffix.lower()
    title, author, own_cover, epub_pictures = None, None, None, []
    if ext == ".pdf":
        meta = import_pymupdf().open(str(path)).metadata or {}
        title, author = meta.get("title"), meta.get("author")
    elif ext == ".epub":
        from ebooklib import epub

        book = epub.read_epub(str(path), options={"ignore_ncx": True})
        meta = lambda k: (book.get_metadata("DC", k) or [("", {})])[0][0]
        title, author = meta("title"), meta("creator")
        own_cover = epub_cover(book)
        epub_pictures = [i.get_content() for i in epub_images(book)]
    title, author = title_and_author(title, author, path)
    book = Book(args.title or title, args.author or author, [], own_cover)
    if args.cover_choices:
        for f, label in cover_choices(path, book, folder, args.cover_choices, epub_pictures):
            print(f"Cover choice: {f}\t{label}")
    if args.generate_cover:
        f = folder / "generated.jpg"
        f.write_bytes(generated_cover(book.title, book.author))
        print(f"Cover choice: {f}\tGenerated")
    return "checked", "cover choices written"


def convert(path, args):
    """Convert one book. Returns (status, detail) where status is done / skipped / checked."""
    if args.cover_choices or args.generate_cover:
        return cover_tools(path, args)
    keep = set(KEEP_CHOICES) if args.read_all else {k.strip() for k in (args.keep or "").split(",") if k.strip()}
    book = load_book(path, academic=not args.fiction, keep=frozenset(keep))
    book.title = args.title or book.title
    book.author = args.author or book.author
    cover = args.cover or find_cover(path)
    if cover:
        book.cover = cover.read_bytes()
        book.cover_note = f"your image, {cover.name}" if args.cover else f"found {cover.name}"
    elif not book.cover:
        book.cover = generated_cover(book.title, book.author)
        book.cover_note = "generated from the title (no cover art in the book)"
    if not book.chapters:
        raise ValueError("No readable text found. If it's a scanned PDF, run it through OCR first "
                         "(brew install ocrmypdf && ocrmypdf --skip-text in.pdf out.pdf).")
    out = output_path(args, book, path)
    if out.exists() and not (args.force or args.dry_run or args.list_unknown):
        return "skipped", f"already exists: {out.name} (use --force to redo)"

    work = PROJECT / "work" / path.stem
    work.mkdir(parents=True, exist_ok=True)
    (work / "cleaned.txt").write_text(
        "\n\n".join(f"### {i}. {c.title}\n\n{c.text}" for i, c in enumerate(book.chapters, 1))
    )
    words = sum(len(c.text.split()) for c in book.chapters)
    print(f"{book.title} — {book.author or 'unknown author'}")
    print(f"{len(book.chapters)} chapters, {words:,} words, ~{words / 155 / 60 / args.speed:.1f} h of audio")
    for i, c in enumerate(book.chapters, 1):
        print(f"  {i:3d}. {c.title[:60]:60s} {len(c.text.split()):>7,} words")
    print(f"Cover: {book.cover_note}")
    (work / "cover-preview.jpg").write_bytes(book.cover)
    print(f"Cover image: {work / 'cover-preview.jpg'}")
    print(f"Cleaned text: {work / 'cleaned.txt'}")
    rules = load_pronunciations(book=path.stem)
    lang = args.lang or args.voice.strip()[0]
    if rules:
        hits = sum(len(pat.findall(c.text)) for pat, _, _ in rules for c in book.chapters)
        extra = book_pronunciations_path(path.stem)
        src = f"{PRONUNCIATIONS.name}" + (f" + {extra.relative_to(PROJECT)}" if extra.exists() else "")
        print(f"Pronunciations: {len(rules)} rules from {src}, {hits} uses in this book")
    if args.list_unknown:
        unknown = list_unknown_words(book, rules, lang)
        (work / "unknown_words.txt").write_text("".join(f"{w}\t{n}\n" for w, n in unknown.most_common()))
        print(f"\n{len(unknown)} words Kokoro will have to guess (most frequent first):")
        print("  " + ", ".join(f"{w} ({n})" for w, n in unknown.most_common(60)))
        print(f"Full list: {work / 'unknown_words.txt'}")
        print('Hear one with: .venv/bin/python say.py "word"')
        return "checked", f"{len(unknown)} guessed words"
    if args.dry_run:
        return "checked", f"{len(book.chapters)} chapters, {words:,} words"

    only = parse_range(args.chapters)
    # Cache audio per voice+speed so switching voices never reuses another voice's chapters.
    audio = work / f"audio_{args.voice.replace(',', '+')}_{args.speed:g}"
    audio.mkdir(exist_ok=True)
    synthesize(book, audio, args.voice, args.speed, lang, only, rules, args.verbose)
    out.parent.mkdir(parents=True, exist_ok=True)
    package = package_mp3 if args.format == "mp3" else package_m4b
    package(book, audio, out, args.bitrate, only, rules, made_with(args.voice, args.speed), chapters=not args.no_chapters)
    return "done", out.name


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", type=Path, help="PDF, EPUB or TXT files, and/or folders of them")
    ap.add_argument("-o", "--output", type=Path,
                    help="output .m4b, single book only (default: output/<Author> - <Title>.m4b in the project)")
    ap.add_argument("--output-dir", type=Path, help="folder for finished audiobooks (default: output/ in the project)")
    ap.add_argument("--name-from-file", action="store_true",
                    help="name each output after its input file (output/<file name>.m4b)")
    ap.add_argument("--force", action="store_true", help="redo books whose output already exists")
    ap.add_argument("--voice", default="af_alloy",
                    help="Kokoro voice (default af_alloy): af_heart, af_bella, am_michael, bf_emma, bm_george, bm_lewis, ... "
                         "(blend with 'af_heart,bm_george')")
    ap.add_argument("--speed", type=float, default=1.0, help="speaking rate, e.g. 0.9 or 1.15")
    ap.add_argument("--lang", choices=["a", "b"], help="a = American, b = British (default: from voice)")
    ap.add_argument("--chapters", help="only these chapters, e.g. '1-3,7' (handy for previews)")
    ap.add_argument("--fiction", action="store_true",
                    help="skip academic cleanup (citations, abbreviations, footnotes, captions)")
    ap.add_argument("--cover", type=Path,
                    help="cover image, single book only (default: covers/<book>.*, an image next to the book, "
                         "or the book's own cover)")
    ap.add_argument("--cover-choices", type=int, metavar="N",
                    help="write the first N pages to work/<book>/cover-choices, then stop (the app's cover picker)")
    ap.add_argument("--generate-cover", action="store_true",
                    help="write a cover generated from the title and author to work/<book>/cover-choices, then stop")
    ap.add_argument("--title", help="override book title (single book only)")
    ap.add_argument("--author", help="override author (single book only)")
    ap.add_argument("--format", choices=["m4b", "mp3"], default="m4b",
                    help="m4b: one audiobook file with chapters (default); mp3: a folder with one MP3 per chapter")
    ap.add_argument("--no-chapters", action="store_true",
                    help="one continuous file without chapter markers (M4B), or a single MP3 instead of one per chapter")
    ap.add_argument("--bitrate", default="64k", help="audio bitrate (64k is plenty for mono speech)")
    ap.add_argument("--keep", metavar="LIST",
                    help="also read things the cleanup skips, comma-separated: " + ", ".join(KEEP_CHOICES)
                         + " (e.g. --keep page-numbers,footnotes)")
    ap.add_argument("--read-all", action="store_true", help="read everything on the page (all of --keep)")
    ap.add_argument("--dry-run", action="store_true", help="list chapters and write cleaned text, no audio")
    ap.add_argument("--list-unknown", action="store_true",
                    help="list words Kokoro doesn't know (likely mispronounced), then stop")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="every ~10 seconds, print how far into the chapter and book it is, and the time left")
    ap.add_argument("--no-notify", action="store_true", help="no Mac notification when each book finishes")
    args = ap.parse_args()
    global PROGRESS
    PROGRESS = args.verbose
    unknown = {k.strip() for k in (args.keep or "").split(",") if k.strip()} - set(KEEP_CHOICES)
    if unknown:
        ap.error(f"--keep: unknown {', '.join(sorted(unknown))} (choose from {', '.join(KEEP_CHOICES)})")

    if not ffmpeg_exe():
        sys.exit("ffmpeg is required: pip install imageio-ffmpeg (or brew install ffmpeg)")
    voices = [v.strip() for v in args.voice.split(",")]
    stay_offline_if_downloaded("hexgrad/Kokoro-82M", ["config.json", "kokoro-v1_0.pth"] + [f"voices/{v}.pt" for v in voices])
    books = expand_inputs(args.inputs)
    if not books:
        sys.exit("No PDF, EPUB or TXT files found.")
    if len(books) > 1 and (args.output or args.cover or args.title or args.author):
        sys.exit("-o, --cover, --title and --author apply to one book only. For a queue, name covers\n"
                 "covers/<book file name>.jpg (or put them next to the books) and use --name-from-file.")

    rendering = not (args.dry_run or args.list_unknown)
    results = []
    for n, path in enumerate(books, 1):
        if len(books) > 1:
            print(f"\n{'=' * 70}\n[{n}/{len(books)}] {path.name}\n{'=' * 70}", flush=True)
        start = time.time()
        tee = None
        if rendering:
            (PROJECT / "work" / path.stem).mkdir(parents=True, exist_ok=True)
            tee = Tee(sys.stdout, PROJECT / "work" / path.stem / "render.log")
            sys.stdout = tee
        try:
            status, detail = convert(path, args)
        except Exception as e:  # one bad book shouldn't stop the queue
            import traceback

            traceback.print_exc()
            status, detail = "failed", f"{type(e).__name__}: {e}"
        finally:
            if tee:
                sys.stdout = tee.stream
                tee.close()
        minutes = (time.time() - start) / 60
        results.append((path.name, status, detail, minutes))
        if status == "skipped":
            print(f"Skipped {path.name}: {detail}")
        if rendering and status in ("done", "failed") and not args.no_notify:
            notify("Audiobook finished" if status == "done" else "Audiobook problem",
                   f"{path.stem} {'is ready' if status == 'done' else 'failed'}")

    if len(books) > 1:
        print(f"\n{'=' * 70}\nSummary")
        for name, status, detail, minutes in results:
            print(f"  {status.upper():8s} {name[:50]:50s} {minutes:6.1f} min  {detail}")
    if any(status == "failed" for _, status, _, _ in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
