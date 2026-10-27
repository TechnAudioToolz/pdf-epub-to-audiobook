#!/usr/bin/env bash
# Packages the built app into "Audiobook Maker.dmg": the app, an Applications shortcut to drag it
# onto, and a short note on opening an app that isn't from the App Store.
#   ./build.sh && ./make_dmg.sh     -> build/Audiobook Maker.dmg
# make_offline_dmg.sh calls it with APP, DMG and OFFLINE=1 set.
set -euo pipefail
cd "$(dirname "$0")"

APP="${APP:-build/Audiobook Maker.app}"
DMG="${DMG:-build/Audiobook Maker.dmg}"
[ -d "$APP" ] || { echo "Build the app first: ./build.sh"; exit 1; }

STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ "${OFFLINE:-}" = 1 ]; then
  SETUP="This is the offline edition: Python, the libraries and all 28 English voices are inside the
app, so first-launch setup needs no internet connection (about 2 minutes, 1.3 GB of disk space).
Your books never leave your Mac."
else
  SETUP="On first launch the app downloads its voice engine (about 1.3 GB, one time). After that it
works offline, and your books never leave your Mac."
fi
cat > "$STAGE/How to open.txt" <<EOF
Audiobook Maker

1. Drag "Audiobook Maker" onto the Applications folder.
2. Open it from Applications.

The first time, macOS may say it can't check the app for malicious software. That's because
this free app isn't registered with Apple. To open it anyway:

   System Settings > Privacy and Security > scroll down > "Open Anyway"

You only need to do this once.

$SETUP

Needs macOS 13 Ventura or newer, on a Mac with Apple Silicon (M1 or later).
EOF

hdiutil create -volname "Audiobook Maker" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
echo "Built: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
