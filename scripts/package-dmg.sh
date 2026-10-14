#!/bin/zsh
# Builds, packages and verifies the Wren installer.
#
#   scripts/package-dmg.sh [--skip-tests] [--skip-build]
#
# Output: dist/Wren-macOS-universal.dmg (Developer ID signed) or
#         dist/Wren-macOS-universal-unsigned.dmg (ad-hoc), plus a .sha256 next to it.
# Idempotent: re-running replaces previous output.
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_TESTS=0; SKIP_BUILD=0
for a in "$@"; do
  case "$a" in
    --skip-tests) SKIP_TESTS=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    *) echo "unknown option $a"; exit 2 ;;
  esac
done
VERSION="$(tr -d ' \n' < VERSION)"

if [[ $SKIP_TESTS == 0 ]]; then
  echo "→ swift test (full suite)"
  swift test
fi
if [[ $SKIP_BUILD == 0 ]]; then
  scripts/build-app.sh release --universal
fi

APP="build/Wren.app"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Wren")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "✗ not universal: $ARCHS"; exit 1; }

if codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  SIGNED=1; NAME="Wren-macOS-universal"
else
  SIGNED=0; NAME="Wren-macOS-universal-unsigned"
fi

STAGE="build/dmg-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/Wren.app"
ln -s /Applications "$STAGE/Applications"
{
  echo "Wren $VERSION"
  echo "Universal: Apple Silicon (arm64) and Intel (x86_64). Requires macOS 14 Sonoma or later."
  echo
  echo "Install"
  echo "  1. Drag Wren into the Applications folder."
  echo "  2. Eject this disk image."
  echo "  3. Open Wren from Applications. It lives in the menu bar (look for the bird)."
  echo
  echo "Upgrading: replace the old Wren in Applications. Your data stays in"
  echo "~/Library/Application Support/Wren and is backed up automatically before any upgrade."
  echo
  if [[ $SIGNED == 0 ]]; then
    echo "THIS BUILD IS UNSIGNED (development preview)."
    echo "macOS will block it the first time. To open it: try to open Wren once, then go to"
    echo "System Settings › Privacy & Security and choose Open Anyway. Only do this if you"
    echo "downloaded it from github.com/shibadityadeb/wren and the SHA-256 checksum matches."
    echo
  fi
  echo "Local AI (optional)"
  echo "  Wren works without AI. For smarter understanding, install Ollama (ollama.com),"
  echo "  then open Wren › Local AI and press Download next to a model. Nothing is sent"
  echo "  to external AI services."
} > "$STAGE/Install Wren.txt"

OUT="dist/$NAME.dmg"
rm -f "$OUT" "$OUT.sha256"
echo "→ creating $OUT"
# On CI runners hdiutil sometimes fails with "Resource busy" while another process (Spotlight, a
# malware scan) briefly holds the staged files. Retry a few times, with a growing pause, before failing.
for attempt in 1 2 3 4; do
  if hdiutil create -volname "Wren $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT" >/dev/null; then break; fi
  if [[ $attempt == 4 ]]; then echo "hdiutil create failed after $attempt attempts" >&2; exit 1; fi
  echo "  hdiutil create failed (attempt $attempt); retrying in $((attempt * 5)) s"
  rm -f "$OUT"; sleep $((attempt * 5))
done
if [[ $SIGNED == 1 ]]; then
  codesign --force --sign "$WREN_SIGN_IDENTITY" --timestamp "$OUT"
fi
(cd dist && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
scripts/verify-dmg.sh "$OUT"
echo "✓ $OUT"
cat "$OUT.sha256"
