# PDF / EPUB → Audiobook (local, offline)

Converts a PDF, EPUB or TXT into a chaptered `.m4b` audiobook using [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) TTS on your Mac.
Nothing leaves the machine after the one-time model download (~330 MB).

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
