#!/bin/sh
# Build Murmur.app — run from anywhere.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Murmur.app"
BINARY="$APP/Contents/MacOS/Murmur"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

# Copy icon — fall back to the old bundle location during transition
if [ -f "$DIR/AppIcon.icns" ]; then
    cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "$DIR/WhisperInject.app/Contents/Resources/AppIcon.icns" ]; then
    cp "$DIR/WhisperInject.app/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

xcrun swiftc \
  -parse-as-library \
  -sdk "$(xcrun --show-sdk-path)" \
  "$DIR/Sources/"*.swift \
  -o "$BINARY"

codesign --force --deep --sign - "$APP"

# Build DMG
DMG="$DIR/Murmur.dmg"
rm -f "$DMG"
hdiutil create -volname "Murmur" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "Built: $APP"
echo "DMG:   $DMG"
