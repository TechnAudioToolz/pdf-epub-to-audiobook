#!/usr/bin/env bash
# Installs the audiobook tools into a folder, self-contained: its own Python, libraries, ffmpeg and
# voice model. No Homebrew, no system Python. The Mac app runs this on first launch.
#
#   UV=/path/to/uv ./install_engine.sh "<target folder>"
#
# Prints "STEP n/6 <what>" lines for the app's progress screen, then "DONE" or "FAILED <reason>".
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?usage: install_engine.sh <target folder>}"
UV="${UV:-uv}"
STEPS=6
step() { echo "STEP $1/$STEPS $2"; }
trap 'echo "FAILED during: ${CURRENT:-setup}"' ERR

# Keep everything uv downloads inside the target folder, and never use another Python on this Mac.
export UV_PYTHON_INSTALL_DIR="$TARGET/python"
export UV_CACHE_DIR="$TARGET/.uv-cache"
export UV_PYTHON_PREFERENCE=only-managed
export UV_NO_PROGRESS=1

CURRENT="copying the tools"; step 1 "Copying the tools"
mkdir -p "$TARGET/bin" "$TARGET/output" "$TARGET/work" "$TARGET/pronunciations" "$TARGET/covers"
cp "$SRC"/audiobook.py "$SRC"/say.py "$SRC"/voices.py "$SRC"/audio2m4b.py "$SRC"/requirements.txt "$TARGET/"
[ -f "$TARGET/pronunciations.txt" ] || cp "$SRC/pronunciations.txt" "$TARGET/"   # keep the user's own edits

CURRENT="installing Python"; step 2 "Installing Python 3.12 (about 20 MB)"
[ -x "$TARGET/.venv/bin/python" ] || "$UV" venv --quiet --python 3.12 "$TARGET/.venv"
PY="$TARGET/.venv/bin/python"

CURRENT="installing the speech engine"; step 3 "Installing the speech engine (the biggest step, about 1 GB)"
"$UV" pip install --quiet --python "$PY" -r "$TARGET/requirements.txt"

CURRENT="installing the English language model"; step 4 "Installing the English language model"
"$UV" pip install --quiet --python "$PY" \
  "en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

CURRENT="setting up ffmpeg"; step 5 "Setting up the audio tools"
ln -sf "$("$PY" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')" "$TARGET/bin/ffmpeg"
"$TARGET/bin/ffmpeg" -hide_banner -version > /dev/null

CURRENT="downloading the voice model"; step 6 "Downloading the voice model and English voices (about 340 MB)"
"$PY" - <<'EOF'
import warnings
warnings.filterwarnings("ignore")
from huggingface_hub import snapshot_download
snapshot_download("hexgrad/Kokoro-82M",
                  allow_patterns=["config.json", "kokoro-v1_0.pth", "voices/af_*", "voices/am_*", "voices/bf_*", "voices/bm_*"])
EOF

rm -rf "$UV_CACHE_DIR"   # downloaded packages are installed now; the cache is ~1 GB of duplicates
date "+%Y-%m-%d %H:%M" > "$TARGET/.installed"
echo "DONE"
