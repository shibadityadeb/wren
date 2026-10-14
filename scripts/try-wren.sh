#!/bin/zsh
# Real testing on this Mac, without touching your installed Wren or its data.
#
#   scripts/try-wren.sh               build "Wren Dev" (with config/providers.env if present), open it,
#                                     and record a diagnostic log until you press Ctrl-C
#   scripts/try-wren.sh --no-build    open the last Wren Dev build and record the log
#   scripts/try-wren.sh --installed   record the log of the installed Wren (/Applications/Wren.app)
#
# Wren Dev is a separate app: its own bundle ID, data folder (~/Library/Application Support/Wren Dev),
# sign-ins and macOS permissions. You sign in to ChatGPT and Google inside it, and macOS asks it for
# Notifications, Microphone and Speech Recognition separately.
#
# The log holds what Wren did (operation names, states, counts), not your words, email or answers.
# Skim it before sharing: system error messages can name files or accounts.
# Follow docs/TESTING_GUIDE.md while it runs, then attach the log file to an issue if something's wrong.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1; TARGET="dev"
for a in "$@"; do
  case "$a" in
    --no-build) BUILD=0 ;;
    --installed) TARGET="installed"; BUILD=0 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a (try --help)"; exit 2 ;;
  esac
done

if [[ "$TARGET" == "dev" ]]; then
  APP="build/Wren Dev.app"; BUNDLE="com.shibadityadeb.wren.dev"; MATCH="Wren Dev.app"
  if [[ $BUILD == 1 ]]; then
    [[ -f config/providers.env ]] || echo "note: no config/providers.env, so Connect Google will say \"Maintainer setup required\" (see docs/MAINTAINER_SETUP.md)"
    scripts/build-app.sh debug --dev-identity
  fi
  [[ -d "$APP" ]] || { echo "No $APP yet. Run without --no-build."; exit 1; }
  # Restart so the newest build runs (one Wren Dev at a time).
  if pgrep -f "$APP/Contents/MacOS" >/dev/null; then
    osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -f "$APP/Contents/MacOS" >/dev/null || break; sleep 0.5; done
  fi
  open "$APP"
else
  APP="/Applications/Wren.app"; MATCH="/Applications/Wren.app"
  [[ -d "$APP" ]] || { echo "Wren isn't installed in /Applications."; exit 1; }
  pgrep -f "$APP/Contents/MacOS" >/dev/null || open "$APP"
fi

mkdir -p build/test-logs
LOG="build/test-logs/wren-$(date +%Y%m%d-%H%M%S).log"
cat <<EOF

Testing $(basename "$APP") $(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || true)
  Checklist:  docs/TESTING_GUIDE.md
  Log file:   $LOG
  If notifications never appear: System Settings › Notifications › $(basename "$APP" .app) › Allow Notifications.
  If voice says the microphone is denied: System Settings › Privacy & Security › Microphone.

Recording the log. Press Ctrl-C when you're done.
EOF
exec /usr/bin/log stream --style compact \
  --predicate "subsystem == \"com.shibadityadeb.wren\" AND processImagePath CONTAINS \"$MATCH\"" | tee "$LOG"
