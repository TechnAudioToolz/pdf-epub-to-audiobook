#!/usr/bin/env bash
# Build "Audiobook Maker.app" for macOS 13+ on Apple Silicon, signed locally (no Apple Developer account).
#   ./build.sh            -> app/build/Audiobook Maker.app
#   ./build.sh --open     -> build, then launch it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Audiobook Maker.app"
swift build -c release --arch arm64 -Xswiftc -target -Xswiftc arm64-apple-macos13.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/AudiobookMaker "$APP/Contents/MacOS/AudiobookMaker"
cp Resources/donate.html "$APP/Contents/Resources/"   # QR codes are embedded in it: swift make_qr.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # redraw with: swift make_icon.swift

# Everything first-launch setup needs: the tool scripts, the installer, and uv (installs Python + libraries).
mkdir -p "$APP/Contents/Resources/engine" "$APP/Contents/Resources/bin"
for f in audiobook.py say.py voices.py audio2m4b.py requirements.txt pronunciations.txt install_engine.sh; do
  cp "../$f" "$APP/Contents/Resources/engine/"
done
UV_BIN="$(command -v uv || true)"
[ -x ../.venv/bin/uv ] && UV_BIN=../.venv/bin/uv
[ -n "$UV_BIN" ] || { echo "uv not found: run ../.venv/bin/python -m pip install uv"; exit 1; }
cp "$UV_BIN" "$APP/Contents/Resources/bin/uv"
# Text recognition for scanned PDFs (the Mac's built-in Live Text engine); also to ../bin for command-line use.
swiftc -O -target arm64-apple-macos13.0 ocr.swift -o "$APP/Contents/Resources/bin/ocr"
mkdir -p ../bin && cp "$APP/Contents/Resources/bin/ocr" ../bin/ocr
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Signature. With a self-signed "Audiobook Maker Dev" code-signing certificate in your Keychain, every
# build carries the same identity, so firewalls like Little Snitch (and macOS) recognise rebuilds as
# the same app. Without it, an ad-hoc signature is used, which changes on every build.
# Another Mac asks once either way: System Settings > Privacy and Security > Open Anyway.
SIGN_ID="${SIGN_ID:-Audiobook Maker Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --deep --sign "$SIGN_ID" "$APP"
  echo "Signed with: $SIGN_ID"
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad-hoc (create a \"$SIGN_ID\" code-signing certificate for a stable identity)"
fi

echo "Built: $(pwd)/$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
