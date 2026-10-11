# Manual and live tests

`swift test` covers the logic with **mocks** (`RouteStub` serves recorded provider responses,
`FakeGmail` implements Gmail's documented semantics, `FakeReminderCenter` stands in for macOS
notifications). Those are not live tests. This page lists what needs a real Mac session, a person, an
account or real time, with the result of the last pass.

Status values: **Passed live**, **Failed**, **Blocked** (with the reason), **Not run**.

Use a **Wren Dev** build (`scripts/build-app.sh debug --dev-identity`) for anything that writes data:
it has its own bundle ID, data folder and URL scheme (`wren-dev://`), so the installed Wren is never
touched. Debug URLs exist only in debug builds. Read results with:

```
/usr/bin/log stream --style compact --predicate 'subsystem == "com.shibadityadeb.wren" AND processImagePath CONTAINS "Wren Dev.app"'
```

## Last pass: 2026-10-11, branch `feat/audit-real-integrations` (0.9.0, schema 6), macOS 26, Apple Silicon

| ID | Area | Test | Status |
|---|---|---|---|
| M-GPT-1 | GPT | A real delegation through the new pipeline (`wren-tools live-check chatgpt`, same AskService/broker/connector as the app) against the signed-in ChatGPT plan: routed, persisted as running before the provider answered, duplicate submit deduplicated, completed with requested = reported model, answer stored, announced once, audit `succeeded` | **Passed live** (3.2 s, 3 models listed, gpt-6-luna) |
| M-GPT-2 | GPT | Expired access token is refreshed and the rotated tokens are saved (file stays 0600) so the installed app stays signed in | **Passed live** |
| M-GPT-3 | GPT | Earlier 0.8.0 build: a ChatGPT-plan answer recorded in the installed app's audit (`ai.delegate succeeded · requested gpt-6-luna · reported gpt-6-luna`) | **Passed live** (evidence in the user's store, 12:41 UTC) |
| M-GPT-4 | GPT | Voice/typed "search in GPT: …" in the running app routes to the GPT delegation (not a task, not a stored-data answer) | **Passed live** in Wren Dev (`voice command result: ask ChatGPT`); Wren Dev isn't signed in to ChatGPT, so nothing was sent |
| M-GPT-5 | GPT | Completion notification "GPT finished: … View result." appears; clicking it opens the saved result | **Blocked**: notifications are denied for Wren Dev on this Mac; needs a person to allow them (System Settings › Notifications › Wren Dev) and a ChatGPT sign-in in Wren Dev |
| M-GPT-6 | GPT | Quit while a request runs; relaunch shows it as interrupted with Retry | **Not run** live (covered by `testRequestInterruptedByQuitIsReportedOnNextLaunch`) |
| M-GMAIL-1 | Gmail | Connect Google completes against Google | **Failed (blocker)**: Google's token endpoint answers `client_secret is missing.` for this build's Desktop client (probed live with an invalid code; no account involved). Needs `WREN_GOOGLE_CLIENT_SECRET` from the maintainer (docs/MAINTAINER_SETUP.md) |
| M-GMAIL-2..9 | Gmail | Sync, Spam/Trash exclusion, digest, alerts, quiet hours, Mark as read, disconnect | **Blocked** by M-GMAIL-1 (mock-tested: `MailIntelligenceTests`) |
| M-REM-1 | Reminders | "I need to finish this report by Friday" in the running app → a task due Friday with a reminder Friday 10:00 | **Passed live** in Wren Dev (`kind=commitment deadline=Fri next=Fri 10:00`) |
| M-REM-2 | Reminders | "Remind me to stretch in 2 minutes" with notifications denied: saved, nothing scheduled, the reply says notifications are off | **Passed live** in Wren Dev (`reminders authorized=false scheduled=0`) |
| M-REM-3 | Reminders | The notification appears at the time while Wren is quit, its Done action works, and nothing fires again after completion | **Blocked**: notifications denied for Wren Dev (see M-GPT-5). Trigger dates were checked with `UNCalendarNotificationTrigger.nextTriggerDate()` (one-off and weekday-repeating: correct) |
| M-LIFE-1 | Lifecycle | Opening Wren Dev twice leaves exactly one process | **Passed live** |
| M-LIFE-2 | Lifecycle | Quit (Apple Event) ends the process, removes the menu-bar item, releases shortcuts and the data lock; relaunch works | **Passed live** |
| M-LIFE-3 | Lifecycle | One bird in the menu bar, ⌘Q from the keyboard, Dock click reopens the window | **Not run** by hand (needs someone at the screen) |
| M-DATA-1 | Upgrade | A copy of the real 0.8.0 store (schema 5) opens under schema 6 with every item, delegation and audit record intact | **Passed live** (`items=8 delegations=1 audit=22` before and after; `WREN_MIGRATION_COPY` test) |
| M-DATA-2 | Upgrade | Wren Dev's existing data opens after the upgrade | **Passed live** |
| M-VOICE-1 | Voice | Real microphone, "Hey Wren", the voice shortcut | **Not run**: needs a person to speak and to allow Microphone and Speech Recognition |
| M-NOTION-1 | Notion | Full sign-in and search | **Not run**: needs a Notion account at the screen (registration and consent page were reached live in an earlier pass) |
| M-CAL-1 | Calendar (this Mac) | Reading events through macOS | **Not run**: needs a person to allow Calendars access |

## Steps

### M-GPT: delegate to GPT (needs a ChatGPT Plus or Pro sign-in)

Quick live check without the UI (uses your plan allowance; prints status, models and answer length only):

```
swift build --product wren-tools
"$(swift build --show-bin-path)/wren-tools" live-check chatgpt "Ask GPT to reply with the single word: ready"
```

Expected: `persisted as: running`, `second identical submit while running: deduplicated`,
`record: status=completed … providerURL=none announced=1`, `audit: succeeded`.

In the app (Wren Dev, after Connectors › ChatGPT › Continue with ChatGPT and allowing plan usage):
1. ⌥ Space, type `Hey Wren, search in GPT: explain quantum physics and give me a few useful beginner resources.`, Return.
   Expected: the card says "Ask ChatGPT · Request: Explain quantum physics and give me a few useful beginner resources." and "Sent to ChatGPT. You can close this; Wren will tell you when it's finished." No "You're not waiting on anything", no new item.
2. Press Return again and Esc. Expected: no second request (Delegate history shows one entry).
3. When it finishes: a notification "GPT finished: Explain quantum physics… · View result." Click it.
   Expected: the main window opens on the result: what you said, what was sent, model, created/completed times, the answer as returned, Copy answer, Open ChatGPT. No "Open conversation" link (the plan API returns none).
4. Overview › GPT requests lists it as Completed. Quit and reopen Wren: still there.
5. Turn Wi-Fi off, ask `ask GPT to brainstorm names for my project`. Expected: Failed, retryable; Retry with Wi-Fi on completes the same entry (Attempts 2).
6. Ask something and quit Wren while it runs; reopen. Expected: the entry says Wren was closed before ChatGPT finished, with Retry.
7. Voice: say "Hey Wren, ask GPT what quantum physics is." Expected: same as 1–3.

### M-GMAIL: inbox intelligence (needs the maintainer's Google setup, then a listed test account)
1. Connectors › Gmail › Connect Google, approve Gmail read. Expected: Gmail Connected; Inbox shows your account and "checked …".
2. Inbox: only unread inbox mail appears; nothing from Spam or Trash; each entry says "Why: …"; promotions sit under "Informational".
3. Correct › "Never important from …": that sender's mail moves to Informational and stays there after Check now.
4. Send yourself `Urgent: please sign by today`. Within the polling interval (default 5 min) a notification "Urgent: <you>" appears once. Check now again: no second alert. Reply in the same thread with the same urgency: no new alert.
5. Set quiet hours to include now; send another urgent mail: no alert; end quiet hours: one alert.
6. Mail settings › digest time 2 minutes ahead. Expected: one "Email digest" notification; the Inbox shows the digest with Summary (Gmail's text), Inferred reason and Suggested action, and Open email. Quit and relaunch: no second digest for that slot.
7. Sleep the Mac across the digest time; wake. Expected: one digest marked "(late)".
8. Open email opens the right conversation in Gmail in the right account.
9. Mark as read without the extra permission: the button says "Allow Mark as read…", which opens Google's consent for `gmail.modify`. After approving, Mark as read marks the message read in Gmail (check in Gmail) and the alert disappears. Turn Wi-Fi off and try again: an error, the message stays unread, Retry offered.
10. Disconnect Google: the Inbox empties, `~/Library/Application Support/Wren Dev/Mail/` is gone, Wren disappears from your Google account's third-party access.

### M-REM: reminders (needs notifications allowed for Wren Dev)
1. ⌥ Space: `remind me to test Wren in 2 minutes`. Expected: "Reminder set … Scheduled with macOS".
2. Quit Wren (⌘Q). Wait 2 minutes: the notification appears without Wren running.
3. Reopen Wren: the item shows the reminder as sent; no second notification.
4. `remind me every weekday at <2 minutes ahead> to take a break`: fires; Done keeps the series.
5. `snooze this reminder for 30 minutes` with the item selected: a preview; Return confirms.
6. Complete or delete a reminder before it fires: nothing fires.
7. Turn notifications off: a new reminder says it will only show inside Wren. Turn them on: Settings shows it scheduled.
8. Change the Mac's time zone: a repeating 3 PM reminder fires at 3 PM local.

Debug: `open "wren-dev://debug/reminders"` logs `debug pending <id> next=<date>`; `open "wren-dev://debug/delivered"` lists notifications macOS delivered (including while Wren was quit).

### M-LIFE: lifecycle
1. Quit any other Wren. Open Wren Dev: one Dock icon, one bird, the window opens.
2. Close the window: the bird stays; click the Dock icon: the window returns.
3. Open the app again from Finder: still one process and one bird.
4. ⌘Q: the bird and Dock icon go; the microphone indicator (if "Hey Wren" was on) goes off. Wren no longer checks mail or listens; already-scheduled reminders still arrive from macOS.

### M-VOICE (needs Microphone and Speech Recognition allowed)
1. Connectors › Voice › "Listen for “Hey Wren”".
2. Say "Hey Wren, remind me to call Sam tomorrow at 10 AM": reply "Reminder set: Call Sam, tomorrow at 10:00 AM".
3. Say "Hey Wren, search in GPT: explain transformers": a GPT delegation as in M-GPT.
4. Say "Hey Wren, what am I waiting on?": an answer from Wren's own items, nothing sent anywhere.
5. Start speaking and press Esc: nothing happens; recording stops.

### M-NOTION, M-CAL
As before: Connectors › Notion › Connect Notion (search, read, create after confirming, disconnect);
Connectors › Calendar › Use this Mac's calendars (allow, ask "what meetings do I have tomorrow?").
