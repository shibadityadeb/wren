#!/bin/zsh
# CI only. Imports a Developer ID Application certificate into a temporary keychain.
# Reads secrets from the environment; prints nothing secret.
#   MACOS_CERTIFICATE_P12_BASE64  base64 of the exported .p12
#   MACOS_CERTIFICATE_PASSWORD    password of the .p12
# Writes the signing identity name to $GITHUB_ENV as WREN_SIGN_IDENTITY.
set -euo pipefail
: "${MACOS_CERTIFICATE_P12_BASE64:?missing}" "${MACOS_CERTIFICATE_PASSWORD:?missing}"
KEYCHAIN="$RUNNER_TEMP/wren-signing.keychain-db"
KC_PASS="$(openssl rand -hex 24)"
P12="$RUNNER_TEMP/wren-cert.p12"
echo "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$P12"
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
rm -f "$P12"
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/')"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity in the certificate."; exit 1; }
echo "WREN_SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
echo "Imported signing identity (Developer ID Application)."
