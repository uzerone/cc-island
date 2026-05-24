#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="CC Island"
BIN_NAME="CCIsland"
BUNDLE_ID="com.ccisland.app"
VERSION="1.0.0"
BUILD_DIR=".build"
STAGE_DIR="$BUILD_DIR/dmg-stage"
APP_DIR="$STAGE_DIR/$APP_NAME.app"
# Final DMG lands at the project root so it's visible in Finder (.build is hidden).
DMG_PATH="$APP_NAME-$VERSION.dmg"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP_NAME.app"
rm -rf "$STAGE_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/release/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesigning"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "==> Building DMG at $DMG_PATH"
rm -f "$DMG_PATH"
# Symlink so the user can drag-install into /Applications.
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

echo "==> Done"
echo "DMG: $DMG_PATH"
ls -lh "$DMG_PATH"
