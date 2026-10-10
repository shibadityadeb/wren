#!/bin/zsh
# Verifies a Wren DMG: integrity, checksum, contents, bundle metadata, architectures,
# signature, absence of debug hooks and test data, and a smoke test of every slice
# that this Mac can execute.
#
#   scripts/verify-dmg.sh dist/Wren-macOS-universal-unsigned.dmg [--require-notarized]
set -euo pipefail
DMG="$1"; REQUIRE_NOTARIZED="${2:-}"
cd "$(dirname "$0")/.."
VERSION="$(tr -d ' \n' < VERSION)"
fail() { echo "✗ $1"; exit 1; }

[[ -f "$DMG" ]] || fail "missing $DMG"
if [[ -f "$DMG.sha256" ]]; then
  (cd "$(dirname "$DMG")" && shasum -a 256 -c "$(basename "$DMG").sha256" >/dev/null) || fail "checksum mismatch"
  echo "✓ checksum"
fi
hdiutil verify "$DMG" >/dev/null 2>&1 || fail "hdiutil verify"
echo "✓ image integrity"

MNT="$(mktemp -d /tmp/wren-dmg.XXXXXX)"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true' EXIT
APP="$MNT/Wren.app"
[[ -d "$APP" ]] || fail "Wren.app missing"
[[ "$(readlink "$MNT/Applications")" == "/Applications" ]] || fail "Applications shortcut missing"
[[ -f "$MNT/Install Wren.txt" ]] || fail "install guide missing"
echo "✓ contents: Wren.app, Applications shortcut, install guide"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[[ "$(plist CFBundleIdentifier)" == "com.shibadityadeb.wren" ]] || fail "bundle identifier changed (would orphan user data)"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || fail "version mismatch"
[[ "$(plist LSUIElement)" == "true" ]] || fail "not a menu-bar app"
[[ "$(plist LSMinimumSystemVersion)" == "14.0" ]] || fail "minimum macOS changed"
[[ -f "$APP/Contents/Resources/Wren.icns" ]] || fail "icon missing"
echo "✓ bundle: com.shibadityadeb.wren $VERSION, menu-bar only, macOS 14+"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Wren")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "expected arm64 and x86_64, got: $ARCHS"
NESTED="$(find "$APP" -type f -perm +111 ! -path "*/MacOS/Wren" | wc -l | tr -d ' ')"
[[ "$NESTED" == "0" ]] || fail "unexpected nested executables"
echo "✓ architectures: $ARCHS (no nested executables)"

if find "$APP" \( -name "*.store" -o -name "Fixtures" -o -name "*.p12" -o -name "*.p8" \) | grep -q .; then fail "test data or secrets in bundle"; fi
if strings "$APP/Contents/MacOS/Wren" | grep -qE "debug capture saved|debug command proposal|debug ai step"; then fail "debug hooks present"; fi
echo "✓ no debug hooks, fixtures or secrets"

codesign --verify --deep --strict "$APP" || fail "signature invalid"
AUTH="$(codesign -dv "$APP" 2>&1 | grep -m1 '^Authority=' || echo 'Authority=(ad-hoc)')"
echo "✓ signature valid: ${AUTH#Authority=}"
if [[ "$AUTH" == *"Developer ID Application"* ]]; then
  spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/  /' || true
  if xcrun stapler validate "$DMG" >/dev/null 2>&1; then echo "✓ notarization ticket stapled"; else
    [[ "$REQUIRE_NOTARIZED" == "--require-notarized" ]] && fail "not notarized"
    echo "! not notarized"
  fi
else
  [[ "$REQUIRE_NOTARIZED" == "--require-notarized" ]] && fail "unsigned build cannot be notarized"
  echo "! unsigned (ad-hoc) build: for testing, not frictionless public distribution"
fi

# Smoke-test each slice this machine can run.
for A in arm64 x86_64; do
  if arch -$A /usr/bin/true 2>/dev/null; then
    OUT="$(arch -$A "$APP/Contents/MacOS/Wren" --smoke-test)" || fail "smoke test failed on $A"
    [[ "$OUT" == *"arch=$A"* ]] || fail "smoke test ran wrong slice: $OUT"
    echo "✓ $OUT"
  else
    echo "! cannot execute $A on this machine; verified by the $A CI runner instead"
  fi
done
echo "✓ $DMG verified"
