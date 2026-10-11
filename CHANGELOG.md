# Changelog

Versions follow [semantic versioning](https://semver.org). The `VERSION` file is the source of truth; release tags are `v<VERSION>` (stable) or `v<VERSION>-preview.N` (prerelease).

## [Unreleased]

- Every input in the capture panel is classified before anything happens: save, reminder, ask ChatGPT, change an item, question about your items, general question, or something to remember. "Can you check on GPT what is quantum physics" now asks ChatGPT instead of showing an unrelated waiting-items card.
- Asking ChatGPT happens in the panel. It shows the question, sends it with your ChatGPT plan, and streams the real answer. If you're not connected or not allowed, it shows Connect ChatGPT and keeps your question. Usage limits, network errors and retry are explained. One request at a time.
- A question that names no assistant lets you choose: local AI, ChatGPT, or save it as a note. "Note: …" or "Save this: …" always just saves.
- The local model can no longer turn an unrelated sentence into an answer about your stored items.

## [0.8.0]

A complete Mac app, reminders you can rely on, and talking to Wren.

- Wren is a regular Mac app: a Dock icon, a Wren menu with About, Settings, Hide and Quit, and exactly one bird in the menu bar, all in one process. ⌘Q quits for real; closing the window keeps Wren in the menu bar.
- Only one Wren can run, and only one can use your data. This fixes extra birds in the menu bar when a second copy was running.
- Reminders are scheduled with macOS, so they arrive even when Wren isn't running, and are re-checked at every start without duplicates. Completing, deleting, snoozing or moving a reminder updates its notification.
- Repeating reminders ("every weekday at 3 PM") keep their local time through daylight saving and travel.
- "Remind me to …" (typed or spoken) sets the reminder straight away and says exactly when. Wren asks when the time is missing or unclear, refuses times that have passed, and understands "snooze the current reminder for 30 minutes".
- New reminder in the main window, and Repeat in each item.
- "Hey Wren" (off until you turn it on) and the voice shortcut run the same voice command, recognised on your Mac. You see what Wren heard and what it did.
- Connector states read: Available to connect, Missing permissions, Reauthorization required, Usage limit reached, Maintainer setup required, Not implemented.
- Google sign-in no longer uses a client secret.

## [0.7.0]

Connect your accounts by signing in. No keys, tokens or developer setup.

- ChatGPT: **Continue with ChatGPT** signs in with your ChatGPT account (Sign in with ChatGPT). Requests you confirm are sent with your ChatGPT plan and the answer streams back. Shows the account, whether plan usage is allowed, **Using ChatGPT plan** and **Manage usage**, and clear states for usage limits, expired sign-ins and outages. Models come from your account. No API-billing fallback, and background tasks never use your plan.
- Copy-and-open ChatGPT handoff stays as an optional fallback.
- Gmail and Google Calendar: **Connect with Google** using Wren's own registration. Each asks for one read-only permission and checks it was granted.
- Notion: **Connect Notion** and pick pages on Notion's own screen. Shows the connected workspace.
- Disconnect revokes access with the provider, and says so if the provider couldn't confirm it.
- Removed: entering a Google client ID or secret, pasting a Notion token, and the OpenAI API-key connector. Any of these saved by an earlier build are deleted from the Keychain.
- A connector this build wasn't set up for says "Not available in this build" instead of asking you to configure anything.

## [0.6.0]

Connectors, voice and ChatGPT handoff.

- Connectors in the window and Settings: ChatGPT, OpenAI API, Voice, Gmail, Notion, Google Calendar (and Local files and Apple Shortcuts as planned), each with its real state, permissions, privacy and setup.
- ChatGPT handoff with your own account: preview exactly what leaves your Mac, private items and secrets left out unless you include them, copy and open ChatGPT, paste the answer back, summarise locally, make tasks.
- Push-to-talk voice capture with on-device transcription.
- Gmail and Google Calendar, read-only: questions, today's events and mail that needs you, and the morning briefing.
- Notion: search shared pages, use them as context, create a page after confirmation.
- Optional OpenAI API connector.
- Delegate panel and history.
- Items can be marked private.

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
