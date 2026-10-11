#!/bin/zsh
# Builds Wren.app.
#
#   scripts/build-app.sh [debug|release] [--universal]
#
# --universal  builds arm64 and x86_64 separately and merges them with lipo (SwiftPM's
#              multi-arch mode rejects this package's per-target language settings).
#
# Signing: ad-hoc by default. Set WREN_SIGN_IDENTITY to a "Developer ID Application: …"
# identity in the keychain to sign for distribution (hardened runtime + secure timestamp).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"; UNIVERSAL=0
for a in "$@"; do
  case "$a" in
    debug|release) CONFIG="$a" ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "unknown option $a"; exit 2 ;;
  esac
done
VERSION="$(tr -d ' \n' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Wren.app"
mkdir -p build

if [[ $UNIVERSAL == 1 ]]; then
  BINS=()
  for T in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
    echo "→ swift build -c $CONFIG --triple $T"
    swift build -c "$CONFIG" --triple "$T" --product Wren
    swift build -c "$CONFIG" --triple "$T" --product wren-tools
    BINS+=("$(swift build -c "$CONFIG" --triple "$T" --show-bin-path)")
  done
  mkdir -p build/universal
  lipo -create "${BINS[1]}/Wren" "${BINS[2]}/Wren" -output build/universal/Wren
  WREN_BIN="build/universal/Wren"
  TOOLS="${BINS[1]}/wren-tools"   # host-arch tool for asset generation (arm64 on Apple Silicon)
  [[ "$(uname -m)" == "x86_64" ]] && TOOLS="${BINS[2]}/wren-tools"
else
  echo "→ swift build -c $CONFIG"
  swift build -c "$CONFIG" --product Wren
  swift build -c "$CONFIG" --product wren-tools
  BIN="$(swift build -c "$CONFIG" --show-bin-path)"
  WREN_BIN="$BIN/Wren"; TOOLS="$BIN/wren-tools"
fi

echo "→ brand assets from assets/logo.png"
"$TOOLS" assets assets/logo.png Brand >/dev/null
iconutil -c icns Brand/Wren.iconset -o build/Wren.icns

echo "→ assembling $APP ($VERSION, build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WREN_BIN" "$APP/Contents/MacOS/Wren"
cp build/Wren.icns "$APP/Contents/Resources/Wren.icns"
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
  <key>NSMicrophoneUsageDescription</key><string>Wren records only while you hold the push-to-talk shortcut, to turn what you say into a capture. Audio is transcribed on this Mac and deleted.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Wren uses on-device speech recognition to turn your voice capture into text. Audio never leaves this Mac.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.shibadityadeb.wren</string>
    <key>CFBundleURLSchemes</key><array><string>wren</string></array>
  </dict></array>
</dict>
</plist>
PLIST

# Hardened runtime needs an explicit entitlement for microphone access (voice capture).
ENT="build/Wren.entitlements"
cat > "$ENT" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENTITLEMENTS

IDENTITY="${WREN_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  echo "→ ad-hoc signing (not for public distribution)"
  codesign --force --sign - --options runtime --timestamp=none --entitlements "$ENT" "$APP"
else
  echo "→ signing with Developer ID (hardened runtime, secure timestamp)"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENT" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
echo "✓ built $APP ($(lipo -archs "$APP/Contents/MacOS/Wren"))"
