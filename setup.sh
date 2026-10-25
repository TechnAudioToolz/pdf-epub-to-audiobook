#!/usr/bin/env bash
# One-time setup on macOS: system tools, a Python 3.12 virtualenv, and the spaCy English model.
set -euo pipefail
cd "$(dirname "$0")"

command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
for pkg in python@3.12 ffmpeg espeak-ng; do
  brew list --versions "$pkg" >/dev/null || brew install "$pkg"
done

PY="$(brew --prefix python@3.12)/bin/python3.12"
[ -d .venv ] || "$PY" -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m spacy download en_core_web_sm

echo
echo "Ready. Try:  .venv/bin/python audiobook.py book.epub --dry-run"
