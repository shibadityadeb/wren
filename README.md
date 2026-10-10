# Wren

[![CI](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml/badge.svg)](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml)

Wren remembers what you said you'd do, helps you follow through, and brings important things back to your attention.

It is a native macOS menu-bar agent. You press a shortcut, type what you need to do, and get back to work. Wren saves it locally, reads any date in it, and reminds you at the right time. No cloud service, account, or API key is involved.

## Download

**All releases:** https://github.com/shibadityadeb/wren/releases

Each release has `Wren-macOS-universal.dmg` (signed and notarized) or, until signing is set up, `Wren-macOS-universal-unsigned.dmg` (marked as a preview), plus a `.sha256` checksum. Every push to `main` also produces a preview DMG as a download on the [Actions](https://github.com/shibadityadeb/wren/actions/workflows/ci.yml) run page.

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
| Quit | **Quit Wren**, at the bottom of the menu. |

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

## Releases (maintainers)

1. Update `VERSION` and add a section to `CHANGELOG.md`.
2. Commit, then tag: `git tag v0.4.0-preview.1` (prerelease) or `git tag v0.4.0` (stable), and push the tag.
3. The **Release** workflow runs the full tests on Apple Silicon and Intel, builds the universal app, packages and verifies the DMG on both architectures, signs and notarizes when credentials exist, and publishes a GitHub Release with notes and checksums.

Rules: the tag must match `VERSION`. A **stable** tag is only published if the build is signed and notarized; unsigned builds can only be published under a `-preview`/`-beta`/`-rc` tag, marked as prerelease. **Run workflow** (manual dispatch) builds a release candidate as a downloadable artifact and never publishes.

Local packaging: `scripts/package-dmg.sh` (runs tests, builds universal, packages, verifies). `scripts/verify-dmg.sh <dmg>` re-checks any DMG.

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

## Brand assets

`assets/logo.png` is the source. Running `scripts/build-app.sh` regenerates `Brand/` from it:

- `wren-mark*.svg`: vector masters, traced from the logo with Apple's Vision framework (`swift run wren-tools trace assets/logo.png Sources/WrenKit/WrenMarkData.swift`).
- `wren-menubar-template.svg`: a slightly bolder variant that stays legible at 16 to 18 pt.
- `Wren.iconset` and `app-icon-1024.png`: the macOS icon. It uses your original pixels at 64 px and above, and the vector trace at 16 and 32 px, where the raster blurs.
- `tokens.json`: colours, spacing, and type.

## Known limitations

See ROADMAP.md, section "Milestone 1 status".
