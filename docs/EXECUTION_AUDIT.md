# Execution audit: from your words to a real result

Audit of how Wren turns what you type or say into an action, done for 0.12.0 on 14 October 2026.
Base: `main` at `231cf13` (0.11.1, PRs #17 and #18 merged). Branch: `fix/end-to-end-execution`.

**How it was done.** Each capability was traced through the code, stage by stage:

`input → routing → parameters → authorization → execution → persistence → verification → what you see`

Three sources of evidence were used:
- The routing of every example sentence in the brief, run through the router before any change.
- The diagnostic log of the installed app (`build/test-logs/wren-installed-20261014-1227.log`).
- Live runs of the rebuilt app, Wren Dev, and of the real Gmail account. They are listed in
  [MANUAL_TESTS.md](MANUAL_TESTS.md) under the 2026-10-14 evening pass.

A feature only counts as working below if it was verified by an automated test, a live run, or both.
Its UI existing is not enough.

## 1. The routing rules

There is one router, `CommandRouter.intent(for:)` in `Sources/WrenCore/CommandRouter.swift`. Every
entry point uses it:
- the capture panel
- push-to-talk and the Voice button
- the menu-bar "Add something…" field
- the debug command URL
- `wren-tools route`

It returns a structured intent with these fields:

| Field | Meaning |
|---|---|
| `operation` | `CreateTask`, `CreateReminder`, `UpdateTask`, `CompleteTask`, `QueryStoredItems`, `DelegateToChatGPT`, `OpenChatGPTRequest`, `FollowUpDelegation`, `AskLocalAI`, `SearchGmail`, `OpenEmail`, `MarkEmailRead`, `QueryCalendar`, `SaveNote`, `Capture`, `ClarifyIntent`. Each carries its parameters, for example a task's title and deadline, the request for ChatGPT, or the sender |
| `destination` | Wren's items, ChatGPT, local AI, Gmail, calendar, or you (a question back) |
| `rule` | Which rule decided. It is logged, and the log never contains your words |
| `confidence` | 0.95 for an explicit request ("remind me", "ask GPT"), 0.9 for "I need to…", 0.75–0.85 for weaker cues, 0.5 for a plain note |
| `request` / `content` | Your words without "can you" or "please", and what the outer request carries |

**The outer request decides.** The router first removes the words addressed to Wren about asking:
"Hey Wren", "can you", "could you please", "I want you to". It then reads only the start of what is
left.
- In "Remind me to ask GPT about quantum physics tomorrow", the request is *remind me*. The words
  "ask GPT about quantum physics" are the reminder's subject.
- In "Ask ChatGPT to remind me about my taxes", the request is *ask ChatGPT*.

Every pattern is anchored at the start, so a phrase inside the content can't change the action.

| Rule | Decides | Examples |
|---|---|---|
| A: reminders and tasks | A request to be reminded. A task request ("make a task to…", "add … to my list"). A first-person obligation ("I need to / have to / must / 've got to…"). A deadline statement ("the essay is due Friday"). An advance reminder on an existing task ("remind me one day before the deadline"). A change to an existing item (move, snooze, mark done) | "Can you make a reminder to call Sam tomorrow at 10 AM?", "I need to submit the assignment by Friday." |
| B: explicit ChatGPT | ChatGPT is asked, told, used or searched, or named as where the work happens. Follow-ups such as "continue that research in ChatGPT" | "Search in GPT for research on agentic AI." |
| C: questions for Wren | Questions about your items, answered from the store. Other questions go to the local AI. "I need to know what X is" is a question, not a task | "What should I work on today?", "What is gradient descent?" |
| D: email and calendar | Questions and lookups about mail or meetings, and a named email action. A statement that only mentions email or a meeting is not a lookup | "Anything important in my inbox?", "What meetings do I have tomorrow?" |
| E: ask instead of guessing | No action ("Ask GPT."). A reminder without a time or subject. An ambiguous hour ("at 9"). A time that has passed | "Please set a reminder for tomorrow at 9 to pay rent" → "Is that 9 AM or 9 PM?" |

**The local model** is used only after the rules. It runs for input the rules leave as a plain note
that looks like a command or question, and its reading has to be grounded in your words
(`ModelCommandInterpreter`, `IntentRouter.isGrounded`). It never chooses the tool for a request the
rules have already read.

## 2. Each capability, stage by stage

| Capability | Routing | Parameters | Authorization | Execution and persistence | Verification | What you see | Evidence |
|---|---|---|---|---|---|---|---|
| Reminder | Rule A | `ReminderCommand` reads the title, the time and an optional stated deadline. It asks when something is missing | Broker, `reminders` permission, audited | `ItemExecution.createReminder` → store | `ReminderScheduler.reconcile`, then macOS's accepted identifiers are read back | "Reminder created: …", the time, and macOS's real state | Unit and acceptance tests. **Live** in Wren Dev |
| Task with a deadline | Rule A | `TaskDraft`: the title without the framing and the date, and the deadline exactly as said | Broker, interpretation rule | `ItemExecution.createTask` → store | Reconcile and read back. The day-before heads-up and the reminder on the day are each checked | "Task created: …", the deadline, both reminder times and macOS's state | Tests. **Live** |
| Change, complete, snooze, advance reminder | Rule A | `ContextResolver` finds the item from the reference or the context | Proposal, then your confirmation, then the broker | Store | Handler checks, reconcile | Preview, then the result | Tests. **Live** |
| ChatGPT website | Rule B | `AIRequest`, with the request kept as you said it | `chatgpt.handoff` permission. Secrets go to review first | `chatgpt.com/?q=` opened in your browser, record saved | Address-only tab watching (opt-in) sees `/c/<id>` | "Prompt loaded, submission unverified", later "Submitted to ChatGPT" | B-1…B-5 and W-1/W-2 in MANUAL_TESTS. Routing and opening checked **live** again in this pass |
| ChatGPT in Wren | Rule B, in "run in Wren" mode | Same | Broker, `ai.delegate`, plan sign-in checked | `AskService` → Responses API on your plan | The provider's terminal status and model are recorded | "GPT has finished" notification and the result in Wren | AskService and DelegationLifecycle tests. **Live** on 2026-10-13 (E-GPT) |
| Local question | Rule C | Your question | None (it stays on this Mac) | Ollama, then a saved record | The answer is stored with its source | The answer in the panel | Tests. **Live** before (W-1) |
| Stored question | Rule C | `QueryKind` | None | Read from the store only | Every line names its record | The answer | Tests. **Live** ("What should I work on today?") |
| Gmail question | Rule D | A Gmail query from your words | Broker `email.read`, using the account you authorized | A live Gmail search | Gmail's response | An answer with reasons, or the connector's real state | Tests. **Live**: the disconnected path in Wren Dev, and sync against the real account |
| Gmail alerts | None (background, while Wren runs) | None | Rule `monitorConnectedEmail` | `MailSync`: full sync, then `history.list`, with a full sync again when the cursor expires | Deduplicated by message. Spam and Trash are excluded | One notification each, with the sender, subject, an excerpt and the reason. A click opens that conversation in Gmail | Tests. **Live**: sync, dedupe, and the Gmail link |
| Daily briefing | Schedule | Built from stored items and connected sources | `notify` | `WrenEngine.tick`, with the `DailyRun` ledger saved before delivery | At most once a day, even after a restart | One notification and the briefing view | Tests (DailyTests). Not run live this pass |
| Quit | None | None | None | `stopBackgroundWork`, then the microphone, shortcuts and lock are released | Log line | None | **Live** |

## 3. Defects found and fixed

Every defect below was observed before the fix, either in the routing probe of the brief's sentences
or in the installed app's log. The tests named under **Tests** fail without the fix.

### D-1. "Can you make a reminder to call Sam tomorrow at 10 AM?" went to "who should answer?" (local AI or ChatGPT)

- **Observed.** Installed log, 20:38:40: a 58-character voice command was logged as
  `execute AskLocalAI … command result: general question (choose who answers)`. With no local AI
  set up, the panel offered Open in ChatGPT. "Could you remind me to …?" did the same.
- **Root cause.** `ReminderCommand.parse` (`Sources/WrenCore/ReminderCommand.swift`) only recognised
  a sentence that *started* with "remind me", "set a reminder" and similar. A polite wrapper didn't
  match, so `ExecutionRouter` fell through to "it's a question". The text started with "can" and
  ended with "?", so it became a general question.
- **Expected vs actual.** Expected `CreateReminder` "Call Sam", tomorrow 10:00. Actual: a
  local-or-ChatGPT choice.
- **Fix.** `CommandGrammar.request` removes words addressed to Wren. `ReminderCommand.canonical`
  reads every reminder phrasing: "make/create/set/add/schedule a reminder", "don't let me forget",
  "I'd like a reminder", "ping me", "Reminder:", and "Tomorrow at 9, remind me to…". `parse` uses it,
  so follow-up answers benefit too.
- **Tests.** `CommandRouterRulesTests.testRuleA_RemindersAndTasksAreNeverDelegated` and
  `EndToEndAcceptanceTests.testReminderIsPersistedScheduledAndNeverAGPTRequest`. **Live:** E2E-1.

### D-2. "I need to send the proposal before the meeting." went to the calendar

- **Root cause.** In `ExecutionRouter` (before this change), a statement that wasn't otherwise
  matched was checked for the words "meeting", "calendar" or "email" anywhere, before task framing.
  "I need to email Sam by Friday" became a Gmail search the same way.
- **Fix.** Obligation frames are read first. Gmail and calendar are used only for questions and
  lookups ("anything…", "do I have…", "check…").
- **Tests.** Rule A and Rule D tests. **Live:** E2E-7.

### D-3. A destination inside a task beat the task

- **Observed.** "I need to research agentic AI in ChatGPT by Friday" became `DelegateToChatGPT`.
- **Root cause.** `IntentRouter.destinationRequest` matches "in GPT" anywhere, and it was tried
  before task framing.
- **Fix.** Rule A frames are read before rule B, and every frame is anchored at the start. The words
  "in ChatGPT" are now part of the task's title.
- **Tests.** `testTheOuterRequestDecidesAndTheNestedContentIsKept`.

### D-4. Questions about your own work went to the local AI

- **Observed.** "What should I work on today?" and "What deadlines are approaching?" became
  `AskLocalAI`.
- **Root cause.** `ContextResolver.queryKind` had no kind for today's focus, and its "due soon"
  patterns didn't include deadline wording.
- **Fix.** A new `QueryKind.today` covers overdue items, items due today, today's reminders and items
  marked important. "Due soon" now matches "deadlines approaching", "upcoming deadlines" and
  "what's due".
- **Tests.** `testRuleC_QuestionsForWrenStayLocal`. **Live:** E2E-6.

### D-5. "Remind me one day before the deadline." created a new reminder

- **Root cause.** The reminder parser ran before the item-change grammar. That grammar only knew
  "remind me about X the day before it's due".
- **Fix.** `CommandGrammar.advanceReminder`, shared with `ContextResolver`, routes it to
  `UpdateTask`. The item is the one on screen or the most recent one, and a preview must be confirmed
  before anything changes.
- **Tests.** Rule A tests. **Live:** E2E-9.

### D-6. More than one router, and an entry point with none

- **Root cause.** There were three separate paths:
  - `AppModel.execute` ran its own reminder check before `ExecutionRouter`.
  - `IntentRouter.route` was a second router with different rules.
  - The menu-bar field (`PopoverView`) saved text without routing it at all.
- **Fix.**
  - `CommandRouter` decides once, and `AppModel.execute` dispatches on its decision.
  - `IntentRouter.route` is now a coarser view of the same decision.
  - The menu-bar field runs through the capture panel's pipeline.

### D-7. The executor second-guessed the router

- **Root cause.** For `UpdateTask`, `QueryStoredItems` and plain notes, `AppModel.execute` first
  called `connectorAnswer`, which used its own keyword checks. As a result:
  - "Move the meeting prep task to Sunday" could be answered from the calendar.
  - A note that mentioned mail could start a Gmail search.
- **Fix.** Each operation runs only its own subsystem. Gmail and calendar run only for rule D.

### D-8. Tasks were saved without confirming their deadline or reminder

- **Root cause.** `CreateTask` saved the text and closed the panel with "Saved". The deadline and
  reminder were applied later, in the background. Nothing checked what macOS had accepted.
- **Fix.** `ItemExecution.createTask` (`Sources/WrenCore/CommandExecution.swift`) works in order:
  1. It saves your words first.
  2. It applies the reading through the broker.
  3. It schedules, then reads back what macOS accepted.

  The reply lists the deadline, each reminder time and macOS's real state, and it is never
  "scheduled" unless macOS accepted it.
- **Tests.** `testTaskWithDeadlineGetsTheDayBeforeAndOnTheDayReminders`. **Live:** E2E-2.

### D-9. A reminder's time was stored as a deadline

- **Root cause.** `WrenStore.createReminder` set `deadline` to the reminder time. A reminder then
  looked "due" at that time and turned "overdue" afterwards, and "move that reminder" moved a
  deadline you never set.
- **Fix.** The deadline, the reminder time, the notifications and the status are separate facts. A
  reminder has a deadline only if you state one ("remind me to submit the form by Friday at 5 PM").
  Moving a reminder that has no deadline moves its time.
- **Tests.** `testReminderIsPersistedScheduledAndNeverAGPTRequest` and
  `testReminderWithByKeepsTheDeadlineAndTheReminderTime`. The existing test
  `testMoveThatReminderToSundayTargetsTheRecentItemAndNeedsConfirmation` was updated.
- **Existing data.** Reminders created before 0.12 keep their stored deadline. Nothing is rewritten.

### D-10. No heads-up before a deadline

- **Fix.** `ReminderPolicy.advanceReminder` and `DeadlineAdvance` add one notification the day before
  a task's deadline, at your default reminder time. The setting is
  **Settings › Notifications › Also remind me the day before a deadline**, on by default.
- **Rules.**
  - It applies only when the reminder follows the deadline. A reminder time you pick yourself
    replaces it.
  - It applies only to a deadline set at least a day ahead, so "call the landlord tomorrow" gets no
    same-day extra.
  - It has its own identifier: once per task and time, moved with the deadline, and removed when
    the task is done.
  - Its notification offers only Done, so snoozing it can't move the real reminder.
- **Tests.** Four tests in `EndToEndAcceptanceTests`.

### D-11. Task titles lost letters

- **Observed.** "Create a task to submit the application next Monday" became "Submit the applicati".
- **Root cause.** When the date phrase was removed, the optional connector "on" matched the end of
  "application". This happened in `IntentProcessor.rulesOnly` and in the model path.
- **Fix.** The connector must be a whole word.
- **Tests.** `testTaskTitlesAndDeadlinesComeFromTheWords`.

### D-12. Email alerts didn't open the email in Gmail

- **Root cause.** A click opened Wren's own message view. The Gmail address format
  (`EmailMessage.webURL`) had never been checked against a real account, and the alert had no
  summary.
- **Fix.**
  - The alert adds the first sentence of Gmail's own preview text, about 120 characters at most.
    Inbox settings can turn it off. It is built on this Mac and never sent to an AI service.
  - A click on the alert opens that conversation in Gmail.
  - **Show in Wren** is the fallback, alongside **Open in Gmail**, Snooze and Dismiss.
- **Verified live.** M-GMAIL-LINK: the link opened the right conversation in the authorized account.
- **Tests.** `testAlertTextNamesTheSenderSubjectAShortExcerptAndTheReason`,
  `testEmailAlertOpensThatConversationInTheRightAccount`, and a test that old mail preferences
  still load.

### D-13. An expired Google sign-in said "Gmail isn't connected"

- **Fix.** `AppModel.connectorProblem` reports the connector's real state. Examples: "needs you to
  sign in again … your question wasn't answered from old data", missing permission, temporarily
  unavailable.

### D-14. Quitting relied on the process ending

- **Fix.** `AppModel.stopBackgroundWork` stops these at once and logs it:
  - mail checks and the next scheduled check
  - the reminder and briefing timer
  - pending reconciles
  - the ChatGPT tab watching

  Reminders macOS already holds stay scheduled.
- **Verified live.** E2E-12.

### D-15. Push-to-talk lost the first command after the permission prompt

- **Observed.** Installed log, 20:38:25–20:38:28.7:
  - The press began during macOS's permission prompt.
  - Recording started at 28.000.
  - The key-up arrived at 28.049, so the press was measured as 2,064 ms.
  - Wren stopped and reported "Didn't hear anything".
- **Fix.** A tap is judged by how long the microphone had really been recording. A short recording
  continues hands-free, until a pause.
- **Tests.** `VoiceTests.testListeningSinceIsWhenRecordingReallyBegan`.

### D-16. The morning briefing didn't separate tomorrow's work or important items

- **Fix.** The notification counts "due tomorrow" separately, and the briefing lists open items
  marked important. Each day's briefing is still recorded before delivery, so a restart can't send
  it twice.
- **Tests.** `BriefingContentTests` (updated).

### D-17. Slack was missing from Connectors

- **Fix.** Slack is listed as **Not implemented**, and nothing depends on it. Notion keeps its real
  status: it has working sign-in, search and confirmed page creation.

## 3a. Follow-up in 0.12.1: what live testing of 0.12.0 showed

### D-18. Spoken ChatGPT requests were answered by the local AI

- **Observed.** In the installed 0.12.0 (log 21:47:54 and 21:48:30), `route AskLocalAI (rule C question)`. The
  saved records hold the exact transcripts:
  - "Can you make a query at ChatGPT? What is the gradient descent machine learning?"
  - "Can you make a query, ChatGPT what is great in decent machine learning?"
- **Root cause.** `IntentRouter.aiRequest` knew ChatGPT as a destination only after "in, on, with, via,
  using, through or into", or right after a verb such as "ask". A request noun ("make a query") followed
  by "at", a comma or a question mark matched nothing, and the trailing "?" made it a general question.
  Speech spellings of the name ("chat G P T", "chat GBT") weren't recognised either.
- **Fix.** A request-noun pattern: make, send or start a query, question, request, search, chat or
  message, then any preposition, punctuation or nothing, then the name, then what to ask. There is also
  a polite vocative form ("Hey ChatGPT, …"). `IntentRouter.normalizeAssistantName` rewrites speech
  spellings of the name before routing; the request keeps the user's exact words. Naming GPT as a topic
  ("What is GPT?", "email the GPT team") still isn't a request.
- **Tests.** `ChatGPTDestinationTests`, which uses both transcripts word for word. **Live:** G-3.

### D-19. "GPT finished" over a local answer

- **Root cause.** `CaptureView.completedTitle` returned "GPT finished" for any card in the answered
  phase. It never looked at who answered.
- **Fix.** `AskCard.headline` (WrenCore) is built from the destination that really ran and its real
  phase: "Local AI answered", "ChatGPT answered, in Wren", or the website state's own label. A website
  request has no "finished" state. The voice outcome and the log use the same headline.
  - The completion notification is sent only for `chatgptPlan` records, as "ChatGPT finished (in Wren)".
  - `execute` clears the previous card, so a stale result can't show under a new command.
- **Tests.** `AskHeadlineTests`. **Live:** G-4.

### D-20. Answers saved but not shown

- **Observed.** In your screenshot of G-4, the 313-character answer was missing from the card.
- **Root cause.** `answerText` was a `ScrollView` with only a maximum height. In the panel it has no
  height of its own, so it collapsed to zero.
- **Fix.** The answer is now a text view, up to 14 lines, with a pointer to the full result in Wren.
  Checked in the new `capture-local-answer-*.png` snapshots.

### D-21. ChatGPT website requests could only wait for you

- **Context.** The website takes the question from the link but doesn't send it (B-1).
- **Fix.** **Send it for me** (`ChatGPTAutoSend`, `BrowserTabs.focus`, `KeyPresser`) is opt-in and off
  by default. Once the page has taken the question, Wren brings that exact tab forward and presses
  Return in that browser process only. It counts the question as sent only when the tab becomes
  `/c/<id>`, the conversation detection Wren already had. It needs two macOS permissions only the user
  can grant: browser control and Accessibility.
- **Tests.** The decisions are unit-tested in `ChatGPTAutoSendTests`. It was **not run live**, because
  this terminal can't press keys and Wren Dev has no Accessibility permission (G-6, steps M-SEND).

### D-22. A doubtful transcript went straight out

- **Fix.** `TranscriptAssessment.checkBeforeSending` holds a spoken request bound for ChatGPT with a
  reported confidence below 0.85 in the field for checking. The destination stays ChatGPT.
- **Tests.** `VoiceDestinationReviewTests`.

## 3b. Delivery audit in 0.12.2: reminders, deadline alerts, Gmail and briefings

Done on 16 October 2026 on the installed 0.12.1, after two days without visible reminders or email
alerts. Evidence: Wren's own log, Notification Center's log, Wren's database and mailbox file (read
from copies, counts and times only), then live runs listed in [MANUAL_TESTS.md](MANUAL_TESTS.md)
(P-1 to P-13).

| Stage | Reminders | Email alerts | Briefing |
|---|---|---|---|
| Saved | Yes | n/a | Ledger per day |
| Permission | Allowed, Banners | Same | Same |
| Scheduled / produced | Accepted by macOS | **No checks after an offline launch (D-24)**; mail already there never alerted (D-25) | `skippedEmpty`: nothing to report |
| Delivered | Yes, **twice** when Wren was running (D-23) | Digests delivered | n/a |
| Seen | **No: Do Not Disturb muted all of them** | Same | n/a |

### D-23. A reminder that fired while Wren was running was shown twice
Seen on 15 Oct at 10:00 in Notification Center's log: `wren.reminder.22C7….at.…` from macOS and
`reminder-22C7…` from Wren. The app reconciles with macOS before each tick. A request that had just
fired is no longer pending, so the reconcile dropped it from the item's `scheduledNotificationIDs`.
The engine then decided macOS hadn't scheduled it and delivered its own copy. The test only ticked
without reconciling, so it missed this. **Fix:** a fired request for the item's current reminder time
is kept until the engine records it (`ReminderScheduler.isFiredCurrentOccurrence`). New test:
`testReconcileAfterMacOSShowedAReminderDoesNotCauseASecondNotification`. Live: P-4, P-5.

### D-24. One failed mail check stopped mail checking until the user intervened
`checkMail` rescheduled itself only while Gmail was usable. Wren started offline (`-1009`), the
connector became "temporarily unavailable", and the timer was cancelled. Waking the Mac called the
same function, which returned at once. Nothing refreshed the connector. **Fix:** while Gmail is only
temporarily unavailable, each check refreshes it first and keeps polling with a growing delay (up to
6× the interval). The Inbox says it's retrying and when, and **Check inbox now** stays enabled. Only a
sign-out, revoked access or a build problem stops checking, and the Inbox now names that state
instead of "Gmail isn't connected".

### D-25. Important mail already in the inbox was never surfaced
The first sync marks everything as baseline, and alerts consider only newly arrived mail. Unread
urgent mail from before Wren connected only appeared in the digest. **Fix:** the **inbox review**
(`InboxReview`). Once, after the first successful sync, Wren lists unread mail from the last 14 days
that is urgent, time-sensitive or needs a reply. It sends one notification about it, also shown at the
top of the Inbox. It's recorded before delivery, so a restart doesn't repeat it. Mailboxes saved by
older versions get it once.

### D-26. Failed payments and payment deadlines were below the alert threshold
"Autopay failed" or "minimum amount due" only matched the generic financial rule, and the default
alert level covers urgent and time-sensitive mail. **Fix:** explicit rules, never applied to
promotions:
- failed or declined payments, autopay, insufficient funds; unrecognized or suspicious transactions;
  blocked, restricted or declined cards are **urgent**
- payment deadlines are **time-sensitive**, with the reason "payment deadline mentioned in this
  message"
- statements, receipts and transaction alerts stay **financial** (no alert)

Stored mail is re-read with the current rules on each sync (manual corrections stay). Alerts show the
most specific reason.

### D-27. Do Not Disturb hid everything, and Wren couldn't say so
Wren had no way to see what macOS did with its notifications. **Fix:** Settings › Notifications reads
macOS's settings (permission, alert style) and pending list. It shows reminders expected vs. pending,
the next one, the day-before setting, the last scheduling error, the failing stage and which app
bundle the permission belongs to. **Send test notification** schedules a real request and checks
macOS's delivered list. The panel says plainly that "delivered" isn't "seen" during Focus. Every
scheduling step, delivery, display and click is logged (`lifecycle op=…`), with identifiers and times
only. macOS gives apps no supported way to read the Focus state, so Wren explains it instead of
guessing.

### D-28. A task added the morning before got no day-before heads-up
The rule required the task to be created before the heads-up's day, so "Friday 5 PM", added Thursday
at 9 AM, had none. **Fix:** the deadline must be at least 24 hours after the task was created. New
test: `testATaskAddedTheMorningBeforeStillGetsItsHeadsUp`.

### D-29. A briefing could look delivered when it wasn't
The day's ledger said `sent` before delivery was tried. **Fix:** it says `undelivered` until macOS
accepts the notification, then `sent`. A restart still never sends it twice. Settings shows today's
real state.

## 4. Checked and unchanged

These were traced and found to work, with tests and earlier live evidence:

| Area | What was confirmed |
|---|---|
| ChatGPT authorization | "Continue with ChatGPT" checks that plan usage was granted, not only sign-in. There is no API-key path and no paid fallback (`openaiAPI` is retired). Expired sign-in, missing permission, usage limit and unsupported requests are separate outcomes (`AskOutcome`) |
| ChatGPT modes kept apart | Website requests are never "completed". Results run in Wren are labelled as not being ChatGPT conversations. A failed website request is never answered by the local model or the plan API |
| No duplicate requests | `SubmissionGuard` blocks the same words twice within 3 seconds. A website request isn't reopened within 15 seconds. `AskService` joins an identical request that is already running |
| Gmail sync | A full first sync, then `history.list`, with a full sync again when the cursor expires (`GmailSyncError.historyExpired`). Messages are deduplicated by ID. Spam and Trash are excluded. Unread and Important come from Gmail's labels. Token refresh and reconnect work. The last sync time and errors are kept in `MailboxState` |
| Mark as read | Needs the separate `gmail.modify` grant, which is checked, plus your click. It is done only after Gmail confirms the label change. Wren has no code to send or delete mail |
| Digest and briefing | The digest's key is saved before delivery, so it isn't repeated after a restart. When the email digest is on, the briefing leaves mail out so it isn't sent twice |
| Reminders | Reconciled on launch, wake, clock or time-zone change and any store change. Stale requests are removed and nothing is scheduled twice. Done, snooze and tomorrow from a notification go through the broker and are deduplicated |
| Launch at Login | Opt-in, off by default (Settings › Startup) |

## 5. Tests performed

| Kind | What | Result |
|---|---|---|
| Automated | `swift test`: 388 tests, including 22 new routing and acceptance tests and 3 new mail-alert tests | 0 failures, 4 skipped (live-only tests that need environment variables) |
| Mock-based | `FakeReminderCenter` stands in for macOS notifications. `FakeGmail` and recorded responses stand in for Gmail and ChatGPT | Part of the automated run |
| Live, Wren Dev | Wren Dev built from this branch, driven by `wren-dev://debug/command`, with the log recorded | See MANUAL_TESTS.md, E2E-1 to E2E-12 |
| Live, real account | `wren-tools live-check gmail` (read-only), and the Gmail thread link opened in Chrome | Passed: M-GMAIL-LINK and E2E-13 |
| Not run live | Notification delivery while quit, with permission granted. A new urgent email arriving (Test 7). The briefing at its scheduled time (Test 8). Voice with a person | Each needs you at the Mac or a new email in the inbox. Steps are in MANUAL_TESTS.md |
| 0.12.2, installed app | Real scheduling and delivery on `/Applications/Wren.app` with real permission: P-1 to P-7 | Passed live: delivered while quit, while running in the background, no duplicates, day-before scheduling, withdrawal on completion. Not run: click-through and Done (P-8), switching permission (P-9). Blocked: a visible banner while Do Not Disturb is on (P-10), and all live Gmail tests (B-1) |

## 6. Genuine blockers

These need the maintainer or the user. They aren't code defects:

0. **B-1, 16 Oct: Google refuses Wren's client secret.** A direct token refresh returns
   `401 invalid_client: The provided client secret is invalid`. The same secret is built into the
   installed 0.12.1, so Gmail and Google Calendar fail in every build until a valid secret from
   Wren's desktop OAuth client is in `config/providers.env` and Wren is rebuilt. **Resolved the same day:** a new secret was issued, the refresh returned 200, and the rebuilt app
   synced and sent the inbox review (MANUAL_TESTS P-11a).

1. **ChatGPT website submission.** OpenAI provides no supported way for an app to send a message
   into your ChatGPT conversation or to read its answer. Wren fills in the question; you press Enter.
   With detection on, Wren sees the conversation's address. This is a platform limit, and Wren states
   it instead of working around it.
2. **Google verification.** `gmail.readonly` and `gmail.modify` are restricted scopes. While Wren's
   Google app is in testing mode:
   - only accounts on its test-user list can connect
   - Google asks them to reconnect every 7 days

   Publishing for everyone needs Google's verification, including a security assessment for
   restricted scopes. That is maintainer work ([MAINTAINER_SETUP.md](MAINTAINER_SETUP.md)).
3. **Signing.** Ad-hoc-signed builds get new macOS permissions after each rebuild. This was seen in
   the log at 20:38, when Microphone and Speech were asked for again after a reinstall. Developer ID
   signing and notarization fix it, and need the maintainer's Apple account.
4. **Live checks that need you.** Notification delivery and click-through with permission granted,
   an email you send yourself, the morning briefing at its time, and push-to-talk with your voice.
   They are listed in MANUAL_TESTS.md as **Not run**, not as passed.
