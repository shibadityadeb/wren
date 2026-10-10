#!/bin/zsh
# Submits a signed DMG to Apple's notary service with an App Store Connect API key,
# waits, prints the log on failure, staples the ticket and validates it.
#   NOTARY_KEY_P8_BASE64  base64 of the AuthKey_XXXX.p8
#   NOTARY_KEY_ID         key ID
#   NOTARY_ISSUER_ID      issuer ID
#   scripts/notarize.sh dist/Wren-macOS-universal.dmg
set -euo pipefail
DMG="$1"
: "${NOTARY_KEY_P8_BASE64:?missing}" "${NOTARY_KEY_ID:?missing}" "${NOTARY_ISSUER_ID:?missing}"
KEY="${RUNNER_TEMP:-/tmp}/AuthKey_$NOTARY_KEY_ID.p8"
echo "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$KEY"
trap 'rm -f "$KEY"' EXIT
OUT="$(xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait --output-format json)"
echo "$OUT" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("notary status:", d.get("status"), "id:", d.get("id"))'
STATUS="$(echo "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))')"
ID="$(echo "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')"
if [[ "$STATUS" != "Accepted" ]]; then
  xcrun notarytool log "$ID" --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
  echo "✗ notarization $STATUS"; exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "✓ notarized and stapled: $DMG"
