# Wren

[![CI](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml/badge.svg)](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml)

Wren remembers what you said you'd do, helps you follow through, and brings important things back to your attention.

It is a native macOS menu-bar agent. You press a shortcut, type what you need to do, and get back to work. Wren saves it locally, reads any date in it, and reminds you at the right time. No cloud service, account, or API key is involved.

## Requirements

- macOS 14 or later (developed and tested on macOS 26.1, Apple M3, 8 GB RAM)
- Xcode 16 command-line tools (Swift 6.1)
- Optional: [Ollama](https://ollama.com) running locally, with a small chat model

## Build and run

```bash
scripts/build-app.sh            # release build → build/Wren.app
open build/Wren.app
```

`scripts/build-app.sh debug` builds a debug app instead. To install, copy `build/Wren.app` into `/Applications`.

The script compiles the Swift package, regenerates the icon from `assets/logo.png`, assembles the bundle, and ad-hoc signs it. Ad-hoc signing is enough for local use. Moving the app to another Mac requires signing it with your own Developer ID.

## Using Wren

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
| Today's briefing | Sun button in the menu, or the 11:00 notification. |
| Evening check-in | Moon button in the menu, or the 19:00 notification. Done, Later › Snooze / Leave for tomorrow / Reschedule…, then Finish or Dismiss. |
| Change briefing or check-in time, or turn them off | Settings › Daily rhythm |
| Open Wren at login | Settings › Startup (off until you turn it on) |
| See and change what Wren may do | Settings › Permissions, and Activity log |
| Quit | **Quit Wren**, at the bottom of the menu. |

Wren reads dates from your own words even without a language model. It understands phrases like "tomorrow", "tonight at 8", "by Friday", "this weekend", "next week", "in 2 hours", "15 October", "9pm", and "end of month". It never invents a date. A deadline without a time gets a reminder at 10:00 on that day, and you can change that hour in Settings. Numeric dates like 10/11 are deliberately not supported, because the day and month order is ambiguous.

## Local language model (optional)

With a chat model installed, Wren also classifies each capture as a commitment, idea, question, waiting item, or research request, and writes a clean title. Wren never downloads models. On 8 GB of RAM, a 3B model is a good fit:

```bash
ollama pull qwen2.5:3b
```

Then open **Settings › Local language model › Refresh** and pick the model. Wren only connects to `127.0.0.1:11434`, and the client rejects any non-local address. The model's output is validated before anything is saved. Any deadline it suggests must quote words that actually appear in your text, and Wren's own date reader must be able to resolve them.

## What Wren may do on its own

Wren separates proposing, authorizing, executing, verifying and recording every action. In practice:

- Your own clicks on reversible things (done, snooze, edit, drop) just happen.
- Deleting always asks first.
- On its own, Wren only sets and delivers reminders for your deadlines and applies the date rules or local model's reading of your own captures. Both are standing rules you can turn off.
- External permissions (email, AI services) are not granted and their integrations don't exist yet.
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

Capture text is never written to the logs. To reset Wren, quit it and delete the `Wren` folder in Application Support.

## Tests

```bash
swift test
```

The test suite covers persistence across reopen, status transitions, reminder deduplication across restarts, the date reader in two timezones, model-output validation (including invented dates and malformed JSON), local-only enforcement for the Ollama client, and a check that the core library contains no process-execution calls. The live model test runs only when you set `WREN_LIVE_OLLAMA`:

```bash
WREN_LIVE_OLLAMA=qwen2.5:3b swift test --filter testLiveOllama
```

## Brand assets

`assets/logo.png` is the source. Running `scripts/build-app.sh` regenerates `Brand/` from it:

- `wren-mark*.svg`: vector masters, traced from the logo with Apple's Vision framework (`swift run wren-tools trace assets/logo.png Sources/WrenKit/WrenMarkData.swift`).
- `wren-menubar-template.svg`: a slightly bolder variant that stays legible at 16 to 18 pt.
- `Wren.iconset` and `app-icon-1024.png`: the macOS icon. It uses your original pixels at 64 px and above, and the vector trace at 16 and 32 px, where the raster blurs.
- `tokens.json`: colours, spacing, and type.

## Known limitations

See ROADMAP.md, section "Milestone 1 status".
