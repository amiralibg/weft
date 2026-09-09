#!/usr/bin/env bash
# Bundles weft-bar into a menu-bar agent .app bundle.
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/build/WeftBar.app"
BIN="$APP/Contents/MacOS/WeftBar"

# Where to take weft-bar from. `.build/release` is a symlink to the *host*
# architecture's products, so a universal build (`--arch arm64 --arch x86_64`)
# does not land there — its fat binaries go to .build/apple/Products/Release.
# The release workflow points this at those; a plain local build uses the
# default and gets a thin binary, which is what you want on your own machine.
BINDIR="${WEFT_PRODUCT_DIR:-$DIR/.build/release}"
if [ ! -x "$BINDIR/weft-bar" ]; then
    echo "ERROR: no weft-bar at $BINDIR — run 'swift build -c release' first" >&2
    exit 1
fi

# Version for Info.plist. Kept in step with WeftCore/Version.swift rather than
# hardcoded here, so a release cannot ship an app that disagrees with its CLI.
VERSION="${WEFT_VERSION:-$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' \
    "$DIR/Sources/WeftCore/Version.swift")}"
VERSION="${VERSION:-0.0.0}"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINDIR/weft-bar" "$BIN"

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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WeftBar</string>
  <key>CFBundleDisplayName</key><string>WeftBar</string>
  <key>CFBundleIdentifier</key><string>com.weft.bar</string>
  <key>CFBundleExecutable</key><string>WeftBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>WeftBar</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict>
</plist>
PLIST

# Re-sign the bundle after writing into it. The linker ad-hoc signs the
# executable, but copying it into a bundle and adding an Info.plist invalidates
# that signature — and on arm64 an invalid signature is a bundle that will not
# launch at all.
#
# Three cases, in order of preference. A real Developer ID (the release
# workflow). The local self-signed identity install.sh passes down, which keeps
# the app's designated requirement stable so its own TCC grants — and the
# Setup window's Carbon hotkeys — survive a rebuild. Ad-hoc as a last resort,
# which launches but is a different program to macOS after every build.
IDENTITY="${WEFT_CODESIGN_IDENTITY:-${WEFT_SELFSIGN_IDENTITY:--}}"
SIGN_ARGS=(--force --deep --sign "$IDENTITY")
if [ -n "${WEFT_CODESIGN_IDENTITY:-}" ]; then
    SIGN_ARGS+=(--options runtime --timestamp)
elif [ -n "${WEFT_SELFSIGN_IDENTITY:-}" ]; then
    SIGN_ARGS+=(--keychain "${WEFT_SIGN_KEYCHAIN:-$HOME/Library/Keychains/weft-signing.keychain-db}")
fi
codesign "${SIGN_ARGS[@]}" "$APP" 2>/dev/null \
    && echo "Signed: $IDENTITY" \
    || echo "WARNING: codesign failed — the bundle may not launch"

echo "Built: $APP (version $VERSION)"
