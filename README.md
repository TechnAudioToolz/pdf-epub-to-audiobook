# PDF / EPUB → Audiobook (local, offline)

Converts a PDF, EPUB or TXT into a chaptered `.m4b` audiobook using [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) TTS on your Mac.
Nothing leaves the machine after the one-time model download (~330 MB).

**Why:** to help people take in knowledge by listening instead of reading, especially people with dyslexia, and anyone who learns best on the go: walking, driving, working with their hands. Any book or paper you have can become an audiobook, privately and for free.

On an M1 Pro it runs at about **5.5× realtime** on CPU, so a 6.6-hour book takes about 72 minutes.

## Install (macOS, Apple Silicon)

```bash
git clone https://github.com/TechnAudioToolz/pdf-epub-to-audiobook.git && cd pdf-epub-to-audiobook
./setup.sh    # installs python@3.12, ffmpeg, espeak-ng via Homebrew, then a .venv with pinned deps
```

## Usage

```bash
# 1. Check chapters and the cleaned text first (fast, no audio)
.venv/bin/python audiobook.py book.pdf --dry-run

# 2. Render a 1-chapter preview to check the voice
.venv/bin/python audiobook.py book.pdf --chapters 2 --voice bm_george

# 3. Render the whole book (resumable: Ctrl-C and rerun picks up where it stopped)
.venv/bin/python audiobook.py book.pdf
```

Everything is written inside this project folder, wherever the input file lives. The input is only read.

- The finished book goes to `output/<Author> - <Title>.m4b`.
- Working files go to `work/<book>/`: per-chapter WAVs cached per voice, `cleaned.txt` and chapter metadata. Once you're happy with the result, move that folder to the Trash.

## Options

| Flag | Meaning |
|---|---|
| `--voice` | `af_alloy` (default, US female), `af_heart`, `af_bella`, `am_michael`, `am_fenrir`, `bf_emma`, `bf_isabella`, `bm_george`, `bm_lewis`, ... Blend two voices with `af_heart,bm_george` |
| `--speed` | `0.9` slower, `1.15` faster |
| `--chapters` | Render only some chapters, e.g. `1-3,7`. Output is `*.preview.m4b` |
| `--fiction` | Turn off the academic cleanup (citation and abbreviation rewriting, footnote and caption removal) |
| `--title`, `--author` | Override bad metadata |
| `--bitrate` | AAC bitrate, default `64k` (mono speech) |

## What the cleanup does (PDF)

- Uses the PDF's bookmarks for chapters. Without bookmarks it falls back to large or bold headings.
- Removes running headers and footers, page numbers, footnotes (small text at the bottom of the page), superscript markers, tables, and figure/table captions.
- Reads two-column layouts left column first, then right.
- Joins paragraphs split across pages and words hyphenated across lines.
- Strips citations such as `[3, 5–7]` and `(Smith et al., 2020)`, plus URLs and emails.
- Expands abbreviations: `e.g.` → "for example", `i.e.` → "that is", `Fig.` → "Figure", `et al.` → "and colleagues".
- Skips References, Bibliography, Index, Contents, Acknowledgments and Appendices.

Always skim `work/<book>/cleaned.txt` after a `--dry-run`. It contains exactly what will be spoken.

## Limits

- **Scanned PDFs** have no text layer. OCR them first: `brew install ocrmypdf && ocrmypdf --skip-text in.pdf out.pdf`
- **Math and equations** come out garbled. Kokoro can't read LaTeX-style math.
- The Apple GPU (MPS) backend crashes on long sentences in PyTorch, so synthesis runs on CPU.

## Picking a voice

```bash
.venv/bin/python voices.py                                   # all 28 English voices
.venv/bin/python voices.py --text "A line from your book."   # your own test sentence
```

This writes `voice_samples/index.html`, a page with a player for each voice. It also writes `voice_samples/all_voices.m4b`, which has one chapter per voice, so you can skip chapters in Apple Books or BookPlayer to compare voices.

## Existing MP3 audiobook → chaptered M4B

`audio2m4b.py` converts an audiobook you already have, for example a single 14-hour MP3, into an M4B with real chapter markers. It finds the chapters itself, fully offline:

```bash
# 1. Find chapters. It listens to the pause before each chapter with a local Whisper model.
#    --toc (optional) takes exact titles from the book's PDF/EPUB bookmarks.
.venv/bin/python audio2m4b.py detect book.mp3 --toc book.pdf

# 2. Check work/<book>/chapters.tsv. Each line is "HH:MM:SS.mmm<TAB>Title". Fix or add lines as needed.

# 3. Build
.venv/bin/python audio2m4b.py build book.mp3 --cover cover.jpg --narrator "Name"
```

Chapter breaks in commercial audiobooks are about 3 s pauses where the narrator says "Chapter N …". With `--toc`, the tool lines the book's table of contents up against every pause in order. It tolerates Whisper misspelling unusual names, so it can match a title like "Kether" even when Whisper hears "chatter". It also reports any chapter it couldn't place, so you know what to check.

## Acknowledgements

This project mostly connects other people's excellent open-source work. The real credit belongs to:

| Project | What it does here | License |
|---|---|---|
| [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), [kokoro](https://github.com/hexgrad/kokoro) and [misaki](https://github.com/hexgrad/misaki) by hexgrad | The voices and speech synthesis | Apache 2.0 |
| [PyTorch](https://pytorch.org) | Runs the voice model | BSD-style |
| [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (SYSTRAN), using OpenAI's [Whisper](https://github.com/openai/whisper) models | Hears chapter titles in existing audiobooks | MIT |
| [PyMuPDF](https://github.com/pymupdf/PyMuPDF) (Artifex) | Reads PDFs | AGPL-3.0 |
| [EbookLib](https://github.com/aerkalov/ebooklib) | Reads EPUBs | AGPL-3.0 |
| [Beautiful Soup](https://www.crummy.com/software/BeautifulSoup/) | Parses EPUB HTML | MIT |
| [spaCy](https://spacy.io) (Explosion) | Sentence and word analysis for pronunciation | MIT |
| [eSpeak NG](https://github.com/espeak-ng/espeak-ng) and [phonemizer](https://github.com/bootphon/phonemizer) | Pronunciation of unusual words | GPL-3.0 |
| [FFmpeg](https://ffmpeg.org) | Audio encoding, chapters, cover art | LGPL/GPL |
| [NumPy](https://numpy.org), [soundfile](https://github.com/bastibe/python-soundfile) | Audio data handling | BSD |

Written with the help of [Claude](https://claude.com/claude-code) (Anthropic).

If this project helps you, please consider supporting the projects above as well.
