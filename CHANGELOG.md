# Changelog

Versions follow [semantic versioning](https://semver.org). The `VERSION` file is the source of truth; release tags are `v<VERSION>` (stable) or `v<VERSION>-preview.N` (prerelease).

## [0.5.0]

Feels like a real Mac app, and your data is safe to keep, move and recover.

- Opening Wren shows a window: what Wren does, open commitments, goals, waiting items, today's overdue and due items, upcoming reminders, Local AI status, and a New capture button. The menu bar and ⌥ Space still work as before; "Open Wren" in the menu brings the window back.
- Export everything to a readable, versioned JSON file.
- Backups: daily while Wren runs, before upgrades, restores and resets, and on demand. Each is a consistent database snapshot with a checksum and is verified before you can restore it. Restoring backs up your current data first and puts it back if anything goes wrong.
- Pause notifications for an hour, until the end of the day, or until you resume. Nothing is lost; anything that came due arrives as one summary.
- Reset preferences, or remove all Wren data, with a clear explanation, an optional backup first and a confirmation.

## [0.4.0]

Local AI that works, and a downloadable installer.

- Local AI setup in the app: Wren tells you exactly what's missing (Ollama not installed, not running, no chat model, no model selected, untested, ready, temporarily unavailable) and offers the next step.
- Download a model from inside Wren with real progress, cancel and resume. Nothing is downloaded until you press Download.
- "Test local AI" runs a real request and shows each check. Wren only says Ready after a model actually answered.
- The local model now understands many more ways of asking: "Could you push that API task to next Wednesday?", "I won't get that done this week. Move it to Sunday.", "Remind me about the application the day before it's due".
- New questions answered from your stored items, with links to each item: recent commitments, things you keep postponing, what has gone quiet, overdue, due soon, done recently.
- Every change Wren proposes from what you type still needs your confirmation, with or without AI.
- Universal installer for Apple Silicon and Intel Macs (macOS 14+), with checksum and release automation; Developer ID signing and notarization when configured.

## [0.3.0]

Goals with explainable progress, waiting items with follow-up dates, review of postponed and quiet items, and commands like "move that to Sunday".

## [0.2.0]

Morning briefing, evening check-in, launch at login, and the permission system with audit log.

## [0.1.0]

Menu-bar app, global capture shortcut, local storage, date reading, reminders, optional local model.
