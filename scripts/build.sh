#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Releases pass RATION_VERSION from the tag; local builds use the latest tag.
VERSION="${RATION_VERSION:-$( (git describe --tags --abbrev=0 2>/dev/null || true) | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
# Ad-hoc by default. scripts/release.sh signs with a Developer ID for distribution.
IDENTITY="${RATION_SIGN_IDENTITY:--}"
# Ration supports Apple silicon only.
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
rm -rf dist
APP="$PWD/dist/Ration.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Ration" "$APP/Contents/MacOS/Ration"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Ration</string>
<key>CFBundleIdentifier</key><string>io.github.xinding33.ration</string>
<key>CFBundleName</key><string>Ration</string>
<key>CFBundleDisplayName</key><string>Ration</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
cp LICENSE "$APP/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/dist/Ration.zip"
printf 'Built: %s\n' "$APP"
