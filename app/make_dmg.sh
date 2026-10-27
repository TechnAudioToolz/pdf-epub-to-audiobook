#!/usr/bin/env bash
# Packages the built app into "Audiobook Maker.dmg": the app, an Applications shortcut to drag it
# onto, and a short note on opening an app that isn't from the App Store.
#   ./build.sh && ./make_dmg.sh     -> build/Audiobook Maker.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Audiobook Maker.app"
DMG="build/Audiobook Maker.dmg"
[ -d "$APP" ] || { echo "Build the app first: ./build.sh"; exit 1; }

STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open.txt" <<'EOF'
Audiobook Maker

1. Drag "Audiobook Maker" onto the Applications folder.
2. Open it from Applications.

The first time, macOS may say it can't check the app for malicious software. That's because
this free app isn't registered with Apple. To open it anyway:

   System Settings > Privacy and Security > scroll down > "Open Anyway"

You only need to do this once.

On first launch the app downloads its voice engine (about 1.3 GB, one time). After that it
works offline, and your books never leave your Mac.

Needs macOS 13 Ventura or newer, on a Mac with Apple Silicon (M1 or later).
EOF

hdiutil create -volname "Audiobook Maker" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
echo "Built: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
