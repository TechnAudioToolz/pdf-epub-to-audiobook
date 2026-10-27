#!/usr/bin/env bash
# Builds the offline edition: the app with everything first-launch setup would otherwise download
# (Python 3.12, the libraries, the English language model, the voice model and the 28 English
# voices) inside it, so it installs on a Mac with no internet connection.
#   ./build.sh && ./make_offline_dmg.sh     -> build/Audiobook Maker (offline).dmg
# The downloaded parts are kept in build/offline-payload and reused; move it to the Trash to fetch fresh ones.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Audiobook Maker.app"
PAYLOAD="$(pwd)/build/offline-payload"
UV="$(pwd)/../.venv/bin/uv"
SPACY_MODEL="https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
[ -d "$APP" ] || { echo "Build the app first: ./build.sh"; exit 1; }

if [ ! -f "$PAYLOAD/.complete" ]; then
  echo "Gathering the offline payload (downloads about 1 GB once)…"
  ENV="$(pwd)/build/offline-env"   # a throwaway Python used to build and check the wheels
  rm -rf "$PAYLOAD" "$ENV"
  export UV_PYTHON_INSTALL_DIR="$PAYLOAD/python" UV_PYTHON_PREFERENCE=only-managed
  export UV_CACHE_DIR="$(pwd)/build/offline-uv-cache" UV_NO_PROGRESS=1
  "$UV" python install --no-bin 3.12   # --no-bin: put nothing in ~/.local/bin
  "$UV" venv --quiet --seed --python 3.12 "$ENV"
  # Every library as a wheel. Anything compiled here must also run on macOS 13.
  PIP_NO_CACHE_DIR=1 MACOSX_DEPLOYMENT_TARGET=13.0 "$ENV/bin/python" -m pip wheel --quiet -w "$PAYLOAD/wheels" -r ../requirements.txt "$SPACY_MODEL"
  # Install from the wheels alone, as the app will, to prove nothing is missing.
  # (from inside the folder: uv reads a "#" in a --find-links path as a URL fragment)
  (cd "$PAYLOAD/wheels" && "$UV" pip install --quiet --python "$ENV/bin/python" --offline --no-index --find-links . \
    -r "$OLDPWD/../requirements.txt" en_core_web_sm==3.8.0)
  HF_HOME="$PAYLOAD/huggingface" "$ENV/bin/python" - <<'EOF'
import warnings
warnings.filterwarnings("ignore")
from huggingface_hub import snapshot_download
snapshot_download("hexgrad/Kokoro-82M",
                  allow_patterns=["config.json", "kokoro-v1_0.pth", "voices/af_*", "voices/am_*", "voices/bf_*", "voices/bm_*"])
EOF
  # keep only the model files, not Hugging Face's lock files
  rm -rf "$PAYLOAD/huggingface/xet" "$PAYLOAD/huggingface/hub/.locks" "$PAYLOAD/huggingface/token"
  find "$PAYLOAD/huggingface" -name "*.lock" -delete
  chmod -R u+w "$PAYLOAD"   # Hugging Face stores its files read-only, which hdiutil can't copy
  rm -rf "$ENV" "$UV_CACHE_DIR"
  # uv's bookkeeping, including a link that points into this build folder; the installer recreates it
  rm -rf "$PAYLOAD/python/cpython-3.12-macos-aarch64-none" "$PAYLOAD/python/.lock" "$PAYLOAD/python/.temp"
  touch "$PAYLOAD/.complete"
fi

# The app, with the payload inside it.
OUT="build/offline"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$APP" "$OUT/Audiobook Maker.app"
ditto "$PAYLOAD" "$OUT/Audiobook Maker.app/Contents/Resources/offline"
rm -f "$OUT/Audiobook Maker.app/Contents/Resources/offline/.complete"
SIGN_ID="${SIGN_ID:-Audiobook Maker Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --deep --sign "$SIGN_ID" "$OUT/Audiobook Maker.app"
else
  codesign --force --deep --sign - "$OUT/Audiobook Maker.app"
fi
codesign --verify --deep "$OUT/Audiobook Maker.app"

APP="$OUT/Audiobook Maker.app" DMG="build/Audiobook Maker (offline).dmg" OFFLINE=1 ./make_dmg.sh
rm -rf "$OUT"
