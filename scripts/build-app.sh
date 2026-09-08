#!/usr/bin/env bash
# Bundles weft-bar into a menu-bar agent .app bundle.
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/build/WeftBar.app"
BIN="$APP/Contents/MacOS/WeftBar"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$DIR/.build/release/weft-bar" "$BIN"

# Icon, drawn at build time by scripts/make-icon.swift.
ICONSET="$DIR/build/WeftBar.iconset"
rm -rf "$ICONSET"
if swift "$DIR/scripts/make-icon.swift" "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/WeftBar.icns" 2>/dev/null; then
    rm -rf "$ICONSET"
    echo "Icon: WeftBar.icns"
else
    echo "WARNING: icon generation failed — the bundle will use the generic app icon"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WeftBar</string>
  <key>CFBundleDisplayName</key><string>WeftBar</string>
  <key>CFBundleIdentifier</key><string>com.weft.bar</string>
  <key>CFBundleExecutable</key><string>WeftBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleIconFile</key><string>WeftBar</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

echo "Built: $APP"
