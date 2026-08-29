#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

VERSION="1.0.0"

swift build -c release

if [ -w /Applications ]; then
    APP_DIR="/Applications/DockAnchor.app"
else
    mkdir -p "$HOME/Applications"
    APP_DIR="$HOME/Applications/DockAnchor.app"
    echo "Note: /Applications isn't writable, installing to $APP_DIR instead."
fi
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp .build/release/DockAnchor "$APP_DIR/Contents/MacOS/DockAnchor"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DockAnchor</string>
    <key>CFBundleDisplayName</key>
    <string>DockAnchor</string>
    <key>CFBundleIdentifier</key>
    <string>com.dockanchor.app</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>DockAnchor</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>© Micropeptide</string>
</dict>
</plist>
EOF

codesign --force --deep -s - "$APP_DIR"

echo "Built: $APP_DIR"
