#!/bin/zsh
# Builds Wren.app.
#
#   scripts/build-app.sh [debug|release] [--universal]
#
# --universal  builds arm64 and x86_64 separately and merges them with lipo (SwiftPM's
#              multi-arch mode rejects this package's per-target language settings).
#
# Provider sign-in (maintainers only): Google and Notion app registrations are read from
# config/providers.env (git-ignored) or from the environment (CI secrets) and written into
# Info.plist. Values are never printed. A missing value builds a copy of Wren that reports
# "Not available in this build" for that provider. See docs/MAINTAINER_SETUP.md.
#
# Signing: ad-hoc by default. Set WREN_SIGN_IDENTITY to a "Developer ID Application: …"
# identity in the keychain to sign for distribution (hardened runtime + secure timestamp).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"; UNIVERSAL=0; DEV_IDENTITY=0
for a in "$@"; do
  case "$a" in
    debug|release) CONFIG="$a" ;;
    --universal) UNIVERSAL=1 ;;
    --dev-identity) DEV_IDENTITY=1 ;;
    *) echo "unknown option $a"; exit 2 ;;
  esac
done
VERSION="$(tr -d ' \n' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# --dev-identity: a separate "Wren Dev" app (own bundle ID, data folder, Keychain items and URL
# scheme) for testing beside an installed Wren without touching its data. Never for release.
BUNDLE_ID="com.shibadityadeb.wren"; APP_NAME="Wren"; URL_SCHEME="wren"; APP="build/Wren.app"
if [[ $DEV_IDENTITY == 1 ]]; then
  [[ "$CONFIG" == "debug" ]] || { echo "--dev-identity is for debug builds only"; exit 2; }
  BUNDLE_ID="com.shibadityadeb.wren.dev"; APP_NAME="Wren Dev"; URL_SCHEME="wren-dev"; APP="build/Wren Dev.app"
fi
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

# Provider registrations. Only these keys are read from the file; nothing in it is executed.
PROVIDER_VARS=(WREN_GOOGLE_CLIENT_ID WREN_GOOGLE_CLIENT_SECRET WREN_NOTION_CLIENT_ID WREN_NOTION_OAUTH_RELAY)
if [[ -f config/providers.env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ '^[[:space:]]*(#|$)' ]] && continue
    k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
    if (( ${PROVIDER_VARS[(Ie)$k]} )) && [[ -z "${(P)k:-}" ]]; then typeset -gx "$k=$v"; fi
  done < config/providers.env
fi
xml_escape() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; print -r -- "$s"; }
PROVIDER_PLIST=""
add_provider() { [[ -n "$2" ]] && PROVIDER_PLIST+="  <key>$1</key><string>$(xml_escape "$2")</string>"$'\n' || true; }
add_provider WrenGoogleClientID "${WREN_GOOGLE_CLIENT_ID:-}"
add_provider WrenGoogleClientSecret "${WREN_GOOGLE_CLIENT_SECRET:-}"
add_provider WrenNotionClientID "${WREN_NOTION_CLIENT_ID:-}"
add_provider WrenNotionOAuthRelay "${WREN_NOTION_OAUTH_RELAY:-}"
included() { [[ -n "${(P)1:-}" ]] && echo "included" || echo "not included"; }
echo "→ provider sign-in: Google $(included WREN_GOOGLE_CLIENT_ID), Notion $( [[ -n "${WREN_NOTION_CLIENT_ID:-}" && -n "${WREN_NOTION_OAUTH_RELAY:-}" ]] && echo included || echo 'not included'), ChatGPT always (no registration needed)"

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
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>Wren</string>
  <key>CFBundleIconFile</key><string>Wren</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Local-first personal assistant. Data stays on this Mac.</string>
  <key>NSMicrophoneUsageDescription</key><string>Wren records only while you hold the push-to-talk shortcut, to turn what you say into a capture. Audio is transcribed on this Mac and deleted.</string>
${PROVIDER_PLIST}  <key>NSSpeechRecognitionUsageDescription</key><string>Wren uses on-device speech recognition to turn your voice capture into text. Audio never leaves this Mac.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>$URL_SCHEME</string></array>
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
