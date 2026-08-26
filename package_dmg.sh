#!/bin/bash
# Builds DockAnchor.app (via build.sh) and packages it into a distributable,
# drag-to-Applications .dmg at the repo root.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
APP_SRC="$HOME/Applications/DockAnchor.app"
OUT_DMG="$(pwd)/DockAnchor-${VERSION}.dmg"
STAGE=$(mktemp -d /tmp/dockanchor-dmg-stage.XXXXXX)
RW_DMG=$(mktemp /tmp/dockanchor-rw.XXXXXX.dmg)
rm -f "$RW_DMG"

./build.sh

mkdir -p "$STAGE"
cp -R "$APP_SRC" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "DockAnchor" -srcfolder "$STAGE" -ov -format UDRW "$RW_DMG"

MOUNT_DIR=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | grep -Eo '/Volumes/.*$' | tail -1)
osascript <<EOF
tell application "Finder"
    tell disk "DockAnchor"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 700, 420}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set position of item "DockAnchor.app" of container window to {120, 150}
        set position of item "Applications" of container window to {380, 150}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF
sync
hdiutil detach "$MOUNT_DIR"

rm -f "$OUT_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG"

rm -rf "$STAGE" "$RW_DMG"
echo "Built: $OUT_DMG"
