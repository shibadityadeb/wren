# Changelog

Versions follow [semantic versioning](https://semver.org). The `VERSION` file is the source of truth; release tags are `v<VERSION>` (stable) or `v<VERSION>-preview.N` (prerelease).

## [0.12.0] (unreleased)

Wren does what you asked, and says exactly what it did.

- **One router, outer request first.** Typing, voice and the menu-bar field all go through `CommandRouter`. It reads what you asked Wren to do before what that's about, with explicit rules. The local model only helps with plain notes.
  - "Can you make a reminder to call Sam tomorrow at 10 AM?" and "Could you remind me to…" were offered to the local AI or ChatGPT. They now create the reminder.
  - "Remind me to ask GPT about quantum physics tomorrow" is a reminder for tomorrow. "I need to research X in ChatGPT by Friday" is a task.
  - "I need to send the proposal before the meeting" was a calendar question, and "I need to email Sam by Friday" a Gmail search. Both are tasks now.
  - "What should I work on today?" and "What deadlines are approaching?" answer from your items.
  - "Remind me one day before the deadline" changes that task, after a preview.
  - `swift run wren-tools route "…"` shows how a sentence is read.
- **Tasks are confirmed, not just saved.** "I need to submit the assignment by Friday" shows *Task created* with the deadline, each reminder time and what macOS really accepted. It never says "scheduled" when notifications are off or macOS refused.
- **A heads-up the day before a deadline**, at your default reminder time, plus the reminder on the day. Turn it off in Settings › Notifications. A reminder time you pick replaces both. Completing the task withdraws both.
- **A reminder time is no longer stored as a deadline.** "Remind me to call Sam at 10" doesn't make the item "overdue" at 10:01. "… by Friday at 5 PM" still sets a deadline. Existing items aren't changed.
- **Email alerts** include the email's first sentence (from Gmail's own preview, turn-off-able in Inbox settings). **Clicking one opens that conversation in Gmail**, in your account; checked on a real account. **Show in Wren** is a button.
- The morning briefing names what's **due tomorrow** and items you marked **important**.
- An expired Google sign-in now says so ("sign in again"), not "isn't connected", and never answers from old data.
- Quitting stops mail checks, timers and ChatGPT tab watching explicitly. Scheduled reminders stay with macOS.
- Push-to-talk: a key-up that arrives just after recording starts (for example after a permission prompt) now keeps listening hands-free, instead of "Didn't hear anything".
- Fixed: task titles could lose letters ("Submit the applicati" from "…application next Monday").
- Slack is listed as not implemented.
- docs/EXECUTION_AUDIT.md records each defect, its cause, the fix and the tests. No data version change.

## [0.11.1] (unreleased)

"Ask in ChatGPT" puts your question in ChatGPT, not on your clipboard.

- **Your question goes straight into ChatGPT's message box.** Wren opens the ChatGPT website in your normal browser, signed in to your own account, using a `chatgpt.com/?q=` link (undocumented by OpenAI). It no longer opens a blank page with the question on the clipboard.
  - Tested in Chrome on 14 October 2026: ChatGPT takes the question in **but doesn't send it by itself**, and `?prompt=` behaves the same. So you press Enter there; Wren says so instead of claiming it was sent.
  - Questions over 1,500 characters, the ChatGPT Mac app, or the link turned off fall back to copy-and-paste, labelled as such.
- **Detect conversation automatically** (opt-in; Chrome, Brave, Edge, Chromium, Vivaldi). Wren watches only the address of the ChatGPT tab it opened, through the browser's standard scripting; macOS asks you once.
  - When the tab becomes `chatgpt.com/c/…`, the question was really sent: Wren shows "Submitted to ChatGPT" and saves that exact link for **Open conversation in ChatGPT**.
  - A sign-in page shows "Sign-in required".
  - No page content, other tabs, cookies or passwords are read.
- Truthful states: Preparing request, Opening ChatGPT, Prompt loaded (submission unverified), Submitted to ChatGPT, Conversation available, Sign-in required, Failed to open. No "GPT finished" notification for the website: Wren can't see the answer.
- A question that looks like it contains a password, key or code isn't put in a link; you check it in Delegate first.
- "Run with ChatGPT inside Wren" is the name of the plan-API mode.

## [0.11.0] (unreleased)

ChatGPT as a real external tool, and routing that knows which tool you mean.

- **Naming GPT or ChatGPT always means ChatGPT**, in any phrasing ("can you ask in GPT …", "make a query in ChatGPT about …", "search in GPT for …"). It's never a "local or ChatGPT?" choice, and never answered by the local model. **A question that names no assistant goes to Wren's local AI**; with no local AI set up you get the choices, and a connected ChatGPT no longer takes those questions over.
- **"Ask GPT" opens the ChatGPT website by default**, with your request copied, so it becomes a normal ChatGPT conversation you send and continue there.
  - OpenAI offers no supported way for an app to create that conversation or see its answer, so Wren shows exactly what it knows: Opened in ChatGPT / Awaiting your submission / Submitted; completion not verified / Conversation linked / Failed to open. Never Completed.
  - **Link conversation** stores the real `chatgpt.com/c/…` address (validated, read from the clipboard only on click), and **Open in ChatGPT** then goes straight to it.
  - Optional, experimental: fill the request in with a `chatgpt.com/?q=` link, enabled only after you check it in your browser.
- **Run with connected ChatGPT in Wren** is now an explicit mode (setting, or **Run in Wren instead** per request): your plan through Sign in with ChatGPT, with the real answer stored in Wren and labelled as not being a ChatGPT conversation. Not signed in → Connect, or open it on the website instead.
- **Follow-ups keep their tool:** "continue that research", "ask it to go deeper", "find more sources", "open that in GPT". With nothing to refer to, Wren asks.
- Request pages show the destination, mode, real status, follow-up chain and, for website requests, the link and next steps.
- Data version 8 (new request fields; a backup is made before the upgrade).

## [0.10.1] (unreleased)

Push-to-talk that actually runs what you say.

- **Hold ⌥ Space, speak, let go.** A real press-and-hold shortcut (Carbon hotkey with key-up, plus a modifier check so letting go of either key ends it; no extra macOS permission). It works with Wren's window closed. The panel says **I'm listening…** with a ring driven by your voice and the recogniser's real interim text. On release the microphone turns off at once, then **Transcribing your voice…**, the recognised sentence, **Working on it…** and the actual result ("Reminder created: Call Sam", the task saved, the answer, "GPT request submitted" → "GPT finished", "One quick question", or the real error with a fix). No Return press.
- One explicit state machine (idle, requesting permission, listening, transcribing, transcript ready, processing, completed, needs clarification, failed, cancelled). Repeated key-downs and presses while busy are ignored, so one utterance runs once; late results from a cancelled utterance are dropped. Releasing before speaking, Esc, very short or low-confidence transcripts never run anything by themselves.
- Fixed: on release the recogniser was cancelled and only the last partial text was used. Now the microphone closes first and Wren waits for the final on-device result.
- Fixed: "Remind me every weekday at 3 PM" followed by "to stretch" lost the schedule, and a new dated sentence after that question was swallowed as its answer.
- Fixed: after a spoken command's result, pressing Return saved the same words again as a new item.
- **Shortcut change:** ⌥ Space is now push-to-talk (on by default). Typed capture moved to **⌥⇧ Space**; both can be changed in Settings and Connectors › Voice. "Check what I said before Wren acts" is off by default.
- Reminder confirmations say "Reminder created".

## [0.10.0] (unreleased)

Wren as a personal executor: explicitly started voice, honest GPT thinking and research, useful email alerts, and one router for every command.

- **Voice is a tool you pick up, never a background listener.** The "Hey Wren" wake phrase and its always-open microphone are removed (the old preference is deleted at launch). Press the voice shortcut (⌥⇧ Space by default) or click **Voice** in the capture panel, the menu-bar popover or the menu-bar item's menu. Wren records one command, stops when you pause (or press Stop, or after 30 s), shows the words transcribed on this Mac to fix or **Record again**, then runs them. The microphone never restarts on its own: not after a command, an error, a relaunch, a screen unlock or a permission change. Locking the screen or sleeping cancels a recording. Pressing the shortcut while a command is being handled does nothing. Connectors › Voice shows the local transcription model's status (Apple's on-device model, managed by macOS) with a link to Dictation settings.
- **One execution router.** Typed text, the capture panel and voice transcripts all go through `ExecutionRouter`, which names one operation (CreateTask, CreateReminder, QueryStoredItems, ChangeItem, DelegateToChatGPT, SearchGmail, OpenEmail, MarkEmailRead, QueryCalendar, OpenDelegationResult, ClarifyIntent…) before anything runs. Each run records a structured result. "Ask GPT." with nothing to ask now asks what to send instead of saving a note. "Open the latest email from Sam" and "show the GPT result" work. The same words submitted twice in a row (a repeated Return or voice event) and a notification action delivered twice run once.
- **GPT thinking and research.** "Think deeply/carefully", "use high reasoning effort" and "investigate … carefully" ask for high reasoning effort (only where the model's list allows it); "research …", "find sources" and "latest …" offer ChatGPT's web search tool. The result page shows what was asked for and what ChatGPT reports actually ran (reasoning effort, number of web searches, cited sources), never assumes. If the plan refuses web search or the reasoning setting, the request fails with that reason; **Run with standard settings** reruns it only when you choose. New Queued, Needs reconnection and Usage limit labels; search within a result.
- **Notifications.** "GPT has finished · Research: quantum physics", opening the exact result. Email alerts read "Important email from Sam" with the subject and Wren's reason, and offer **Open email**, **Snooze alert for 1 hour** (it really comes back once if still unread) and, when allowed, Mark as read. New **Play notification sounds** setting.
- Fixed: while the Mac was locked, Wren's mailbox file couldn't be saved (it used complete file protection), so alert bookkeeping was lost and a restart could alert again. It now uses protection until first login.
- Fixed: "Move that reminder to Sunday" right after setting a reminder said no reminder had gone off yet; "that/this reminder" now means the one you were just talking about.
- Settings › **Voice, GPT and Gmail** shows each tool's real state in one place (voice model and permissions, ChatGPT account, Google scopes) with email alert frequency, quiet hours and the morning email digest.
- `wren-tools live-check chatgpt` reports effort and web-search evidence; new read-only `wren-tools live-check gmail`.
- **Real testing:** `scripts/try-wren.sh` builds and opens a side-by-side Wren Dev and records a content-free diagnostic log; docs/TESTING_GUIDE.md is a 30-minute hands-on checklist with expected results. The README is now a short front page; the full reference moved to docs/USER_GUIDE.md, and release and signing setup to docs/MAINTAINER_SETUP.md.
- Data version 7 (new GPT request fields; a backup is made before the upgrade). Wren 0.9 won't open 0.10 data.

## [0.9.0] (unreleased)

Real integrations, tracked GPT requests, Gmail inbox intelligence, and an audit (docs/AUDIT_REPORT.md).

- **GPT requests are tracked jobs.** "Hey Wren, search in GPT: …" (typed, spoken or from Delegate) is saved as running before anything is sent, keeps running if you close the panel, and ends completed, incomplete, failed or cancelled with ChatGPT's real answer. Wren tells you once when it's done ("GPT finished: … View result."), and the notification, the panel, the overview and Delegate open a saved result page with your words, what was sent, the model, the times and the answer. Retry reruns a failed request on the same entry; a completed one is never sent again. A repeated Return or voice event doesn't send twice. A request cut off by quitting Wren is shown as interrupted, never as done. Earlier plan answers are shown as completed.
- Routing: "tell GPT to investigate this and let me know when it's finished", "ask GPT what quantum physics is" and similar keep the whole query and drop only the instruction meant for Wren. A pending "When should I remind you?" no longer swallows your next GPT request or note.
- **Gmail inbox intelligence** (needs the maintainer fix below to connect): while Wren runs it checks the inbox every few minutes using Gmail's change history (full re-read when that expires), ranks unread mail into Urgent, Time-sensitive, Needs a reply, Professional, Financial and Informational with reasons you can see and correct, alerts once per message (not per Spam/Trash, not during quiet hours, bursts become one summary), and sends a daily email digest at the time and time zone you choose (once per day, late if the Mac slept). New Inbox view with Open in Gmail, Add task, Dismiss and Snooze (Wren's alerts only), and **Mark as read** after you allow Google's extra permission. Email is never sent to ChatGPT or any AI service. Mail metadata lives in a private file outside the database, backups and exports, and is deleted on disconnect.
- **Fixed: Connect Google could never finish.** Google requires the Desktop client's secret at the token endpoint ("client_secret is missing"); builds can now include it (`WREN_GOOGLE_CLIENT_SECRET`), and a build without it says so plainly.
- Fixed: "Remove all Wren data" left GPT requests and answers in the database and connector sign-in files on disk. It now removes both and revokes the sign-ins.
- Fixed: standing rules that read Gmail or Calendar are scoped to their own scheduler, so turning off the briefing's access really stops the briefing.
- "I need to finish this report by Friday" and "Create a task for … next Monday" are saved as "Finish this report" / "Recruiter follow-up" with the date as the deadline, and a reminder is scheduled.
- The microphone permission text describes "Hey Wren" accurately.
- Data version 6 (new delegation fields; a backup is made before the upgrade). Wren 0.8 won't open 0.9 data.
- `wren-tools live-check chatgpt` runs one real delegation for maintainers.
- **"Hey Wren" feels like Siri:** an animated orb shows Wren is listening, your words appear as you speak, and after you pause they stay in the panel to edit; Return runs them (or switch to acting immediately in Voice settings). While waiting for the phrase Wren now only measures loudness and runs speech recognition only while someone is talking, and it stops listening while the screen is locked or asleep. (macOS still shows the microphone indicator while "Hey Wren" is on; no app can listen for a phrase without it.)

## Earlier unreleased changes (in 0.9.0)

- Notion connects through Notion's official connection for apps (Notion MCP): sign in on Notion's page and allow. There's nothing to set up, no integration, and no server of Wren's own.
- New **Calendar** connector reads the calendars already on your Mac (Google, iCloud, Outlook accounts from System Settings) with one macOS permission and no sign-in. Google Calendar (direct) stays optional; events shown from both appear once.
- Google setup for maintainers is a 15-minute, step-by-step guide. A new status setting tells users exactly what to expect (test users only, Google's "unverified app" screen, or verified).

- One **Connect Google** for Gmail and Calendar. It explains what Wren can read, opens Google's own sign-in and permission page, and brings Wren back afterwards. Wren then shows the account, the permissions Google granted, Add for a skipped permission, Reconnect, and Disconnect Google.
- Only the features whose permission Google granted switch on, after a real read.
- Wren says plainly when Google hasn't finished reviewing its app, and that only test accounts can connect until then.
- Fixed: closing Google's (or ChatGPT's or Notion's) sign-in page without finishing no longer leaves Wren waiting forever.

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
