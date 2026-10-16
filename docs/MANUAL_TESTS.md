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

## Last pass: 2026-10-16, branch `fix/p0-delivery` (0.12.2), installed app

What triggered it: two days of using the installed 0.12.1 without seeing reminders or email alerts.
This pass ran on **the installed app itself**: a debug build of this branch with the real bundle ID
(`com.shibadityadeb.wren`) at `/Applications/Wren.app`, so with your notification permission, data and
Google sign-in. The previous 0.12.1 was backed up to `build/Wren-0.12.1-backup.app`. Debug URLs use
`wren://debug/…` in that build. Evidence: Wren's log and Notification Center's own log
(`log stream … process == "NotificationCenter"`).

**Audit of the installed 0.12.1 (logs from 13–16 Oct, read-only):**
- macOS permission: **Allowed, Banners** (`debug health`). Not the cause.
- **Do Not Disturb on since 14 Oct 21:26** (`activeModeIdentifier=com.apple.donotdisturb.mode.default`, no later change). Every Wren notification was delivered into Notification Center **muted** ("muted by DND suppression: delay", `isMuted: true`). Still on during this pass.
- The 10:00 reminder on 15 Oct was posted **twice**: `wren.reminder.22C7….at.…` (macOS) and `reminder-22C7…` (Wren). Defect D-23.
- Wren started at 09:59 on 15 Oct while offline (`Network error -1009`). Gmail was marked unavailable and never checked again: the mailbox file was last written at 00:28 that day. Defect D-24.
- Mailbox: 182 messages, 0 alerts ever. 3 unread urgent, 1 time-sensitive and 10 financial, all from before monitoring started (baseline, never alerted). Defects D-25, D-26.
- Briefings 14–16 Oct: `skippedEmpty`. Correct for the data (no deadlines; Gmail and Calendar unreachable). Digests of 13 and 14 Oct: delivered, muted by Do Not Disturb.
- **Google now refuses Wren's client secret** (`401 invalid_client: The provided client secret is invalid`, from a direct token refresh). Identical in 0.12.1 and this build. Blocker B-1.

| Kind | Meaning |
|---|---|
| Automated | `swift test`: 406 tests, 0 failures, 4 skipped (6 of them new in this pass) |
| Mock-based | Part of the automated run: `FakeReminderCenter` for macOS notifications, `FakeGmail` for Gmail |
| Real macOS scheduling | The request is in macOS's pending list (`lifecycle op=schedule … result=accepted`, `debug pending`) |
| Real delivery | macOS's Notification Center logged and listed it as delivered (`debug delivered`). This does not prove a banner was on screen |
| Real Gmail | Against the authorized mailbox |
| Scheduled-time briefing | The briefing at its configured time |

| ID | Test | Kind | Result |
|---|---|---|---|
| P-1 | Permission belongs to the installed app | Real | **Passed live**: `permission=Allowed style=Banners bundle=com.shibadityadeb.wren path=/Applications/Wren.app` |
| P-2 | Send test notification (15 s) | Real delivery | **Passed live**: `accepted, pending`, delivered at 11:34:30 (`delivered=true`). Notification Center: `isMuted: true` (Do Not Disturb), so no banner |
| P-3 | Reminder 2 minutes ahead: saved, pending, Wren fully quit before it's due | Real scheduling + delivery | **Passed live**: saved (`pending`, next 11:36:47 in the database), `expected=1 pending=1`, Wren quit 11:35:04, macOS delivered it at **11:36:47** with Wren not running |
| P-4 | Relaunch after P-3: no second notification | Real | **Passed live**: `reminders due: 1 recorded as shown`, the delivered list holds only macOS's request, and Wren posted no `reminder-…` copy |
| P-5 | Reminder 1 minute ahead while Wren runs in the background (Chrome in front) | Real delivery | **Passed live**: delivered once at 11:39:15, recorded, no copy from Wren. This is the D-23 case, which failed in 0.12.1 |
| P-6 | Task due Sunday 5 PM (2 days ahead) | Real scheduling | **Passed live**: `before` request Saturday 10:00 and `at` request Sunday 17:00, both pending (`expected=2 pending=2`). Delivery on those days not observed |
| P-7 | Completing that task | Real | **Passed live**: both requests cancelled, `expected=0 pending=0` |
| P-8 | Click a reminder: opens the task. **Done** completes it and removes it | Real | **Not run**: needs a click from you. Steps M-FIRE |
| P-9 | Permission turned off: Wren reports the blocker; turned back on: reminders rescheduled | Real | **Not run**: needs you to switch it in System Settings. Covered by tests with the fake center |
| P-10 | A banner actually on screen | Real | **Blocked**: Do Not Disturb is on. Turn it off, or allow Wren in Focus, then use Send test notification |
| P-11a | After a new client secret (same day, 12:22): real sync and the inbox review on the installed release build | Real Gmail | **Passed live**: `wren-tools live-check gmail`: full sync 150 messages, incremental 0 new. The installed app: `incremental sync ok, 30 new, 154 kept`, `inbox review: 4 need attention; notification accepted by macOS: true`, shown at 12:22:50. Today's digest was delivered too. None of the 30 new messages met the alert threshold. B-1 is resolved |
| P-11 | Gmail: urgent mail from another account, Open email, snooze, no duplicate, expired sign-in, window closed, stops on quit | Real Gmail | **Not run** (needs an email from another account and your clicks). Before the new secret: **Blocked (B-1)**: Google refuses the client secret, so no real sync is possible from any build. The code paths are unit-tested (mock-based). New triage rules checked offline against your stored mailbox (counts only): 2 unread messages moved up (a failed payment, a near deadline); the review would list 6 |
| P-12 | Gmail unreachable at launch: checking resumes | Real | **Not run live** (needs Gmail to work first, B-1). In this build Wren correctly stops polling on `invalid_client` and the Inbox now says why |
| P-13 | Briefing at its scheduled time; no duplicate after restart | Scheduled-time | **Not run**: today's briefing already ran (`skippedEmpty` at 11:09). To test: set **Briefing at** a few minutes ahead tomorrow morning |

### Steps for you (0.12.2)

1. **Do Not Disturb.** Turn it off in Control Center, or add Wren to the allowed apps in System Settings › Focus › Do Not Disturb. Then Settings › Notifications › **Send test notification**: a banner should appear in 10 seconds.
2. **Google client secret (B-1).** Google Cloud Console › the project with Wren's desktop OAuth client › Credentials › that client. If its secret was reset, add a new secret. Put it in `config/providers.env` as `WREN_GOOGLE_CLIENT_SECRET`, rebuild (`scripts/build-app.sh release`) and reinstall. Then Inbox › **Check inbox now**: expect the inbox review notification.
3. **M-FIRE.** `remind me to test Wren in 2 minutes`, wait for it, click it (the item opens), then do it again and choose **Done** (the item is completed and the notification goes).
4. **Urgent mail.** From another account, send yourself "Your autopay failed". Within 5 minutes: one alert "Important email from …", Why: "says a payment failed or was declined". Click: Gmail opens that conversation.

## Previous pass: 2026-10-14 night, branch `fix/chatgpt-destination-and-reminders` (0.12.1)

What triggered it: in the installed 0.12.0, two spoken "ChatGPT" requests were answered by the local AI,
and the panel said "GPT finished". The exact words came from the installed app's own records:
- "Can you make a query at ChatGPT? What is the gradient descent machine learning?" (confidence 0.78)
- "Can you make a query, ChatGPT what is great in decent machine learning?"

The router knew "in/on/with ChatGPT" but not "at ChatGPT", a comma before the name, or a question mark
in the middle, so both read as general questions. The heading said "GPT finished" for any answered card,
whoever answered. Automated: `swift test`, 400 tests, 0 failures, 4 skipped.

| ID | Test | Result |
|---|---|---|
| G-1 | Installed 0.12.0, voice: "Can you make a reminder to call Sam tomorrow at 10 AM" | **Passed live** (your run, 21:47): `CreateReminder`, `planned=1 accepted=1 authorized=true`, so macOS accepted the notification. Its delivery at 10:00 on 15 Oct is still to be seen (G-7) |
| G-2 | Installed 0.12.0, voice: the two ChatGPT sentences above | **Failed live** (your run, 21:48): `AskLocalAI`, headline "GPT finished". Fixed in 0.12.1 |
| G-3 | Wren Dev 0.12.1: the same two sentences, word for word | **Passed live**: `DelegateToChatGPT (rule B)`, prompts "What is the gradient descent machine learning?" and "What is great in decent machine learning?" (kept as heard). Chrome opened `chatgpt.com` with the question; the card read "Prompt loaded, submission unverified". Nothing was sent, and the tabs were closed |
| G-4 | Wren Dev 0.12.1: "What is gradient descent?" | **Passed live**: `AskLocalAI`, card "Local AI answered" (not "GPT finished"). Your screenshot of that run showed the answer missing from the card, though 313 characters were saved: the answer area had no height. Fixed, and checked in the `capture-local-answer-*.png` snapshots (`wren-tools snapshot`) |
| G-5 | Wren Dev 0.12.1: "Can you make a reminder for to call Sam tomorrow at 10 AM?" (the 20:38 transcript) | **Passed live**: `CreateReminder` "Call Sam". Notifications are denied for Wren Dev, and that was reported, not "scheduled" |
| G-6 | Send it for me: Wren presses Enter in the ChatGPT tab it opened, and "Submitted to ChatGPT" appears only when the tab becomes `/c/…` | **Not run live**: needs you to allow Wren in Accessibility and browser control (steps M-SEND). Its decisions are unit-tested (`ChatGPTAutoSendTests`). This terminal isn't allowed to press keys, so it couldn't be tried from here |
| G-7 | A scheduled reminder fires, and Done withdraws it | **Not yet observed** (steps M-FIRE). 0.12.1 logs `notification shown: reminder (scheduled)` and `notification opened: …` so the log proves it |
| G-8 | A doubtful spoken ChatGPT request (confidence below 0.85) waits in the field for checking | Automated (`VoiceDestinationReviewTests`). **Not run live** (needs your voice) |

### Steps for you (0.12.1)

Record a log first: `scripts/try-wren.sh --installed`, or the `log stream` line at the top of this page.

**M-GPT: ChatGPT means ChatGPT**
1. Hold ⌥ Space and say "Can you make a query at ChatGPT, what is gradient descent in machine learning?".
2. Expected: ChatGPT opens with the question in its box. The panel says "Prompt loaded, submission unverified", or "Check the words I heard" if the recogniser wasn't sure. Never "Local AI" or "GPT finished".
3. Log: `route DelegateToChatGPT … (rule B …)`, `ask card: Prompt loaded, submission unverified`.
4. Hold ⌥ Space and say "What is gradient descent?". Expected: "Local AI answered", with the answer visible in the card. Log: `ask card: Local AI answered`.

**M-SEND: Send it for me (optional)**
1. Connectors › ChatGPT: turn on **Detect when I send it**, and allow Wren to control Chrome when macOS asks.
2. Turn on **Send it for me**. macOS opens Accessibility: switch Wren on.
3. Say "ask GPT what gradient descent is". Expected:
   - Chrome comes forward with the question in the box, and Enter is pressed once.
   - The card goes to "Submitted to ChatGPT", and **Open conversation in ChatGPT** opens that exact `chatgpt.com/c/…`.
   - Log: `send for me: tab focused=true Return pressed=true`, then `conversation detection: ChatGPT conversation created`.
4. If ChatGPT doesn't start a conversation within 20 s, the card says so and asks you to press Enter. It never says "Submitted".

**M-FIRE: a reminder really fires**
1. Type `remind me to stretch in 2 minutes`. Expected: "Reminder created: Stretch … Scheduled with macOS", and log `reminder created: planned=1 accepted=1`.
2. Quit Wren (⌘Q) and wait. Expected: the notification appears on time.
3. Reopen Wren. Expected: no second notification. Log: `reminders due: 1 recorded as shown`.
4. Repeat with Wren running and click **Done**. Expected: log `notification opened: reminder (scheduled) action=WREN_DONE`, and the item is completed.

## Previous pass: 2026-10-14 evening, branch `fix/end-to-end-execution` (0.12.0)

Automated: `swift test`, 388 tests, 0 failures, 4 skipped. The brief's ten acceptance scenarios have automated
versions in `EndToEndAcceptanceTests` and `CommandRouterRulesTests`. Those use `FakeReminderCenter` for macOS,
so they are **mock-based**, not live.

Live runs in this pass:
- **Wren Dev.** Built from this branch with `scripts/build-app.sh debug --dev-identity`, driven with
  `wren-dev://debug/command?text=…` and read from its log. Wren Dev has notifications **denied**, so these runs
  check routing, saving and the honest "notifications are off" report, not delivery. It isn't signed in to
  Google or ChatGPT.
- **The real Google account.** The account the installed Wren uses, read-only.

The installed Wren and its data weren't touched.

| ID | Test | Result |
|---|---|---|
| E2E-1 | "Can you make a reminder to call Sam tomorrow at 10 AM?" (brief test 1) | **Passed live**: `CreateReminder → wren (rule A reminderRequest, 0.95)`, "Reminder created: Call Sam". One notification planned, 0 accepted, reported as "notifications are off for Wren" (not "scheduled"). No GPT request |
| E2E-2 | "I need to submit the assignment by Friday." (test 2) | **Passed live**: `CreateTask (rule A obligation)`, "Task created: Submit the assignment", deadline Friday, **2 notifications planned** (the day before and on the day), 0 accepted (denied, and reported so) |
| E2E-3 | "Remind me to ask GPT about quantum physics tomorrow." (test 3) | **Passed live**: `CreateReminder`, "Reminder created: Ask GPT about quantum physics". Nothing sent to ChatGPT |
| E2E-4 | "Ask GPT to research quantum physics." (test 4) | **Passed live**: `DelegateToChatGPT → chatgpt (rule B)`, prompt "Research quantum physics." (website mode, the default). Chrome opened a new `chatgpt.com` tab; the `?q=` parameter was consumed, and nothing was sent. The composer's contents weren't machine-checked; B-1 below covers that. The tab was closed afterwards |
| E2E-5 | "What is gradient descent?" (test 5) | **Passed live**: `AskLocalAI → localAI (rule C)`, no ChatGPT |
| E2E-6 | "What should I work on today?" | **Passed live**: `QueryStoredItems (today)`, an answer from stored items |
| E2E-7 | "I need to send the proposal before the meeting." | **Passed live**: `CreateTask`, not the calendar. No deadline invented; reported as "No deadline was given" |
| E2E-8 | "Anything important in my inbox?" with Gmail not connected (test 6, disconnected branch) | **Passed live**: `SearchGmail → gmail`. Replied "Gmail isn't connected. Open Connectors › Gmail to connect it." No answer from memory |
| E2E-9 | "I need to finish the essay by Saturday.", then "Remind me one day before the deadline.", then confirm | **Passed live**: `UpdateTask (advanceReminder)`. Preview "Remind you about “Finish the essay” Friday at 10:00 AM". It ran only after the confirmation (`auth=your confirmation`) |
| E2E-10 | "Remind me to call Sam today at 9 AM" at 21:20 (test 9, invalid time) | **Passed live**: refused, "Today at 9:00 AM has already passed…". Nothing saved |
| E2E-11 | The same reminder sentence twice, 0.3 s apart | **Passed live**: one reminder; the second was refused with "That was just submitted, so Wren didn't do it twice." |
| E2E-11b | "Mark the essay as done", then confirm | **Passed live**: `CompleteTask`, with a preview first |
| E2E-12 | Quit Wren Dev (test 10, Wren's half) | **Passed live**: log "quit: mail checks, scheduler and conversation watching stopped; scheduled reminders stay with macOS", then "status item removed, shortcuts released". Process gone. macOS keeping scheduled reminders after quit is **not re-run** here because Wren Dev has notifications denied; see M-REM |
| E2E-13 | `wren-tools live-check gmail` against the real account (read-only) | **Passed live**: full sync of 150 messages (Spam and Trash 0), history cursor saved. A second, incremental sync found 0 new. The alert dry run would alert 3 + 2 summarized, and **0 on a repeated check** |
| M-GMAIL-LINK | Wren's Gmail link for an alert (`https://mail.google.com/mail/?authuser=<account>#all/<thread id>`), opened in Chrome for a read message in a multi-message thread | **Passed live**: Gmail opened that conversation in the authorized account. The tab title had the message's subject and the account, and Gmail rewrote the address to its own form. A message already read was used, so nothing was marked read. The tab was closed. The script printed only matches, not content |
| E2E-14 | A new urgent email arrives and gets one alert, which opens in Gmail when clicked (test 7) | **Not run**: needs a new email sent to the account by a person. Link and dedupe are covered by M-GMAIL-LINK and E2E-13 |
| E2E-15 | Morning briefing at its time, and no second one after a restart (test 8) | **Not run** live (it needs the scheduled time). Automated: `DailyTests` |
| E2E-16 | Notification delivery and click-through with permission granted, including after quitting | **Not run** in this pass. Needs a build with notifications allowed and a person to watch (M-REM) |

## Previous pass: 2026-10-14, branch `feat/ask-in-chatgpt` (0.11.1), Chrome (default browser), signed in to ChatGPT

Automated: `swift test`, 363 tests, 0 failures, 4 skipped. Live checks used the maintainer's real Chrome, observed
through Chrome's AppleScript (tab address and title only; screen capture isn't available to this terminal).
The maintainer was in a video call, so the second link was opened in the background (`open -g`).

| ID | Test | Result |
|---|---|---|
| B-1 | `open "https://chatgpt.com/?q=What is gradient descent in machine learning?"` (URL-encoded) in the signed-in Chrome | **Observed live**: the address went from `/?q=…` to `https://chatgpt.com/` (the parameter was consumed); **no `/c/…` conversation was created in 40 s**, so it was **not auto-submitted**. Whether the text sat in the composer couldn't be seen (no screen access); community reports and the consumed parameter suggest it does. Confirm in M-ASK 1 |
| B-2 | `?prompt=Explain the difference between L1 and L2 regularization in one paragraph.` | **Observed live**: the same (consumed, nothing sent) |
| B-3 | Wren's tab-reading AppleScript against the real Chrome | **Passed live** after a fix: Chrome's `tab` keyword had replaced the field separator (the word "tab" came back), which would have made detection silently fail. It now returns `id<TAB>address` lines for ChatGPT tabs only |
| B-4 | Wren's watcher on a real send (`chatgpt.com/` → `chatgpt.com/c/…`), Sign-in required, Automation permission prompt | **Not run** in the app: needs the user to allow Wren to control Chrome and to press Enter in ChatGPT (M-ASK). Unit-tested with the addresses observed in B-1 |
| B-5 | Conclusion | The public website **offers no way for an app to submit a question**; Wren puts it in the box and the user sends it. Wren reports "Prompt loaded, submission unverified" until it sees the conversation |

## Previous pass: 2026-10-14, branch `feat/chatgpt-web-handoff` (0.11.0)

Automated: `swift test`, 353 tests, 0 failures, 4 skipped. Routing, conversation-link validation, launch links,
honest handoff states and card choices are unit-tested. The browser itself isn't: opening ChatGPT and
copying the request were not run from automation on this Mac, because the maintainer was using it
(the browser and clipboard are theirs).

| ID | Area | Test | Status |
|---|---|---|---|
| W-1 | Routing | "What is gradient descent?", "Help me understand this concept." → AskLocalAI, answered by the local model in Wren Dev (Ollama present) | **Passed live** in Wren Dev |
| W-2 | Follow-ups | "Open that in GPT." / "Continue that research." resolve to the most recent request and keep its tool (here: a local answer continued with the local AI) | **Passed live** in Wren Dev; the website branch of "open that in GPT" is mocked only |
| W-3 | Website handoff | Scenarios 1, 3, 4, 5, 8 in a real browser (opens chatgpt.com, request copied, Awaiting your submission, I sent it, Link conversation, open the exact conversation) | **Not run**: needs the user's browser and ChatGPT session (steps M-WEB) |
| W-4 | `?q=` link | What `chatgpt.com/?q=` does today (fill in / send / nothing) | **Not run**: can only be judged by a person looking at their browser; Wren keeps it off until they report it |
| W-5 | In Wren | Scenario 7 (result stays in Wren, labelled) | Mocked (UI labels); the plan API path itself passed live on 2026-10-13 (E-GPT-1/2) |
| W-6 | Not signed in | Scenario 6: Connect / Open in ChatGPT website instead, never the local model | Mocked (card logic) |

## Previous pass: 2026-10-14, branch `fix/push-to-talk` (0.10.1), macOS 26.1, Apple Silicon

Automated: `swift test`, 344 tests, 0 failures, 4 skipped (the push-to-talk state machine runs against a
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

### M-WEB: ChatGPT website and routing (needs a browser signed in to ChatGPT)

The scenarios are the same as docs/TESTING_GUIDE.md §5:
1. `Ask ChatGPT what gradient descent is`.
   - Expected: no provider question. The browser opens chatgpt.com, the request is on the clipboard, and the card shows "Awaiting your submission".
   - Delegate history has one entry with Mode "ChatGPT website (handoff…)".
2. `What is gradient descent?`. Expected: local AI answers. Without local AI, the choices are offered and nothing is sent.
3. `Ask GPT to research this topic: the history of the transistor`. Expected: "Research the history of the transistor." (or similar) is what's copied; the word "research" is kept.
4. Send it in ChatGPT, copy the conversation address, then in Wren: **I sent it**, then **Link conversation**.
   - Expected: "Submitted; completion not verified", then "Conversation linked", with the link shown on the request page.
   - A non-conversation address is refused.
5. `Continue that research in ChatGPT`. Expected: that exact conversation opens, and "Please continue this research and go further." is on the clipboard.
6. `Open that in GPT`. Expected: the exact conversation opens. With an unlinked request: chatgpt.com opens, and the reply says no link is saved.
7. Switch to *Run with connected ChatGPT in Wren*, disconnect ChatGPT, then `ask GPT what a monad is`.
   - Expected: Connect ChatGPT / Open in ChatGPT website instead. No local answer.
   - Connect, and ask again. Expected: the result in Wren, Mode "Run with connected ChatGPT in Wren…", no conversation button.
8. Press Return twice fast on a website request. Expected: one tab and one record. **Retry**/**Open in ChatGPT** reuses the record. No request is ever shown as Completed.
9. Connectors › ChatGPT › **Check it in my browser…** and record what `?q=` did. Only if it was filled in, turn on the experimental option and repeat step 1. Expected: the request is already in ChatGPT's box, and the status is "Opened in ChatGPT".

### M-ASK: Ask in ChatGPT (Chrome or another Chromium browser, signed in to ChatGPT)

1. `Ask GPT what gradient descent is`.
   - Expected: Chrome opens ChatGPT with "What is gradient descent?" in the message box. Nothing is on the clipboard.
   - The card says "Prompt loaded, submission unverified", and Delegate has one entry.
2. Press Enter in ChatGPT. Expected: ChatGPT answers in a new conversation in your account (it shows in ChatGPT's history).
3. On the card, **Detect conversation automatically…** → macOS asks to let Wren control Chrome → OK.
   - Ask a second question (`ask ChatGPT what quantum physics is`) and press Enter in ChatGPT.
   - Expected: within a few seconds the card says "Submitted to ChatGPT", and **Open conversation in ChatGPT** opens that exact chat.
   - The first question isn't touched or mixed up.
4. Sign out of ChatGPT in Chrome and ask again. Expected: "Sign-in required".
5. `What is gradient descent?` → local AI. Disconnect the in-Wren ChatGPT sign-in and ask GPT something → still the website, never local AI.
6. Connectors › ChatGPT › *Run with ChatGPT inside Wren* → the answer arrives in Wren, labelled as stored in Wren.
7. `ask GPT whether my password is hunter2` → not opened; asks you to check it in Delegate first.

### M-NOTION, M-CAL
As before: Connectors › Notion › Connect Notion (search, read, create after confirming, disconnect);
Connectors › Calendar › Use this Mac's calendars (allow, ask "what meetings do I have tomorrow?").
