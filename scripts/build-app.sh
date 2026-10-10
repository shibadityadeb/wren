#!/bin/zsh
# Builds Wren.app from the Swift package: compiles, assembles the bundle,
# generates the icon from assets/logo.png, and ad-hoc signs it.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Wren.app"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG" --product Wren
swift build -c "$CONFIG" --product wren-tools
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "→ brand assets from assets/logo.png"
"$BIN/wren-tools" assets assets/logo.png Brand >/dev/null
mkdir -p build
iconutil -c icns Brand/Wren.iconset -o build/Wren.icns

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Wren" "$APP/Contents/MacOS/Wren"
cp build/Wren.icns "$APP/Contents/Resources/Wren.icns"
VERSION="0.1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.shibadityadeb.wren</string>
  <key>CFBundleName</key><string>Wren</string>
  <key>CFBundleDisplayName</key><string>Wren</string>
  <key>CFBundleExecutable</key><string>Wren</string>
  <key>CFBundleIconFile</key><string>Wren</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Local-first personal assistant. Data stays on this Mac.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.shibadityadeb.wren</string>
    <key>CFBundleURLSchemes</key><array><string>wren</string></array>
  </dict></array>
</dict>
</plist>
PLIST

echo "→ ad-hoc signing (hardened runtime)"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "✓ built $APP"
