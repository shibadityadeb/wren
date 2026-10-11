# Wren

[![CI](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml/badge.svg)](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml)

Wren remembers what you said you'd do, helps you follow through, and brings important things back to your attention.

It is a native macOS menu-bar agent. You press a shortcut, type what you need to do, and get back to work. Wren saves it locally, reads any date in it, and reminds you at the right time. No cloud service, account, or API key is involved.

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
3. Open Wren from Applications. It has no Dock icon: look for the bird in the menu bar.

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

**Opening Wren** from Applications, Spotlight or Finder shows its window: what Wren does, your open commitments, active goals and waiting items, today's overdue and due items, upcoming reminders, Local AI status, and a **New capture** button. The sidebar has Items, Goals, Review, Local AI and Settings. Closing the window doesn't quit Wren: it keeps running in the menu bar (the bird), with no Dock icon. **Open Wren** in the menu, or opening the app again, brings the window back. When Wren starts at login it stays quietly in the menu bar.

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
| Quit | **Quit**, at the bottom of the menu. |

Wren reads dates from your own words even without a language model. It understands phrases like "tomorrow", "tonight at 8", "by Friday", "this weekend", "next week", "in 2 hours", "15 October", "9pm", and "end of month". It never invents a date. A deadline without a time gets a reminder at 10:00 on that day, and you can change that hour in Settings. Numeric dates like 10/11 are deliberately not supported, because the day and month order is ambiguous.

## Local AI (optional)

Wren works fully without AI: it saves everything you capture, reads dates with built-in rules, reminds you, and understands a set of fixed command phrasings. A local model adds cleaner titles, recognition of goals, ideas, questions and waiting items, clarifying questions, and many more ways of asking for changes or asking about your items.

The model runs **on your Mac** through [Ollama](https://ollama.com). Wren talks only to `127.0.0.1:11434` and refuses any other address. Nothing you type goes to an external AI service. This is different from external AI services (like ChatGPT), which Wren does not use.

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

Each connector shows its real state (Not connected, Connecting, Connected, Partially connected, Temporarily unavailable, Permission denied, Not available in this build, Planned), how it signs in, what it reads and changes, the permissions it grants Wren, its privacy and data handling, the last successful check and the last error. A connector is only shown as Connected after a real, authorized call to the provider succeeded.

| Connector | What you do | What it can do |
|---|---|---|
| ChatGPT | **Continue with ChatGPT**, sign in, approve Wren | Send requests you confirm and get the answer back, using your ChatGPT plan |
| Voice | Turn it on; allow Microphone and Speech Recognition when macOS asks | Push-to-talk capture, transcribed on your Mac |
| Gmail | **Connect with Google** | Read-only: search, what needs attention, morning briefing |
| Google Calendar | **Connect with Google** | Read-only: schedule questions, briefing, reminders from events |
| Notion | **Connect Notion**, pick the pages Wren may use | Search and read those pages, create a page after you confirm |
| Local files, Apple Shortcuts | — | Planned |

If a connector says **Not available in this build**, the copy of Wren you have was built without that provider's sign-in. There's nothing for you to set up; it's for Wren's maintainers to enable.

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

Say or type "Ask ChatGPT to brainstorm ten names for this project", or open **Delegate**. Wren shows exactly what will leave your Mac. Private items are left out unless you tick them, and detected secrets are replaced with "[removed]" unless you choose otherwise. **Send with ChatGPT** sends that text, once, and streams the answer back. Each request uses your ChatGPT plan's allowance (Plus or Pro). Wren never switches to paid API billing. Requests are sent with storage turned off. Answers are labelled with the model Wren requested and the model the response reports.

Wren uses your plan only for requests you start and confirm; background tasks never use it. Wren can't see your ChatGPT conversations, memories or custom instructions. Tokens stay in the macOS Keychain and never appear on screen, in logs, exports or backups. **Disconnect** revokes the sign-in with OpenAI and deletes the tokens.

**Fallback: copy and open.** Under Connectors › ChatGPT you can also allow copying a prompt and opening ChatGPT in your browser or the ChatGPT app. You paste and send it yourself, then paste the answer back into Delegate. This works without signing in.

### Voice

Connectors › Voice › turn on push-to-talk. Hold **⌥⇧ Space**, speak, release. Apple's speech recognition runs **on this Mac** (`requiresOnDeviceRecognition`; Wren refuses server recognition), and the recording is deleted right after. The text lands in the capture panel for you to correct, then goes through exactly the same handling as typing (commands still show a preview). There's also a microphone button in the capture panel. Maximum 60 seconds. If on-device recognition isn't installed for your language, turn on Dictation once in System Settings › Keyboard.

### Gmail and Google Calendar

**Connect with Google** opens Google's sign-in page. Choose your account and approve one read-only permission. Gmail and Calendar are connected separately and each asks only for its own:

| Connector | Permission (scope) |
|---|---|
| Gmail | Read your email: `https://www.googleapis.com/auth/gmail.readonly` |
| Google Calendar | See your calendars: `https://www.googleapis.com/auth/calendar.readonly` |

Wren checks which permission Google actually granted. If you unticked it, the connector says what's missing instead of claiming to work. Wren can't send, archive, delete or mark mail, or create or change events.

What you get: search mail ("Anything from the recruiter?"), "What needs my attention today?" (overdue Wren items + today's events + mail flagged as a request, deadline, bill, interview, security notice, Gmail-important or from your important senders), today's events and mail on the Overview, both in the morning briefing (Connectors › Gmail › "Include in the morning briefing"), "What meetings do I have tomorrow?", and "Remind me" on any event. Suggested tasks from email open in the capture panel for you to edit first.

Mail is fetched when needed and **not stored** unless you turn on the 7-day cache of headers and previews. Text in an email is treated as data: it can't trigger any action. **Disconnect** revokes Wren's access with Google, removes the token from the Keychain and deletes cached mail.

### Notion

**Connect Notion** opens Notion in your browser. Pick the workspace and the pages Wren may use; Wren can't see anything else. Wren shows the workspace it's connected to. **Change which pages Wren can use…** takes you back to Notion to adjust.

You can search those pages, read them, include chosen pages as context in a Delegate request, and create a page (it asks first). Unsupported block types are shown as "[type block not shown]". Sign-in finishes through a small service run by Wren's maintainers that holds Wren's Notion app secret; it passes the token to Wren and stores nothing. **Disconnect** revokes the token with Notion and deletes it from the Keychain.

### Troubleshooting

| Problem | Fix |
|---|---|
| "Not available in this build" | This copy of Wren doesn't include that provider. Nothing to set up on your side |
| ChatGPT: "Account connected, plan usage not authorized" | Press **Allow plan usage…** and approve it, or check that your plan is Plus or Pro |
| ChatGPT: "Usage limit reached" | Wait for your allowance to reset, or check **Manage usage** |
| "Reauthorization required" or "Permission denied" | Press **Reconnect** |
| Gmail/Calendar: "Missing permission" | Connect again and leave the permission ticked on Google's page |
| Notion pages missing | **Change which pages Wren can use…** and add them in Notion |
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

The global shortcut needs no Accessibility or Input Monitoring permission. Wren registers exactly one key combination through the standard macOS hotkey API and never sees any other keystroke. Wren uses no microphone and needs no file access.

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
- **Remove all Wren data**: deletes every item, goal, history entry, review decision and briefing record, and resets permissions to defaults. "Back up first" is on by default. Backups, Wren itself and Ollama models are not touched, and nothing outside Wren's data folder is.

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

Google and Notion sign-in need app registrations made once by the maintainers and injected at build time; ChatGPT needs none. See [docs/MAINTAINER_SETUP.md](docs/MAINTAINER_SETUP.md). A build without them still works and shows those connectors as "Not available in this build".

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

The Notion sign-in relay has its own tests:

```bash
node --test services/notion-oauth-relay
```

## Brand assets

`assets/logo.png` is the source. Running `scripts/build-app.sh` regenerates `Brand/` from it:

- `wren-mark*.svg`: vector masters, traced from the logo with Apple's Vision framework (`swift run wren-tools trace assets/logo.png Sources/WrenKit/WrenMarkData.swift`).
- `wren-menubar-template.svg`: a slightly bolder variant that stays legible at 16 to 18 pt.
- `Wren.iconset` and `app-icon-1024.png`: the macOS icon. It uses your original pixels at 64 px and above, and the vector trace at 16 and 32 px, where the raster blurs.
- `tokens.json`: colours, spacing, and type.

## Known limitations

See ROADMAP.md, section "Milestone 1 status".
