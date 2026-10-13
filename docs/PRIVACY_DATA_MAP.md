# Privacy data map

What Wren (app 0.9, schema 6) and the Wren website actually do with data, category by category.
Source of truth is the code; the public policy (`website/privacy/index.html`) is written from this
map. Update both together. Last checked against the code: 2026-10-13.

Paths below are relative to `~/Library/Application Support/Wren/` (the data folder) unless stated.
"Wren Dev" builds use `~/Library/Application Support/Wren Dev/` and the `com.shibadityadeb.wren.dev`
preferences instead.

## The app

| Data | Where it's stored | Leaves the Mac? To whom, and when | Purpose | How it's deleted | Code |
|---|---|---|---|---|---|
| Captured items: original text, title, kind, dates, reminders, recurrence, status, history | `Wren.store` (SwiftData/SQLite) | Only if you choose it as context for a GPT request in Delegate (then to OpenAI) | Tasks, reminders, briefing | Delete the item; Remove all Wren data; delete the data folder | `Models.swift`, `WrenStore.swift` |
| Goals, waiting items, insight records, daily-run records | `Wren.store` | No | Goals, review, briefing at-most-once | As above | `Models.swift` |
| GPT request records: your words, the sent prompt, the answer, requested/reported model, times, status, error | `Wren.store` | The prompt goes to OpenAI when you send it | Track and reopen results | Remove all Wren data (since 0.9); delete the data folder | `AskService.swift`, `DelegationRecord` |
| Activity (audit) log: action, status, origin, short target label (an item's title, the first 80 characters of a GPT request, "Email from <sender name>") | `Wren.store` | No | Show what Wren did and why | Pruned automatically; Remove all Wren data keeps only the erase's own record | `ActionBroker.swift`, `PolicyRecords.swift` |
| Permissions, standing rules, denials | `Wren.store` | No | Authorization | Remove all Wren data resets them | `Policy.swift` |
| Preferences: shortcuts, notification and digest times, quiet hours, important senders, unsent capture draft, connector status (account email or workspace, last error, last sync) | macOS preferences for `com.shibadityadeb.wren` | No | Settings | Reset preferences; delete the preferences file | `Settings.swift`, `DefaultsStatusStore` |
| Emergency captures (only if the database can't open) | `emergency-captures.txt` | No | Never lose typed text | Delete the file | `AppModel.emergencySave` |
| Sign-in tokens and account identity for ChatGPT, Google and Notion | `Credentials/<key>`: folder 0700, files 0600. **Not** the Keychain | Sent only to the provider that issued them (token refresh, revocation, API calls) | Authorization | Disconnect (revokes with the provider, deletes the file); Remove all Wren data (revokes all, deletes the folder) | `Credentials.swift`, `ChatGPTConnector.swift`, `LiveConnectors.swift` |
| Gmail inbox metadata: from, to, subject, date, labels, Gmail snippet, Wren's classification, alert and digest bookkeeping, sender rules, Mark-as-read outcomes | `Mail/mailbox.json` (0600) | No (fetched from Google) | Inbox, digest, alerts | Pruned after 30 days; deleted on Disconnect Google and Remove all Wren data | `MailIntelligence.swift`, `AppModel+Mail.swift` |
| Optional Gmail cache (headers and snippets, 7 days) | `Cache/gmail.json` | No | Faster answers | Off by default; deleted on disconnect | `Gmail.swift` `EmailCache` |
| Calendar events (Mac calendars via EventKit; Google Calendar) | Not stored | No | Schedule answers, briefing | n/a | `MacCalendar.swift`, `GoogleCalendar.swift` |
| Notion page content | Not stored, except inside a GPT request record if you included a page | Notion (read on request); OpenAI only if you include the page in a GPT request | Search, context | n/a | `NotionMCP.swift` |
| Microphone audio | Never stored; buffers exist in memory only | No. Apple speech recognition with `requiresOnDeviceRecognition = true` | Voice commands | n/a | `VoiceSystem.swift` |
| Transcribed text | Only if it becomes an item or a request you run | As for items or GPT requests | Voice commands | As above | `AppDelegate.runVoiceCommand` |
| Capture text sent to a local model | Not stored by Wren beyond the item | Only to Ollama at `127.0.0.1:11434` | Better interpretation | n/a | `OllamaClient.swift` |
| Backups: full copies of `Wren.store` (incl. GPT records), with a manifest | `Backups/` (keep 7 daily, 10 manual, 5 each pre-upgrade/restore/reset) | No | Recovery | Delete in Settings or Finder; retention prunes old ones | `Backups.swift` |
| Export: items with history, goals, observations, briefing records, permissions, audit labels (no credentials, GPT records, mail, preferences) | A file you choose | Wherever you put it | Portability | Your file | `Export.swift` |
| Scheduled notifications: reminder titles; GPT finished (first 90 characters of the request); mail alerts (sender, subject, reason); digest summary | macOS Notification Center | No (local notifications) | Reminders and alerts | macOS clears delivered ones; completing or deleting a reminder withdraws its pending request | `NotificationService.swift`, `ReminderScheduler.swift` |
| System log messages | macOS unified log, subsystem `com.shibadityadeb.wren` | No | Diagnostics | macOS log retention | `os.Logger` calls (release builds: states and counts; debug builds: more detail) |

### External recipients (all connections are user-initiated or user-enabled)

| Recipient | Hosts | What is sent | When |
|---|---|---|---|
| OpenAI | `auth.openai.com`, `api.openai.com` | OAuth sign-in and tokens; for each request you send: the prompt text (plus any context you explicitly added), `store: false` | Connect ChatGPT; each GPT request you start. Never from background tasks |
| Google | `accounts.google.com`, `oauth2.googleapis.com`, `gmail.googleapis.com`, `www.googleapis.com` | OAuth sign-in and tokens (with the Desktop client ID and secret); read requests; `messages.modify` with `{"removeLabelIds":["UNREAD"]}` only when you choose Mark as read | Connect Google; mail checks while Wren runs and the monitor rule is on; questions; briefing; Mark as read |
| Notion | `mcp.notion.com` | OAuth (dynamic registration) and tokens; search/fetch/create tool calls | When you use Notion features |
| Ollama (your Mac) | `127.0.0.1:11434` | Capture text and prompts for the local model | If you set up local AI |

Wren includes no analytics, telemetry, crash-reporting or advertising SDK and contacts no Wren server.

## The website

| Data | Where | Purpose | Notes |
|---|---|---|---|
| Standard HTTP request data (IP address, URL, time, user-agent, referrer) | The hosting provider's logs, if it keeps them | Serving pages | **Hosting not chosen yet.** Update the policy (section 2) with the provider and its log retention before publishing |
| Cookies, local storage, analytics, third-party scripts or fonts | None | n/a | Verified by `website/tools/check.mjs` (no off-site resources) and a browser network check |

## Maintainer confirmations before publishing

1. Choose hosting; name it and its logging in policy section 2.
2. Confirm the contact email (`shibadityadeb.official@gmail.com`, from the public GitHub profile) is the one to publish.
3. Before Google verification: Google requires an app privacy policy that discloses Google user data use (and, for restricted Gmail scopes, its Limited Use requirements). Review section 7 against Google's current requirements at that time.
4. Re-check statuses on the website when Google sign-in, voice and notification delivery are verified live (docs/MANUAL_TESTS.md).
