#!/bin/bash
# Prints release notes: changelog section, install steps, requirements, trust level, checksums.
#   scripts/release-notes.sh v0.4.0-preview.1 dist <signed 0|1> <notarized 0|1>
set -euo pipefail
TAG="$1"; DIST="$2"; SIGNED="$3"; NOTARIZED="$4"
V="${TAG#v}"; BASE="${V%%-*}"
cd "$(dirname "$0")/.."
echo "## Wren $V"
echo
if [[ "$NOTARIZED" == 1 ]]; then
  echo "Signed with Developer ID and notarized by Apple."
else
  echo "> **Unsigned preview.** Not signed with a Developer ID or notarized. macOS will block it on first open:"
  echo "> open it once, then go to **System Settings › Privacy & Security › Open Anyway**. Only do this after checking the SHA-256 below."
fi
echo
echo "### Requirements"
echo "- macOS 14 Sonoma or later"
echo "- Universal: Apple Silicon (arm64) and Intel (x86_64), verified on both in CI"
echo "- Optional: [Ollama](https://ollama.com/download) for local AI. Models are downloaded separately, only when you press Download in Wren › Local AI."
echo
echo "### Install"
echo "1. Download the .dmg below and open it."
echo "2. Drag **Wren** into **Applications**, then eject the image."
echo "3. Open Wren from Applications. It lives in the menu bar."
echo
echo "Upgrading replaces the app only. Your data in \`~/Library/Application Support/Wren\` is kept and backed up before any schema change."
echo
echo "### Changes"
awk -v v="$BASE" '$0 ~ "^## \\[?"v {p=1; next} p && /^## / {exit} p' CHANGELOG.md
echo
echo "### Known limitations"
echo "- Local AI needs Ollama installed separately; Wren does not include a model runtime."
echo "- Scheduled reminders arrive even after you quit Wren. The briefing, check-in, email checks and alerts run only while Wren is running (turn on Open at login)."
echo "- Voice uses Apple's on-device speech model; if Connectors › Voice says it isn't installed, turn on Dictation once in System Settings › Keyboard."
echo "- Google sign-in is in testing: only accounts on the app's test-user list can connect, and Google asks them to reconnect every 7 days."
echo
echo "### Try it"
echo "Follow the [testing guide](https://github.com/shibadityadeb/wren/blob/${TAG}/docs/TESTING_GUIDE.md) and report problems as issues, with the log it describes."
echo
echo "### Checksums (SHA-256)"
echo '```'
cat "$DIST"/*.sha256
echo '```'
echo "Verify with: \`shasum -a 256 -c <file>.dmg.sha256\`"
