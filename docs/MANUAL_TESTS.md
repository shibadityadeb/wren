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

## Last pass: 2026-10-14, branch `fix/push-to-talk` (0.10.1), macOS 26.1, Apple Silicon

Automated: `swift test`, 342 tests, 0 failures, 4 skipped (the push-to-talk state machine runs against a
fake microphone and fake permissions). Live: a **Wren Dev** build driven by debug URLs. No microphone was
opened: Wren Dev has never been granted Microphone or Speech Recognition, and granting them needs a person.

| ID | Area | Test | Status |
|---|---|---|---|
| P-1 | Shortcut | At launch, push-to-talk registers ⌥ Space and typed capture moves to ⌥⇧ Space (no clash); voice phase `idle`, microphone closed | **Passed live** in Wren Dev (`push-to-talk ⌥ Space registered`, `hotkey ⌥⇧ Space registered`, `microphoneOpen=false`) |
| P-2 | Command | The step after transcription (`/debug/voice-command`), as a spoken command: "Remind me to call Sam tomorrow at 10 AM." → `completed("Reminder created: Call Sam")`; "I need to finish the report by Friday." → CreateTask, `completed("Saved")`; "Ask GPT to research quantum physics." → DelegateToChatGPT, `failed("ChatGPT isn't connected…")` with the request kept (Wren Dev isn't signed in); "What am I waiting for?" → QueryStoredItems, `completed`; "Remind me every weekday at 3 PM." → `needsClarification("What should I remind you about?")`; microphone closed throughout | **Passed live** in Wren Dev |
| P-3 | Command | "to stretch" after that question → `completed("Reminder created: Stretch")` (repeating); "I need to send the invoice by Monday." after the same question → CreateTask, not swallowed as the answer | **Passed live** after the fix (first run showed the bug: the invoice sentence became the answer and the weekday schedule was lost) |
| P-4 | Shortcut + mic | Hold ⌥ Space in another app with Wren's window closed: "I'm listening…", orange mic dot; release (either key) ends recording and the dot goes off at once; key repeat and repeated presses start nothing; Esc cancels | **Not run**: needs a person at the keyboard and Microphone + Speech Recognition granted (steps M-PTT below) |
| P-5 | Transcription | Real on-device transcription of spoken words, interim text while holding, low-confidence confirmation | **Not run** live (same reason). Mocked: `PushToTalkTests` |
| P-6 | Lifecycle | Quit unregisters both shortcuts and releases the microphone | **Passed live** for quit (`quit: status item removed, shortcuts released`); microphone part mocked (`testQuitAndScreenLockReleaseTheMicrophone`) |

Observed once and not reproduced: during the first P-3 run, a typed-channel "Capture" submission appeared
in the log between two debug commands. A clean rerun of the same sequence showed none. A content-free
`panel submit` log line now records every panel submission, to catch it if it recurs.

## Previous pass: 2026-10-13, branch `feat/personal-executor` (0.10.0, schema 7), macOS 26.1, Apple Silicon

Automated: `swift test` (mocks, see above). Live items below used the maintainer's own signed-in
accounts through `wren-tools live-check` (same AskService/broker/connectors as the app, throwaway
in-memory database) and a **Wren Dev** build driven by debug URLs. Nothing was sent from or changed in
the installed Wren or its data.

| ID | Area | Test | Status |
|---|---|---|---|
| E-GPT-1 | GPT | "Ask GPT to think deeply about this …" on the real ChatGPT plan: routed as DelegateToChatGPT (thinking), persisted as running first, duplicate deduplicated, `reasoning.effort: high` sent, completed with `response.completed`, response reports effort `high`, announced once, audit `succeeded` | **Passed live** (5.9 s, gpt-6-luna) |
| E-GPT-2 | GPT | "Ask GPT to research the latest stable Swift language release and cite your sources …": `web_search` tool offered and accepted; the record shows 1 web search and 1 cited source taken from the stream, effort left at the model default (response reports `medium`) | **Passed live** (7.6 s). First run found 0 sources: live stream inspection showed the completed event's `output` is empty on this route, so citations are now read from `response.output_text.annotation.added` and finished message items (fixed, re-run passed) |
| E-GPT-3 | GPT | The model list exposes `supported_reasoning_levels` per model (used to pick the effort) | **Passed live** (3 models, each listing low…max) |
| E-GPT-4 | GPT | Plan refuses web search or reasoning (`subscription_sharing_unsupported_capability`) | **Mock only** (`testUnsupportedWebSearchFails…`); the live account accepted both, so the refusal couldn't be produced live |
| E-GPT-5 | GPT | "GPT has finished · Research: …" notification opens the exact result | **Blocked**: notifications are denied for Wren Dev on this Mac (needs a person in System Settings › Notifications › Wren Dev) and Wren Dev isn't signed in to ChatGPT. Covered by mocks and the result-page snapshot |
| E-GMAIL-1 | Gmail | Read-only `live-check gmail` with the real Google sign-in: token refresh, full sync, Spam/Trash excluded, then an incremental (history) sync, triage into categories, alert policy dry run (nothing delivered) | **Passed live** (150 inbox messages, 0 Spam/Trash, incremental sync reported 0 new, a repeated alert check would alert 0 times) |
| E-GMAIL-2 | Gmail | Mark as read changes the real Gmail state | **Not run**: this account granted read-only access (`gmail.modify` not granted); Wren correctly reports Mark as read unavailable |
| E-GMAIL-3 | Gmail | "Important email from …" alert with Open email / Snooze alert in Notification Center | **Blocked**: notifications denied for Wren Dev, and Wren Dev has its own data folder without the Google sign-in. Snooze re-alert covered by `testSnoozedAlertComesBackOnce…` |
| E-ROUTE-1 | Router | In the running Wren Dev app (`/debug/command`): "Remind me to call Sam tomorrow at 10 AM." → CreateReminder (set); "Move that reminder to Sunday." → ChangeItem (preview "Move “Call Sam” to Sunday"); "I need to finish the report by Friday." → CreateTask; "Remind me every weekday at 3 PM." → asks "What should I remind you about?"; "Check whether I have an important email from the recruiter." → SearchGmail (Wren Dev not connected: says so); "Ask GPT." → ClarifyIntent; "Show the GPT result" → OpenDelegationResult; "What am I waiting for?" → QueryStoredItems | **Passed live** in Wren Dev |
| E-ROUTE-2 | Router | The same reminder submitted twice at once creates one reminder | **Passed live** in Wren Dev (`duplicate submission ignored`, one `execute CreateReminder`) |
| E-VOICE-1 | Voice | After launch nothing touches the microphone: voice phase `off`, Microphone and Speech Recognition still `notDetermined` (macOS never asked) | **Passed live** in Wren Dev |
| E-VOICE-2 | Voice | A transcript ("Hey Wren, ask GPT to research quantum physics and think carefully …") through the post-transcription step waits for review and then takes the typed path | **Passed live** in Wren Dev (`voice command awaiting review`) |
| E-VOICE-3 | Voice | Real microphone: shortcut and Voice button start one recording, the red indicator shows, pause/Stop ends it, the macOS microphone indicator goes off afterwards, Record again, Esc, screen lock cancels | **Not run**: needs a person to speak and to allow Microphone and Speech Recognition |
| E-REM-1 | Reminders | Delivery at the time while Wren is quit; Complete/Snooze from the notification | **Blocked**: notifications denied for Wren Dev (as in 0.9). Scheduling, reconcile-without-duplicates, recurrence, DST, snooze/move/complete/delete: mock-tested (`ReminderSchedulerTests`, `ExecutorJourneyTests`) |
| E-LIFE-1 | Lifecycle | Quit Wren Dev (Apple Event): process ends, status item removed, shortcuts released, data unlocked | **Passed live** |
| E-DATA-1 | Upgrade | Wren Dev's existing schema-6 data opens under schema 7 | **Passed live** (opened, commands ran on existing data) |

## Previous pass: 2026-10-11, branch `feat/audit-real-integrations` (0.9.0, schema 6), macOS 26, Apple Silicon

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
| M-VOICE-1 | Voice | Real microphone, "Hey Wren" (removed in 0.10), the voice shortcut, the listening orb, gated idle listening, pause on screen lock | **Not run**: needs a person to speak and to allow Microphone and Speech Recognition |
| M-VOICE-2 | Voice | A spoken command waits for review (editable, runs on Return) instead of acting | **Passed live** in Wren Dev (`voice command awaiting review`; no item created) |
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
1. ⌥ Space, type `search in GPT: explain quantum physics and give me a few useful beginner resources.`, Return.
   Expected: the card says "Ask ChatGPT · Request: Explain quantum physics and give me a few useful beginner resources." and "Sent to ChatGPT. You can close this; Wren will tell you when it's finished." No "You're not waiting on anything", no new item.
2. Press Return again and Esc. Expected: no second request (Delegate history shows one entry).
3. When it finishes: a notification "GPT has finished · Request: quantum physics and give me a few useful beginner resources" with View result. Click it.
   Expected: the main window opens on the result: what you said, what was sent, model, created/completed times, the answer as returned, Copy answer, Open ChatGPT. No "Open conversation" link (the plan API returns none).
4. Overview › GPT requests lists it as Completed. Quit and reopen Wren: still there.
5. Turn Wi-Fi off, ask `ask GPT to brainstorm names for my project`. Expected: Failed, retryable; Retry with Wi-Fi on completes the same entry (Attempts 2).
6. Ask something and quit Wren while it runs; reopen. Expected: the entry says Wren was closed before ChatGPT finished, with Retry.
7. Voice: press ⌥⇧ Space and say "ask GPT what quantum physics is." Expected: same as 1–3.
8. Thinking: `ask GPT to think deeply about whether I should learn Rust or Go first`. Expected: the card says "Asks for high reasoning effort"; the result page shows Kind Deep thinking and Reasoning "high (asked for and reported)" (or what the response actually reported).
9. Research: `ask GPT to research the fundamentals of quantum physics and cite sources`. Expected: the card mentions web search; the notification reads "GPT has finished · Research: the fundamentals of quantum physics …"; the result shows "Web search: Used: N searches" and a "Sources ChatGPT cited" list, or "Offered, but ChatGPT didn't search the web" when it didn't. Find in answer highlights matches.
10. If your workspace disallows web search: the request fails saying so, and **Run with standard settings** reruns it on the same entry without web search.

### M-GMAIL: inbox intelligence (needs the maintainer's Google setup, then a listed test account)
1. Connectors › Gmail › Connect Google, approve Gmail read. Expected: Gmail Connected; Inbox shows your account and "checked …".
2. Inbox: only unread inbox mail appears; nothing from Spam or Trash; each entry says "Why: …"; promotions sit under "Informational".
3. Correct › "Never important from …": that sender's mail moves to Informational and stays there after Check now.
4. Send yourself `Urgent: please sign by today`. Within the polling interval (default 5 min) a notification "Important email from <you>" with the subject and "Why: …" appears once, with **Open email** and **Snooze alert for 1 hour**. Choose Snooze: it disappears and comes back once about an hour later if still unread (not if you read it meanwhile). Click the alert itself: Wren opens that exact message, and it stays unread in Gmail. Check now again: no second alert. Reply in the same thread with the same urgency: no new alert.
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
4. ⌘Q while recording a voice command: the bird and Dock icon go and the macOS microphone indicator goes off. Wren no longer checks mail or records; already-scheduled reminders still arrive from macOS.

### M-PTT: push-to-talk (needs a person, a microphone, and Microphone + Speech Recognition allowed)

Run with `scripts/try-wren.sh` (Wren Dev) or the installed app, and keep its log open.

1. Launch Wren and close its window. Wait a minute. Expected: no orange microphone dot; log shows `push-to-talk ⌥ Space registered` and `hotkey ⌥⇧ Space registered`.
2. In TextEdit, press and hold ⌥ Space.
   - First time: macOS asks for Microphone, then Speech Recognition. Allow both and let go.
   - Expected: "Microphone access is set. Hold the shortcut again and speak." No space was typed into TextEdit.
3. Hold ⌥ Space and say "remind me to call Sam tomorrow at 10 AM"; let go.
   - Expected while holding: the panel shows "I'm listening…", the ring moves with your voice, words appear, and the orange dot is on.
   - On release (log `push-to-talk up`): the dot goes off immediately, then "Transcribing your voice…".
   - Then: the sentence, "Working on it…", and "Reminder created: Call Sam · Tomorrow at 10:00 AM". You don't press Return.
   - The log shows exactly one `execute CreateReminder`.
4. Hold, speak, and release **⌥ first** while still holding Space. Expected: log `push-to-talk modifier released`, and the same flow as step 3.
5. Hold ⌥ Space for a few seconds without speaking; let go. Expected: "Didn't hear anything, so nothing was done." No item is created.
6. Hold ⌥ Space and press Esc while speaking. Expected: "Cancelled. Nothing was done." The dot goes off.
7. "I need to finish the report by Friday" → a task due Friday. "What am I waiting for?" → the answer. "Ask GPT to research quantum physics" → "GPT request submitted" (or "ChatGPT isn't connected" with Connect ChatGPT and the request kept).
8. "Remind me every weekday at 3 PM" → "One quick question: What should I remind you about?". Hold again: "to stretch" → "Reminder created: Stretch", weekdays at 3 PM.
9. While "Working on it…" shows, press ⌥ Space repeatedly. Expected: nothing new starts; one execution in the log.
10. Mumble. Expected: "I'm not sure I heard that right…" and the words wait for Return or **Record again**.
11. Return after a result shows "Done" and closes the panel; it doesn't save the words again.
12. Hold ⌥ Space and lock the screen (⌃⌘Q). Expected: recording cancelled; nothing restarts after unlocking.
13. System Settings › Privacy & Security › Microphone › turn Wren off, then hold ⌥ Space. Expected: "Microphone access is off" with **Open Privacy Settings**, and no recording.
14. Settings: typed capture shows ⌥⇧ Space and opens the panel for typing. Connectors › Voice shows "Hold ⌥ Space" and can change or turn off the shortcut.
15. ⌘Q while holding ⌥ Space: the dot goes off and Wren quits.

### M-NOTION, M-CAL
As before: Connectors › Notion › Connect Notion (search, read, create after confirming, disconnect);
Connectors › Calendar › Use this Mac's calendars (allow, ask "what meetings do I have tomorrow?").
