# Wren

[![CI](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml/badge.svg)](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml)

Wren remembers what you said you'd do, helps you follow through, and brings important things back to your attention.

It is a native macOS menu-bar agent. You press a shortcut, type what you need to do, and get back to work. Wren saves it locally, reads any date in it, and reminds you at the right time. Its core needs no cloud service, account or API key; connecting ChatGPT, Gmail or Notion is optional and uses your own account's sign-in, never an API key.

## Download

**All releases:** https://github.com/shibadityadeb/wren/releases

Each release has `Wren-macOS-universal.dmg` (signed and notarized) or, until signing is set up, `Wren-macOS-universal-unsigned.dmg` (marked as a preview), plus a `.sha256` checksum. Every push (any branch) and pull request also produces an unsigned preview DMG, downloadable from the run's page under [Actions](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml); the run summary lists its version, architectures, minimum macOS and signing status.

| | |
|---|---|
| macOS | 14 Sonoma or later |
| Processors | Universal: Apple Silicon (arm64) and Intel (x86_64), each tested natively in CI |
| Local AI | Optional. Needs [Ollama](https://ollama.com/download) (free, separate). Models are downloaded only when you choose to. |

### Install

1. Open the `.dmg`.
2. Drag **Wren** into **Applications**, then eject the disk image.
3. Open Wren from Applications. It appears in the Dock and as a bird in the menu bar. If an older Wren is running, quit it first (right-click its bird › Quit Wren).

**Unsigned preview builds** are blocked by macOS the first time. Open Wren once, then go to **System Settings › Privacy & Security** and click **Open Anyway**. Do this only for a file from this repository whose checksum matches.

**Downgrading:** don't run an older Wren after a newer one has opened your data. Versions before 0.6.0 silently migrate newer data down, dropping fields they don't know (for example the 0.6.0 "private" flag and delegation history). From 0.6.0 on, an older Wren refuses newer data instead and leaves it untouched.

**Upgrading** is the same: drag the new Wren over the old one. Your data stays in `~/Library/Application Support/Wren`, keyed to the bundle identifier `com.shibadityadeb.wren`, and is backed up automatically before any database upgrade. If you'd turned on "Open Wren when I log in", it keeps working; there is only ever one login item.

### Verify a download

```bash
shasum -a 256 -c Wren-macOS-universal-unsigned.dmg.sha256
```

## Build from source

Requirements: macOS 14+, Xcode 16 (Swift 6.1).


```bash
scripts/build-app.sh            # release build → build/Wren.app
open build/Wren.app
```

`scripts/build-app.sh debug` builds a debug app. `scripts/build-app.sh release --universal` builds for Apple Silicon and Intel. `scripts/package-dmg.sh` runs the tests, builds the universal app, makes the DMG in `dist/` and verifies it.

The script compiles the Swift package, regenerates the icon from `assets/logo.png`, assembles the bundle, and ad-hoc signs it. Ad-hoc signing is enough for local use. Moving the app to another Mac requires signing it with your own Developer ID.

## Using Wren

**Wren is a normal Mac app.** It has a Dock icon, a Wren menu (About Wren, Settings…, Hide Wren, Quit Wren), and exactly one bird in the menu bar. All of them are the same running Wren. Opening Wren from the Dock, Applications, Spotlight or Finder shows its window: what Wren does, your open commitments, goals and waiting items, today's overdue and due items, upcoming reminders, and **New reminder** and **New capture** buttons.

- **Closing the window** keeps Wren running in the menu bar, so "Hey Wren", the shortcuts, the briefing and the check-in keep working. Click the Dock icon or the bird to get it back.
- **Quitting** (⌘Q, Wren › Quit Wren, or right-click the bird › Quit Wren) stops everything, including the microphone, and removes the bird. Reminders are scheduled with macOS, so they still arrive after you quit. Open Wren from the Dock or Applications to start it again.
- **Only one Wren runs at a time.** Opening it again brings the running one forward, and Wren locks its data folder so two copies can never change your data at once.
- **Open at login** is in Settings › Startup (off until you turn it on). Started at login, Wren stays in the menu bar without opening its window.

| Do this | How |
|---|---|
| Capture | Press **⌥ Space** anywhere, type, press **Return**. **Esc** cancels. Clicking away keeps your draft. |
| Capture without the shortcut | Click the bird in the menu bar and type in "Add something…", or click the pencil button. You can also run `open wren://capture`. |
| See your items | Click the bird in the menu bar. |
| Complete | Click the circle, or choose **Done** in the notification. |
| Snooze or set a reminder | Use the **…** menu on a row, or open the item and set **Remind**. In a notification, choose **Remind me in 1 hour** or **Remind me at…** and type a time such as `9pm` or `tomorrow 10am`. |
| Edit, drop, reopen, delete | Click a row to open it. |
| Test a notification | Use **…** › **Remind me in 1 minute**. |
| Change the shortcut | Open **Settings** (gear) › **Change…**, then press the new combination. You can also turn the shortcut off there. |
| Goals | **Goals** tab. Type a goal (a trailing date like "by end of month" becomes the target). Choose how progress is measured, link tasks or add milestones. |
| Waiting on someone | Open a waiting item: who, what, follow-up date, "I followed up". |
| Review | **Review** tab: follow-ups due, things moved several times, goals coming up, quiet items. Nothing changes until you choose. |
| Change an existing item by typing | In the capture panel: "move that to Sunday", "push the API task to next week", "mark the research task as done", "remind me about it tomorrow", "drop that idea". Wren shows what it understood; Return confirms. "What am I waiting for?" and "Which goals have I made no progress on?" answer from your data. |
| Today's briefing | Sun button in the menu, or the 11:00 notification. |
| Evening check-in | Moon button in the menu, or the 19:00 notification. Done, Later › Snooze / Leave for tomorrow / Reschedule…, then Finish or Dismiss. |
| Change briefing or check-in time, or turn them off | Settings › Daily rhythm |
| Open Wren at login | Settings › Startup (off until you turn it on) |
| See and change what Wren may do | Settings › Permissions, and Activity log |
| Pause notifications | **Pause** at the bottom of the menu, or Settings › Notifications: for 1 hour, until the end of today, or until you resume |
| Export, back up, restore | Settings › Your data |
| Reset | Settings › Reset |
| Set a reminder | Type or say "remind me to call Sam tomorrow at 10 AM", "remind me to submit the report Friday evening" or "remind me to take a break every weekday at 3 PM". Or use **New reminder** in the window. |
| Change or snooze a reminder | "Move my API reminder to Sunday at noon" or "snooze the current reminder for 30 minutes". Wren shows the change; Return confirms. |
| Ask ChatGPT | Type "ask ChatGPT to explain quantum physics" or "can you check on GPT what is quantum physics". The panel shows the question and the real answer from your ChatGPT plan, or Connect ChatGPT if you aren't signed in. A question that names no assistant lets you choose local AI, ChatGPT or saving it. Start with "Note:" to just save text. |
| Talk to Wren | Say "Hey Wren" (turn it on in Connectors › Voice) or press **⌥⇧ Space**, then say what you need. |
| Quit | ⌘Q, Wren › Quit Wren, right-click the bird › Quit Wren, or **Quit** at the bottom of the menu. |

### Reminders

A reminder is only reported as set after it's saved and handed to macOS:

1. Wren saves it, records it in the activity log, and schedules a macOS notification for it.
2. The notification arrives at that time whether or not Wren is running.
3. Completing, dropping, deleting, snoozing or moving a reminder updates or removes its notification, so nothing stale fires.
4. Each time Wren starts, it checks its reminders against macOS's pending notifications and fixes any difference without creating duplicates.

**Repeating reminders** ("every day at 9", "every weekday at 3 PM", "every Monday and Thursday at 8am") use macOS's repeating schedule at your local clock time, so they stay at 3 PM through daylight-saving changes and when you travel. **Done** in the notification finishes that day's one; completing the item in Wren ends the series.

**When something is unclear, Wren asks instead of guessing.** "Remind me to call Sam" gets "When should I remind you…?", and "tomorrow at 3" gets "Is that 3 AM or 3 PM?". Your next answer completes the request. A time that has already passed is refused. A date without a time ("on Friday") uses your default reminder hour, and Wren says so.

**Notifications permission:** macOS asks the first time you set a reminder. If notifications are off, reminders still show inside Wren, and Wren tells you. Settings › Notifications shows the permission, how many reminders are scheduled with macOS, and opens macOS's notification settings.

### Dates

Wren reads dates from your own words even without a language model. It understands phrases like "tomorrow", "tonight at 8", "by Friday", "this weekend", "next week", "in 2 hours", "15 October", "9pm", and "end of month". It never invents a date. A deadline without a time gets a reminder at 10:00 on that day, and you can change that hour in Settings. Numeric dates like 10/11 are deliberately not supported, because the day and month order is ambiguous.

## Local AI (optional)

Wren works fully without AI: it saves everything you capture, reads dates with built-in rules, reminds you, and understands a set of fixed command phrasings. A local model adds cleaner titles, recognition of goals, ideas, questions and waiting items, clarifying questions, and many more ways of asking for changes or asking about your items.

The model runs **on your Mac** through [Ollama](https://ollama.com). Wren talks only to `127.0.0.1:11434` and refuses any other address. The local model never sends anything to an external AI service. Separately, if you connect ChatGPT, requests you explicitly address to GPT ("ask GPT …") are sent with your ChatGPT plan; nothing else is.

### First run

Open the menu bar bird, then the AI label in the header (or **Settings › Local AI**). Wren shows one of:

| Status | Meaning | What to do |
|---|---|---|
| Setup required | Ollama isn't installed | **Download Ollama**, install, open it once, **Check again** |
| Start Ollama | Installed but its service isn't answering | **Start Ollama** |
| Download a model | Ollama runs, but has no chat model (embedding-only models don't count) | Press **Download** next to a model |
| Select a model | Several chat models installed | Pick one |
| *model* selected, not yet tested | Configured; hasn't answered yet this session | **Test local AI**, or just use Wren |
| Ready | The model answered a real test request | Nothing |
| Temporarily unavailable | It was set up but just failed (stopped, timed out) | Start Ollama, **Test local AI** again |

**Downloading a model.** Wren recommends `qwen2.5:3b` (about 1.9 GB, good on 8 GB of memory) and lists two alternatives; you can type any other Ollama model name. Nothing downloads until you press **Download**. You see real progress and can cancel; Ollama keeps what was downloaded, so **Resume** continues. Wren checks free disk space first, and after the download runs a test before calling the model ready. Models live in Ollama's folder, not inside Wren; remove one with `ollama rm <name>`.

### Troubleshooting

| Symptom | Fix |
|---|---|
| "Start Ollama" stays | Open the Ollama app; or run `ollama serve` in Terminal |
| Download fails | Check internet and free space; press **Retry** |
| "Temporarily unavailable: timed out" | The first request loads the model into memory and can take 10–30 s on 8 GB Macs. Press **Test local AI** again |
| Only `nomic-embed-text` installed | That's an embedding model; download a chat model |

Every change Wren proposes from what you type (with or without AI) is shown first and needs your confirmation. The model can suggest; it can never approve.

## Connectors

Open Wren's window › **Connectors** (or Settings › Connectors). You connect your existing accounts by signing in on the provider's own page in your browser. There's never a key, token, client ID or configuration file to deal with.

Each connector shows its real state (Available to connect, Connecting, Connected, Missing permissions, Reauthorization required, Usage limit reached, Temporarily unavailable, Maintainer setup required, Not implemented), how it signs in, what it reads and changes, the permissions it grants Wren, its privacy and data handling, the last successful check and the last error. A connector is only shown as Connected after a real, authorized call to the provider succeeded.

| Connector | What you do | What it can do |
|---|---|---|
| ChatGPT | **Continue with ChatGPT**, sign in, approve Wren | Send requests you confirm and get the answer back, using your ChatGPT plan |
| Voice | Turn it on; allow Microphone and Speech Recognition when macOS asks | The voice shortcut and optional "Hey Wren", transcribed on your Mac |
| Gmail | **Connect Google** (one sign-in for both) | Inbox triage with reasons, daily email digest, urgent-mail alerts while Wren runs; optional Mark as read |
| Google Calendar | **Connect Google** (same sign-in) | Read-only: schedule questions, briefing, reminders from events |
| Calendar | **Use this Mac's calendars** (macOS asks once) | Read-only: every calendar already on this Mac, including Google, iCloud and Outlook accounts |
| Notion | **Connect Notion**, sign in and allow | Search and read pages, create a page after you confirm |
| Local files, Apple Shortcuts | — | Planned |

If a connector says **Maintainer setup required**, the copy of Wren you have was built without that provider's sign-in. There's nothing for you to set up; it's for Wren's maintainers to enable.

### ChatGPT

**Continue with ChatGPT** opens OpenAI's sign-in page ("Sign in with ChatGPT"). Sign in and approve Wren, including use of your ChatGPT plan. Wren then lists the models your plan offers and shows:

| State | Meaning |
|---|---|
| Not connected | You haven't signed in |
| Account connected, plan usage not authorized | You signed in but didn't allow plan usage, or your plan can't be used by apps. **Allow plan usage…** asks again |
| Connected and ChatGPT plan usage enabled | Ready. The Delegate panel shows **Using ChatGPT plan** and a **Manage usage** link |
| Reauthorization required | The sign-in expired or was removed. **Reconnect** |
| Usage limit reached | Your plan's allowance for apps is used up for now. **Manage usage** opens ChatGPT's usage page |
| Temporarily unavailable | ChatGPT or your connection had a problem; nothing was removed |

Say or type "Hey Wren, search in GPT: explain quantum physics and give me a few beginner resources", "ask GPT to brainstorm names for my project", or use **Delegate**. Wren treats it as a delegation, not a task or a note:

1. It sends exactly your request (without "ask GPT" and "let me know when it's done") using your ChatGPT plan, once. A repeated Return or voice event doesn't send it twice.
2. The request is saved as **Running** first, so it keeps going if you close the panel and stays in your history after a restart.
3. When ChatGPT finishes, Wren tells you once: "GPT finished: … View result." Clicking it (or the entry in Overview › GPT requests or Delegate) opens the saved result: your words, what was sent, the model requested and reported, the times, and the answer exactly as returned.
4. Failures say why (not connected, permission, usage limit, network, Wren closed mid-request). **Retry** reruns the same entry; a completed request is never re-sent.

The plan API is called with storage off, so the request doesn't appear in your ChatGPT history and there's no link to a ChatGPT conversation; Wren doesn't invent one. **Open ChatGPT** just opens ChatGPT. Nothing from Wren (items, notes, email) is attached unless you add it yourself in Delegate, which shows exactly what will leave your Mac; private items need ticking and detected secrets are replaced with "[removed]". Wren never switches to paid API billing.

Wren uses your plan only for requests you start and confirm; background tasks never use it. Wren can't see your ChatGPT conversations, memories or custom instructions. Tokens stay in a private file in Wren's data folder that only your macOS account can read (not the Keychain, so there are no Keychain password prompts) and never appear on screen, in logs, exports or backups. **Disconnect** revokes the sign-in with OpenAI and deletes the tokens.

**Fallback: copy and open.** Under Connectors › ChatGPT you can also allow copying a prompt and opening ChatGPT in your browser or the ChatGPT app. You paste and send it yourself, then paste the answer back into Delegate. This works without signing in.

### Voice: "Hey Wren" and the voice shortcut

Turn these on in Connectors › Voice. Both run the same voice command:

- **"Hey Wren"** (off until you turn it on). Say "Hey Wren, search in GPT: explain transformers". The capture panel opens with a Siri-style animated orb and **Listening…**, your words appear as you speak, and recording stops when you pause. The panel then shows **Transcribed** with the text editable: fix anything, then press **Return** to run it, or **Esc** to cancel. (Settings › Connectors › Voice can switch to running straight away.) Typing while Wren listens stops listening and keeps the text.
- **The voice shortcut** (default **⌥⇧ Space**, changeable; Wren tells you if it clashes with another shortcut). Press it, speak, and pause, or press it again when you're done.

Wren shows what it heard and what it did, for example "Reminder set: Call Sam, tomorrow at 10:00 AM, scheduled with macOS". A clear request such as setting a reminder runs straight away. Changing an existing item shows a preview to confirm. Anything unclear gets a short question. **Esc** or **Cancel** stops listening without doing anything.

**Privacy:**
- Speech is recognised on this Mac with Apple's on-device recognition. Wren refuses server recognition, and no audio is stored or sent anywhere.
- To hear the phrase at all, the microphone has to stay open while "Hey Wren" is on and Wren is running, so macOS shows its orange microphone indicator (no app other than Siri can avoid that). Until someone speaks, Wren only measures loudness; speech recognition runs on this Mac only while someone is talking, and silence and background noise are never transcribed. Listening pauses while the screen is locked or the display sleeps.
- Recording stops as soon as a command ends.
- Quitting Wren turns the microphone off.

If on-device recognition isn't installed for your language, turn on Dictation once in System Settings › Keyboard.

### Gmail and Google Calendar

One **Connect Google** covers both. In Connectors › Gmail or Google Calendar:

1. Tick what Wren may read. Wren explains each option first.
2. Press **Connect Google**.
3. Google's own sign-in page opens in your browser. Choose your account and review the permissions; you can untick one there too.
4. Approve. Wren comes back to the front by itself.

| Permission | What it lets Wren do |
|---|---|
| Read your email, read-only (`gmail.readonly`) | Inbox triage, the email digest, alerts, search and questions |
| See your calendars, read-only (`calendar.readonly`) | Read upcoming events, answer schedule questions, and add events to the briefing |
| Change your email's read state (`gmail.modify`, optional, asked separately) | **Mark as read**. Google's permission also covers other changes, but Wren implements only Mark as read: no send, archive or delete |

Afterwards Wren shows the Google account, which permissions Google actually granted, **Add…** for a permission you skipped, **Reconnect** and **Disconnect Google**. Gmail or Calendar only switches on after a real read with that permission worked.

**Inbox.** While Wren runs (and "Check for new mail while Wren runs" is on), it checks the inbox every 5 minutes by default, reading only what changed since the last check. It never looks at Spam or Trash. Unread mail is ranked into Urgent, Time-sensitive, Needs a reply, Professional (work, recruiting), Financial, and Informational, each with the reason (for example "deadline within a day; asks you something"). Promotions and newsletters are low priority, not "spam", and an unfamiliar sender isn't treated as suspicious. **Correct** changes a message's category or always/never treats a sender as important.

**Alerts.** Mail at or above your threshold (default: urgent and time-sensitive) gets one notification with the sender, subject and reason. Each message alerts once; another message in the same conversation doesn't alert again unless it's more urgent; several at once become one summary; quiet hours (default 22:00–07:00) hold alerts until they end. Clicking an alert opens the message in Wren, with **Open in Gmail**, **Mark as read** (when allowed), **Add task…**, **Dismiss** and **Snooze**. Dismiss and Snooze change Wren's alert only, never Gmail.

**Email digest.** Once a day at the time and time zone you choose (default 08:00, this Mac's zone), Wren sums up unread inbox mail since the last digest plus older important unread mail (up to 14 days), one entry per conversation: sender, subject, Gmail's own preview (factual), Wren's inferred category and reason, and a suggested next step. If the Mac was asleep or Wren wasn't running, the digest comes once when Wren next runs, marked late. With the digest on, the morning briefing leaves email out so you're not told twice.

**Privacy.** Triage runs on your Mac with rules. Email is never sent to ChatGPT or any other AI service, and there's no setting that would. Wren reads headers, labels and Gmail's short preview, not full bodies or attachments. Recent inbox metadata is kept in a private file (`Mail/mailbox.json`, readable only by your macOS account) outside Wren's database, exports and backups, pruned after 30 days, and deleted when you disconnect or remove all data. Text in an email is data: it can't trigger any action. Wren can only check mail while it's running; when you quit it, nothing is checked.

**Before Google has verified Wren's app**, Google shows an "unverified app" warning or only lets listed test accounts connect; Wren says which on the Connect Google screen.

### Calendar (this Mac)

**Use this Mac's calendars** in Connectors › Calendar lets Wren read the calendars already in Apple's Calendar app. That includes Google, iCloud, Outlook and Exchange accounts you added in System Settings › Internet Accounts. macOS asks once for Calendars access. There's no sign-in, and nothing leaves your Mac.

It's read-only. It powers "what meetings do I have tomorrow?", today's events on the Overview and in the briefing, and **Remind me** on an event. To include a Google calendar this way, add your Google account in System Settings › Internet Accounts and turn on Calendars.

You can also connect **Google Calendar (direct)** through Connect Google. If both are on, Wren shows each event once.

### Notion

**Connect Notion** opens Notion's sign-in page in your browser. Sign in, choose the workspace, and allow access. Wren comes back by itself and shows the workspace. There's nothing to set up in Notion first.

Wren uses Notion's official connection for apps (Notion MCP). It registers itself during sign-in, so there's no integration, token or secret.

You can search your workspace, read pages, include chosen pages as context in a Delegate request, and create a page (it always asks first). Notion asks you to connect again after 30 days without use, or after 180 days. **Disconnect** removes the sign-in from this Mac and asks Notion to revoke it.

### Troubleshooting

| Problem | Fix |
|---|---|
| "Maintainer setup required" | This copy of Wren doesn't include that provider. Nothing to set up on your side |
| ChatGPT: "Account connected, plan usage not authorized" | Press **Allow plan usage…** and approve it, or check that your plan is Plus or Pro |
| ChatGPT: "Usage limit reached" | Wait for your allowance to reset, or check **Manage usage** |
| "Reauthorization required" | Press **Reconnect** |
| "Missing permissions" | Connect again and approve everything Wren asks for on the provider's page |
| Gmail/Calendar: "Missing permission" | Connect again and leave the permission ticked on Google's page |
| Notion says Reauthorization required | Notion's sign-in lasts up to 180 days, and ends after 30 days unused: press **Reconnect** |
| Calendar shows no events | Add your accounts in System Settings › Internet Accounts, then **Check again** in Connectors › Calendar |
| Voice: "on-device recognition isn't installed" | Turn on Dictation in System Settings › Keyboard once |
| Voice: microphone denied | System Settings › Privacy & Security › Microphone › Wren |

## What Wren may do on its own

Wren separates proposing, authorizing, executing, verifying and recording every action. In practice:

- Your own clicks on reversible things (done, snooze, edit, drop) just happen.
- Deleting always asks first.
- On its own, Wren only sets and delivers reminders for your deadlines and applies the date rules or local model's reading of your own captures. Both are standing rules you can turn off.
- Connecting a service grants only its read permission. Anything that leaves your Mac (a ChatGPT handoff, an OpenAI request, a new Notion page) is shown first and needs your press each time; private content needs an extra explicit tick.
- Model suggestions and text inside emails, pages or documents never count as permission.
- Everything Wren does or refuses is listed in Settings › Activity log, without your content.

Details: ARCHITECTURE.md §18.

## macOS permissions

| Permission | Why | When it's asked |
|---|---|---|
| Notifications | Reminders, briefing, check-in, with actions | The first time a capture gets a reminder, or via **Allow…** in the menu |
| Login item | Open Wren at login | Only when you turn it on in Settings › Startup; macOS shows it in System Settings › General › Login Items |

The global shortcut needs no Accessibility or Input Monitoring permission. Wren registers exactly one key combination through the standard macOS hotkey API and never sees any other keystroke. The microphone is used only for the voice shortcut and, if you turn it on, "Hey Wren" (see Voice). Wren needs no file access.

If notifications are off, due items appear under **Due now** in the menu. Wren does not mark them as sent.

## Your data

| What | Where |
|---|---|
| Items, history, permissions, audit, daily runs | `~/Library/Application Support/Wren/Wren.store` (SwiftData/SQLite) |
| Automatic backup before a schema upgrade | `~/Library/Application Support/Wren/Backups/schema-vN/` |
| Fallback if the database can't open | `~/Library/Application Support/Wren/emergency-captures.txt` |
| Preferences | `defaults read com.shibadityadeb.wren` |
| Diagnostics | `/usr/bin/log show --predicate 'subsystem == "com.shibadityadeb.wren"' --last 1h` |

Capture text is never written to the logs.

### Export

Settings › Your data › **Export…** writes one readable JSON file (format `wren-export`, version 1): every item with its original wording, dates, reminders, status and full history; waiting details and follow-ups; goals, progress settings and linked items; review decisions; briefing records; permissions and standing rules; the activity log (labels only). Dates are ISO 8601 in UTC with the Mac's time zone in the manifest. It contains no passwords, keys or tokens, and doesn't include preferences or AI models. Wren never overwrites an existing file without the save dialog asking first.

### Backups and restore

Wren backs up its database once a day while running, before every upgrade, restore and reset, and when you press **Back Up Now**. Each backup is a consistent SQLite snapshot (taken with SQLite's backup API, safe while Wren is writing) with a `manifest.json` holding the date, app version, schema version, record counts and a SHA-256 checksum. Kept: the newest 7 daily, 10 manual and 5 of each automatic kind. Location: `~/Library/Application Support/Wren/Backups`.

**Preview** verifies the checksum and database integrity and shows what the backup holds. **Restore…** asks for confirmation, backs up your current data, then restarts Wren and swaps the data in before anything opens it. If the restored data can't be opened, Wren puts your previous data back and tells you. The replaced data is also kept in `Restore/`. Backups made by Wren 0.2–0.4 (plain copies) can be previewed and restored too.

### Reset

Settings › Reset offers two separate actions, each explained and confirmed:

- **Reset preferences**: shortcut, times, review thresholds, AI model choice, pause and open-at-login go back to defaults. Items are kept.
- **Remove all Wren data**: deletes every item, goal, history entry, review decision, briefing record and GPT request, signs out of (and revokes) ChatGPT, Google and Notion, deletes cached mail, and resets permissions to defaults. "Back up first" is on by default. Backups, Wren itself and Ollama models are not touched, and nothing outside Wren's data folder is.

Wren doesn't offer "clear test data": it can't reliably tell test entries from real ones.

### Pausing notifications

While paused, Wren delivers no reminders, briefing or check-in, and changes nothing: deadlines and reminder times stay as they are, and no reminder is recorded as sent. The pause survives restarts. When it ends (on its own or with **Resume**), everything that came due is listed in **one** summary notification, and only if macOS accepts it are those reminders recorded as delivered. A briefing or check-in whose time passed during the pause follows the usual rule: still in its window, it's sent once; otherwise it's marked missed. Notifications macOS had already shown before the pause can't be taken back.

## Releases (maintainers)

1. Update `VERSION` and add a section to `CHANGELOG.md`.
2. Commit, then tag: `git tag v0.4.0-preview.1` (prerelease) or `git tag v0.4.0` (stable), and push the tag.
3. The **Release** workflow runs the full tests on Apple Silicon and Intel, builds the universal app, packages and verifies the DMG on both architectures, signs and notarizes when credentials exist, and publishes a GitHub Release with notes and checksums.

Rules: the tag must match `VERSION`. A **stable** tag is only published if the build is signed and notarized; unsigned builds can only be published under a `-preview`/`-beta`/`-rc` tag, marked as prerelease. **Run workflow** (manual dispatch) builds a release candidate as a downloadable artifact and never publishes.

Local packaging: `scripts/package-dmg.sh` (runs tests, builds universal, packages, verifies). `scripts/verify-dmg.sh <dmg>` re-checks any DMG.

### Provider sign-in setup

Google sign-in needs one app registration made by the maintainers and injected at build time. ChatGPT and Notion need none, because Wren registers itself with them. See [docs/MAINTAINER_SETUP.md](docs/MAINTAINER_SETUP.md). A build without them still works and shows Gmail and Google Calendar (direct) as "Maintainer setup required".

### Signing and notarization setup

Required for a frictionless public release. Add these **repository secrets** (Settings › Secrets and variables › Actions). Never commit them.

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Your **Developer ID Application** certificate and private key, exported from Keychain Access as .p12, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the .p12 |
| `NOTARY_KEY_P8_BASE64` | An App Store Connect API key (Users and Access › Integrations › Team Keys, role Developer), the downloaded `AuthKey_XXXX.p8`, base64-encoded |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys list |

You need a paid Apple Developer Program membership to create a Developer ID Application certificate. The workflow imports the certificate into a temporary keychain, signs with the hardened runtime and a secure timestamp (no extra entitlements are needed), submits the DMG with `notarytool`, waits, staples the ticket and verifies it with `stapler validate` and `spctl` before publishing.

## Tests

```bash
swift test
```

The test suite covers persistence across reopen, status transitions, reminder deduplication across restarts, the date reader in two timezones, model-output validation (including invented dates and malformed JSON), local-only enforcement for the Ollama client, and a check that the core library contains no process-execution calls. CI never needs a model. The live tests run only on a Mac with Ollama and the model installed:

```bash
WREN_LIVE_OLLAMA=qwen2.5:3b swift test --filter "LiveModelTests|testLiveOllama"
```

To try a development build next to an installed Wren, build it as **Wren Dev**. It's a separate app with its own data folder, preferences, credentials and `wren-dev://` URL scheme, so it never touches your real data and never shows up as a second Wren:

```bash
scripts/build-app.sh debug --dev-identity
```

Tests that need a person, a real account, macOS permission prompts or real time passing are listed in [docs/MANUAL_TESTS.md](docs/MANUAL_TESTS.md), with what has and hasn't been run.

## Brand assets

`assets/logo.png` is the source. Running `scripts/build-app.sh` regenerates `Brand/` from it:

- `wren-mark*.svg`: vector masters, traced from the logo with Apple's Vision framework (`swift run wren-tools trace assets/logo.png Sources/WrenKit/WrenMarkData.swift`).
- `wren-menubar-template.svg`: a slightly bolder variant that stays legible at 16 to 18 pt.
- `Wren.iconset` and `app-icon-1024.png`: the macOS icon. It uses your original pixels at 64 px and above, and the vector trace at 16 and 32 px, where the raster blurs.
- `tokens.json`: colours, spacing, and type.

## Known limitations

See ROADMAP.md, section "Milestone 1 status".
