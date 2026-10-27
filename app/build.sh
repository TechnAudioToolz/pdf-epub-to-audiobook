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
cp Resources/donate.html "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: runs on this Mac. Another Mac asks once:
# System Settings > Privacy and Security > Open Anyway.
codesign --force --deep --sign - "$APP"

echo "Built: $(pwd)/$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
