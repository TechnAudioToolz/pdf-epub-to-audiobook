# PDF / EPUB → Audiobook (local, offline)

Converts a PDF, EPUB or TXT into a chaptered `.m4b` audiobook using [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) TTS on your Mac.
Nothing leaves the machine after the one-time model download (~330 MB).

**Why:** to help people take in knowledge by listening instead of reading, especially people with dyslexia, and anyone who learns best on the go: walking, driving, working with their hands. Any book or paper you have can become an audiobook, privately and for free.

On an M1 Pro it runs at about **5.5× realtime** on CPU, so a 6.6-hour book takes about 72 minutes.

## Download the Mac app

**[Audiobook Maker for Mac: latest release](https://github.com/TechnAudioToolz/pdf-epub-to-audiobook/releases/latest)** (early preview)

- Needs **macOS 13 Ventura or newer** on a Mac with **Apple Silicon** (M1 or later).
- Open the `.dmg` and drag **Audiobook Maker** to Applications.
- The app isn't registered with Apple, so the first time macOS blocks it: go to **System Settings → Privacy and Security** and click **Open Anyway**. You only do this once.
- On first launch it downloads its voice engine (about 1.3 GB, one time). After that it works offline and your books never leave your Mac.
- **No internet on that Mac, or a slow connection?** Download **`Audiobook-Maker-0.1-offline.dmg`** from the same release instead (about 660 MB). Python, the libraries and all 28 English voices are inside it, so setup takes seconds and needs no connection.

Drag in PDFs, EPUBs or text files, check the chapters, pick one of 28 voices, fix any mispronounced words, and render a queue of audiobooks with chapters and covers. Everything below is the command-line version of the same tools.

![Audiobook Maker: a queue of books on the left, the selected book's cover, voice and chapters on the right](docs/screenshots/main-light.png)

| | |
|---|---|
| ![Dark mode](docs/screenshots/main-dark.png) **Dark mode** | ![First launch: setup downloads the voice engine once](docs/screenshots/first-launch.png) **First launch:** a one-time setup |
| ![Book panel: cover, voice, chapters and words to check](docs/screenshots/book-panel.png) **Book panel:** chapters and words to check | ![Voice settings](docs/screenshots/settings-voice.png) **Settings:** voice, speed and pronunciation lists |
| ![General settings](docs/screenshots/settings-general.png) **Settings:** where audiobooks are saved | ![About window with credits](docs/screenshots/about.png) **About:** credits for every project it builds on |

*Screenshots use public-domain books with generated covers. They're made by the app itself: `open "app/build/Audiobook Maker.app" --args -screenshots docs/screenshots`.*

## Install the command-line tools (macOS, Apple Silicon)

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

- The finished book goes to `output/<Author> - <Title>.m4b` (or `output/<file name>.m4b` with `--name-from-file`).
- Working files go to `work/<book>/`: per-chapter WAVs cached per voice, `cleaned.txt`, chapter metadata and `render.log`. Once you're happy with the result, move that folder to the Trash.

## Converting many books (queue)

Give it several files, a whole folder, or both. Books render one after another:

```bash
.venv/bin/python audiobook.py "/path/to/My Books/" --name-from-file
.venv/bin/python audiobook.py book1.pdf book2.epub "/path/to/More Books/"
```

- **Covers are found automatically**, in this order: `covers/<book file name>.jpg|png|webp` in this project, then an image next to the book (`<book>.jpg`, `<book>-Cover.jpg`, `cover.jpg` or `folder.jpg`), then the book's own first page.
- **Finished books are skipped**, so re-running a folder only converts the new ones. `--force` redoes them. Interrupted books resume from the last finished chapter.
- **One bad file doesn't stop the queue.** It's marked FAILED in the summary at the end.
- **A Mac notification** appears as each book finishes (`--no-notify` turns it off).
- **Watch progress** with `./status.sh`, or `tail -f work/<book>/render.log`.

Long queues can run for hours. To keep one going after you close the terminal, start it detached and keep the Mac awake:

```bash
nohup caffeinate -i .venv/bin/python audiobook.py "/path/to/My Books/" --name-from-file > queue.log 2>&1 &
```

## Options

| Flag | Meaning |
|---|---|
| `--voice` | `af_alloy` (default, US female), `af_heart`, `af_bella`, `am_michael`, `am_fenrir`, `bf_emma`, `bf_isabella`, `bm_george`, `bm_lewis`, ... Blend two voices with `af_heart,bm_george` |
| `--speed` | `0.9` slower, `1.15` faster |
| `--chapters` | Render only some chapters, e.g. `1-3,7`. Output is `*.preview.m4b` |
| `--fiction` | Turn off the academic cleanup (citation and abbreviation rewriting, footnote and caption removal) |
| `--name-from-file` | Name each output after its input file |
| `--force` | Redo books whose output already exists |
| `--cover` | Cover image (single book only; queues find covers automatically) |
| `--title`, `--author`, `-o` | Override bad metadata or the output path (single book only) |
| `--list-unknown` | List the words Kokoro has to guess, then stop |
| `--keep LIST` | Also read things the cleanup skips, comma-separated: `page-numbers`, `headers`, `footnotes`, `tables`, `captions`, `citations`, `links`, `extras` (copyright, contents, references, index, about the author). In the app these are the **Also read** checkboxes |
| `--read-all` | Read everything on the page (all of `--keep`) |
| `--format mp3` | A folder with one numbered MP3 per chapter (tagged, with cover) instead of one M4B |
| `--bitrate` | Audio bitrate, default `64k` (mono speech) |

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

## Fixing pronunciations

Names like *Kether*, *Malkuth* or *Enoch* sometimes come out wrong. Fix them once in `pronunciations.txt` and the fix applies to every book:

```text
Enoch = /ˈinɪk/          # exact phonemes (most reliable)
Qliphoth = Klip-oth      # or a sound-alike spelling
```

```bash
.venv/bin/python audiobook.py book.pdf --list-unknown   # words Kokoro has to guess: review these first
.venv/bin/python say.py "the teacher of Enoch"          # hear it with your current rules
.venv/bin/python say.py "Enoch" --raw                   # hear it without them, to compare
```

`say.py` prints the phonemes it used, so you can copy them into `pronunciations.txt` and adjust. Chapter audio is cached by its exact spoken text, so re-running `audiobook.py` after a change re-renders only the chapters that contain that word.

## Mac app (demo)

A simple window for everything above: drag in books, check chapters, pick a voice, fix words, and render a queue. It needs macOS 13 Ventura or newer on Apple Silicon, and the tools installed with `./setup.sh`.

```bash
app/build.sh --open      # builds "Audiobook Maker.app" into app/build/ and opens it
app/make_dmg.sh          # packages it as app/build/Audiobook Maker.dmg (drag-to-Applications installer)
```

- **Add books:** drag PDFs, EPUBs or folders onto the window, or use **Add books**. Each one is checked right away for title, author and chapters.
- **Book panel:** drop a cover image, edit the title or author, choose a voice and **Listen**. **Words to check** lists words the voice will guess; listen to each one, type a sound-alike spelling and **Save** to add a rule for that book.
- **Start queue** renders the books one after another with progress. **Pause** (⌘P) freezes the render, using no CPU, until **Resume**. **Stop** keeps finished chapters.
- **Log** (⌘L) shows what the engine is doing: each chapter, and each paragraph as it's read (`--verbose` on the command line).
- **Donate** opens the support page.
- **Settings** (⌘, or the gear button): where finished audiobooks are saved, file names (book file name or Author - Title), notifications, what else to read (page numbers, headers, footnotes and so on), M4B or one MP3 per chapter, default voice and speed, pronunciation lists, and the tools folder.

**On a Mac without this project folder**, the app sets itself up on first launch: it downloads its own Python, the libraries, ffmpeg and the voice model into `~/Library/Application Support/Audiobook Maker/` (about 1.3 GB, one time, no Homebrew needed), and saves audiobooks to `~/Audiobooks`. After that it runs offline: the app runs the engine with networking switched off (macOS `sandbox-exec`), so no library it uses can reach the internet. One of them, Microsoft's onnxruntime (loaded by PyMuPDF), would otherwise report usage to Microsoft; the command-line tools switch that reporting off too. The same installer can be run by hand: `UV=uv ./install_engine.sh <folder>`.

**Offline edition:** `cd app && ./build.sh && ./make_offline_dmg.sh` builds `build/Audiobook Maker (offline).dmg`, with everything first-launch setup would download stored inside the app (`Contents/Resources/offline`: Python, the libraries as wheels, and the Kokoro model with the English voices). When the installer finds that folder it copies from it instead of downloading. The downloaded parts are kept in `app/build/offline-payload`, so later builds take about a minute.

On a developer Mac the app is a front end only. It runs `audiobook.py` and `say.py` from the project folder it was built in, and its audiobooks go to `output/`. It's signed locally, without a paid Apple Developer account. On another Mac, the first launch is blocked once: open System Settings → Privacy and Security → Open Anyway.
